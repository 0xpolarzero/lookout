import Foundation
import Testing
@testable import Lookout

@Suite struct LevelDBReading {
    private func varint(_ v: Int) -> [UInt8] {
        var v = v, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7f | 0x80)); v >>= 7 }
        return out + [UInt8(v)]
    }

    private func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * UInt64($0)) & 0xff) } }

    private func batch(_ seq: UInt64, _ puts: [(String, String?)]) -> [UInt8] {
        var b = le(seq, 8) + le(UInt64(puts.count), 4)
        for (k, v) in puts {
            if let v {
                b += [1] + varint(k.utf8.count) + Array(k.utf8) + varint(v.utf8.count) + Array(v.utf8)
            } else {
                b += [0] + varint(k.utf8.count) + Array(k.utf8)
            }
        }
        return b
    }

    private func record(_ payload: [UInt8], type: UInt8 = 1) -> [UInt8] {
        [0, 0, 0, 0] + le(UInt64(payload.count), 2) + [type] + payload
    }

    @Test func logKeepsSequenceOrderAndDeletions() {
        let log = record(batch(10, [("_x\u{0}\u{1}k", "old"), ("other", "1")]))
            + record(batch(12, [("_x\u{0}\u{1}k", "new")]))
        let entries = LevelDB.logEntries(log).filter { String(decoding: $0.key, as: UTF8.self).hasSuffix("k") }
        #expect(entries.map(\.sequence) == [10, 12])
        #expect(entries.last?.value == Array("new".utf8))
        let deleted = LevelDB.logEntries(record(batch(20, [("k", nil)])))
        #expect(deleted.first?.value == nil)
    }

    @Test func logReassemblesFragmentsAndStopsAtATornTail() {
        let payload = batch(5, [("key", String(repeating: "v", count: 40))])
        let split = record(Array(payload[..<20]), type: 2) + record(Array(payload[20...]), type: 4)
        #expect(LevelDB.logEntries(split).first?.value?.count == 40)
        #expect(LevelDB.logEntries(split + [1, 2, 3]).count == 1)
    }

    @Test func snappyLiteralsAndOverlappingCopies() throws {
        // "abcd" literal, then copy offset 4 length 8 → "abcdabcdabcd".
        let compressed: [UInt8] = varint(12) + [3 << 2, 97, 98, 99, 100] + [UInt8((8 - 4) << 2 | 1), 4]
        #expect(try LevelDB.snappy(compressed) == Array("abcdabcdabcd".utf8))
        // Two-byte offset copy.
        let two: [UInt8] = varint(6) + [2 << 2, 120, 121, 122] + [UInt8((3 - 1) << 2 | 2), 3, 0]
        #expect(try LevelDB.snappy(two) == Array("xyzxyz".utf8))
        #expect(throws: LevelDB.Malformed.self) { try LevelDB.snappy(varint(3) + [UInt8(3 << 2 | 1), 9]) }
    }

    @Test func blockEntriesUndoPrefixCompression() throws {
        var block: [UInt8] = []
        block += varint(0) + varint(5) + varint(1) + Array("apple".utf8) + [49]
        block += varint(3) + varint(3) + varint(1) + Array("ly!".utf8) + [50]
        block += le(0, 4) + le(1, 4)  // one restart at 0, count 1
        let entries = try LevelDB.blockEntries(block)
        #expect(entries.map { String(decoding: $0.0, as: UTF8.self) } == ["apple", "apply!"])
    }

    @Test func latestAcrossFilesWins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-ldb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(record(batch(30, [("_o\u{0}\u{1}target", "second")]))).write(to: dir.appendingPathComponent("000010.log"))
        try Data(record(batch(7, [("_o\u{0}\u{1}target", "first")]))).write(to: dir.appendingPathComponent("000003.log"))
        #expect(LevelDB.latest(in: dir, keySuffix: Array("target".utf8)) == Array("second".utf8))
    }
}
