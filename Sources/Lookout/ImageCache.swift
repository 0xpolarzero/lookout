import AppKit
import ImageIO

/// Memory cache for avatars, with in-flight dedupe, a disk-backed URLCache and downsampling to the pixel size asked
/// for in the URL's `s` query item.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        cache.countLimit = 300
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 100 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// The image if it's already in memory.
    func cached(_ url: URL?) -> NSImage? {
        url.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    /// Loads (or joins an in-flight load of) an image.
    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        // Avatars are decoration: a test run keeps the placeholders and asks nobody for them.
        guard !UnderTest.isRunning else { return nil }
        let task: Task<NSImage?, Never> = lock.withLock {
            if let t = inflight[url] { return t }
            let t = Task<NSImage?, Never> { [session] in
                defer { self.lock.withLock { self.inflight[url] = nil } }
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                let image = Self.downsample(data, maxPixel: Self.pixels(url))
                if let image { self.cache.setObject(image, forKey: url as NSURL) }
                return image
            }
            inflight[url] = t
            return t
        }
        return await task.value
    }

    /// Warms the cache, e.g. after a sync, so avatars are there the first time the hub opens.
    func prefetch(_ urls: [URL]) {
        for url in Set(urls) where cached(url) == nil {
            Task.detached(priority: .utility) { _ = await ImageCache.shared.load(url) }
        }
    }

    private static func pixels(_ url: URL) -> Int {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value.flatMap(Int.init) ?? 128
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
