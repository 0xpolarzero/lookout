import Foundation

/// Just enough LevelDB to read one key out of a Chromium "Local Storage" folder while the app that owns it keeps
/// running: the write-ahead log, SSTables and their Snappy blocks. Read-only, no locking: whatever is on disk now.
/// Every version of the key found anywhere is compared by sequence number, so stale files left behind by a
/// compaction never win.
enum LevelDB {
    struct Entry: Equatable {
        var key: [UInt8]
        var sequence: UInt64
        /// nil when the newest write was a deletion.
        var value: [UInt8]?
    }

    /// Matches per file, keyed by path, size and modification date. Tables never change once written, so in
    /// practice only the log is parsed again.
    private static var cache: [String: (stamp: String, entries: [Entry])] = [:]

    /// Newest value of the first key ending with `suffix`, or nil if absent (or deleted).
    static func latest(in dir: URL, keySuffix: [UInt8]) -> [UInt8]? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        var best: Entry?
        var live = Set<String>()
        for file in files where ["log", "ldb", "sst"].contains(file.pathExtension) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let stamp = "\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let path = file.path + "|" + String(decoding: keySuffix, as: UTF8.self)
            live.insert(path)
            var found: [Entry]
            if let cached = cache[path], cached.stamp == stamp {
                found = cached.entries
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                let bytes = [UInt8](data)
                found = file.pathExtension == "log" ? logEntries(bytes) : (try? tableEntries(bytes)) ?? []
                found = found.filter { $0.key.ends(with: keySuffix) }
                cache[path] = (stamp, found)
            }
            for entry in found where best == nil || entry.sequence > best!.sequence {
                best = entry
            }
        }
        cache = cache.filter { live.contains($0.key) || !$0.key.hasPrefix(dir.path) }
        return best?.value
    }

    // MARK: Log (write-ahead journal of WriteBatches)

    static func logEntries(_ bytes: [UInt8]) -> [Entry] {
        var entries: [Entry] = []
        for batch in logRecords(bytes) {
            entries += (try? batchEntries(batch)) ?? []
        }
        return entries
    }

    /// Reassembles records from 32 KiB blocks (FULL, or FIRST/MIDDLE…/LAST fragments). Stops at a torn tail.
    static func logRecords(_ bytes: [UInt8]) -> [[UInt8]] {
        let blockSize = 32768
        var records: [[UInt8]] = []
        var pending: [UInt8]?
        var p = 0
        while p + 7 <= bytes.count {
            let leftInBlock = blockSize - p % blockSize
            if leftInBlock < 7 {
                p += leftInBlock
                continue
            }
            let length = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8
            let type = bytes[p + 6]
            let start = p + 7
            guard type != 0, start + length <= bytes.count else { break }
            let payload = Array(bytes[start..<start + length])
            p = start + length
            switch type {
            case 1: records.append(payload); pending = nil
            case 2: pending = payload
            case 3: pending? += payload
            case 4:
                if let first = pending { records.append(first + payload) }
                pending = nil
            default: pending = nil
            }
        }
        return records
    }

    /// WriteBatch: sequence (8, LE), count (4), then Put(1)/Delete(0) records. Each record takes the next sequence.
    static func batchEntries(_ batch: [UInt8]) throws -> [Entry] {
        var r = Reader(batch)
        var sequence = try r.fixed64()
        let count = try r.fixed32()
        var entries: [Entry] = []
        for _ in 0..<count {
            let tag = try r.byte()
            let key = try r.lengthPrefixed()
            switch tag {
            case 1: entries.append(Entry(key: key, sequence: sequence, value: try r.lengthPrefixed()))
            case 0: entries.append(Entry(key: key, sequence: sequence, value: nil))
            default: throw Malformed()
            }
            sequence += 1
        }
        return entries
    }

    // MARK: Tables

    /// Every entry of an SSTable: footer → index block → data blocks. Keys are internal keys (user key + 8-byte tag).
    static func tableEntries(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 48 else { throw Malformed() }
        var footer = Reader(Array(bytes[(bytes.count - 48)...]))
        _ = try footer.varint(); _ = try footer.varint()  // metaindex handle
        let index = try block(bytes, offset: Int(try footer.varint()), size: Int(try footer.varint()))
        var entries: [Entry] = []
        for (_, handle) in try blockEntries(index) {
            var h = Reader(handle)
            let data = try block(bytes, offset: Int(try h.varint()), size: Int(try h.varint()))
            for (key, value) in try blockEntries(data) where key.count >= 8 {
                let tag = key.suffix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                entries.append(Entry(key: Array(key.dropLast(8)), sequence: tag >> 8, value: tag & 0xff == 1 ? value : nil))
            }
        }
        return entries
    }

    /// A block's contents (its 5-byte trailer says whether it's Snappy-compressed).
    private static func block(_ bytes: [UInt8], offset: Int, size: Int) throws -> [UInt8] {
        guard offset >= 0, size >= 0, offset + size + 5 <= bytes.count else { throw Malformed() }
        let raw = Array(bytes[offset..<offset + size])
        switch bytes[offset + size] {
        case 0: return raw
        case 1: return try snappy(raw)
        default: throw Malformed()
        }
    }

    /// Prefix-compressed key/value pairs, followed by the restart array and its count.
    static func blockEntries(_ block: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { throw Malformed() }
        let restarts = Int(block.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        let end = block.count - 4 - restarts * 4
        guard end >= 0 else { throw Malformed() }
        var r = Reader(Array(block[..<end]))
        var key: [UInt8] = []
        var out: [([UInt8], [UInt8])] = []
        while !r.atEnd {
            let shared = Int(try r.varint()), unshared = Int(try r.varint()), valueLength = Int(try r.varint())
            guard shared <= key.count else { throw Malformed() }
            key = Array(key[..<shared]) + (try r.take(unshared))
            out.append((key, try r.take(valueLength)))
        }
        return out
    }

    // MARK: Snappy

    static func snappy(_ input: [UInt8]) throws -> [UInt8] {
        var r = Reader(input)
        let length = Int(try r.varint())
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while !r.atEnd {
            let tag = try r.byte()
            switch tag & 3 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    n = try r.take(extra).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                }
                out += try r.take(n + 1)
            case 1:
                let n = Int((tag >> 2) & 7) + 4
                let offset = Int(tag >> 5) << 8 | Int(try r.byte())
                try copy(&out, offset: offset, count: n)
            case 2:
                let offset = try r.take(2).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                try copy(&out, offset: offset, count: Int(tag >> 2) + 1)
            default:
                let offset = try r.take(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                try copy(&out, offset: offset, count: Int(tag >> 2) + 1)
            }
        }
        guard out.count == length else { throw Malformed() }
        return out
    }

    /// Back-reference; may overlap what it's producing (byte by byte on purpose).
    private static func copy(_ out: inout [UInt8], offset: Int, count: Int) throws {
        guard offset > 0, offset <= out.count else { throw Malformed() }
        let start = out.count - offset
        for i in 0..<count { out.append(out[start + i]) }
    }

    // MARK: Bytes

    struct Malformed: Error {}

    struct Reader {
        let bytes: [UInt8]
        var p = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { p >= bytes.count }

        mutating func byte() throws -> UInt8 {
            guard p < bytes.count else { throw Malformed() }
            defer { p += 1 }
            return bytes[p]
        }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, p + n <= bytes.count else { throw Malformed() }
            defer { p += n }
            return Array(bytes[p..<p + n])
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: UInt64(0), to: 64, by: 7) {
                let b = try byte()
                result |= UInt64(b & 0x7f) << shift
                if b < 0x80 { return result }
            }
            throw Malformed()
        }

        mutating func fixed32() throws -> UInt32 {
            try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }

        mutating func fixed64() throws -> UInt64 {
            try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }

        mutating func lengthPrefixed() throws -> [UInt8] {
            try take(Int(try varint()))
        }
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
