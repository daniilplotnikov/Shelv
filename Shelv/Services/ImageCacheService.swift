import UIKit
import ImageIO

actor ImageCacheService {
    static let shared = ImageCacheService()

    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var waiters: [String: Int] = [:]
    private var writesSinceTrim = 0
    private static let diskLimitBytes = 1_073_741_824 // 1 GB
    private static let diskTrimTarget  = 900 * 1024 * 1024 // 900 MB (hysteresis)
    private static let writesPerTrimCheck = 20
    private static let maxConcurrentDownloads = 6
    // nonisolated: read from inside the detached download task below, which runs off
    // this actor. ConcurrencyLimiter is itself an actor, so sharing the reference is safe.
    nonisolated private let downloadLimiter = ConcurrencyLimiter(maxConcurrent: ImageCacheService.maxConcurrentDownloads)
    // Bounds how many local artwork files can be decoded at once. Without this, fast-
    // scrolling through a grid of many already-downloaded albums fires one decode Task
    // per cell almost simultaneously; combined with un-downsampled decodes of large
    // embedded cover art this could spike memory enough to trigger a jetsam kill.
    private static let maxConcurrentLocalDecodes = 4
    private let localDecodeLimiter = ConcurrencyLimiter(maxConcurrent: ImageCacheService.maxConcurrentLocalDecodes)
    private static let defaultFallbackSizes = [600, 300, 240, 200, 192, 180, 160, 156, 150, 120, 100, 80, 50]
    private static let fallbackSizesByPreferred: [Int: [Int]] = Dictionary(
        uniqueKeysWithValues: defaultFallbackSizes.map { preferred in
            (preferred, [preferred] + defaultFallbackSizes.filter { $0 != preferred })
        }
    )

    private init() {
        cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 200
        memory.totalCostLimit = 100 * 1024 * 1024
    }

    /// Synchroner Memory-Cache-Lookup — kein Actor-Hop nötig (NSCache ist thread-safe)
    nonisolated func cachedImage(key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    nonisolated func cachedImage(key: String, fallbackSizes: [Int]) -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let lastUnderscore = key.lastIndex(of: "_") else { return nil }
        let idPrefix = String(key[key.startIndex..<lastUnderscore]) + "_"
        for size in fallbackSizes {
            let candidate = "\(idPrefix)\(size)"
            guard candidate != key else { continue }
            if let hit = memory.object(forKey: candidate as NSString) { return hit }
        }
        return nil
    }

    nonisolated func cache(_ img: UIImage, key: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
    }

    nonisolated static func coverFallbackSizes(preferred size: Int) -> [Int] {
        fallbackSizesByPreferred[size] ?? ([size] + defaultFallbackSizes)
    }

    func diskOnlyImage(key: String, fallbackSizes: [Int] = ImageCacheService.defaultFallbackSizes) async -> UIImage? {
        await diskOnlyImageResult(key: key, fallbackSizes: fallbackSizes)?.image
    }

    func diskOnlyImageResult(
        key: String,
        fallbackSizes: [Int] = ImageCacheService.defaultFallbackSizes
    ) async -> (key: String, image: UIImage)? {
        let candidates = Self.candidateKeys(for: key, fallbackSizes: fallbackSizes)
        for candidate in candidates {
            if let hit = memory.object(forKey: candidate as NSString) {
                return (candidate, hit)
            }
        }
        let dir = cacheDir
        let template = SubsonicAPIService.shared.coverArtURL(for: "placeholder-probe", size: 300)
        let result = await Task.detached(priority: .medium) { () -> (String, UIImage)? in
            for candidate in candidates {
                let fallbackURL = dir.appendingPathComponent(candidate.pathSafeComponent)
                guard let data = try? Data(contentsOf: fallbackURL),
                      let img = UIImage(data: data) else { continue }
                if await CoverPlaceholderDetector.shared.isPlaceholder(
                       data,
                       size: CoverPlaceholderDetector.size(fromCacheKey: candidate),
                       template: template
                   ) {
                    // A server placeholder cached earlier must not shadow the real cover.
                    try? FileManager.default.removeItem(at: fallbackURL)
                    continue
                }
                return (candidate, img)
            }
            return nil
        }.value
        if let (candidate, img) = result {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: candidate as NSString, cost: cost)
            return (candidate, img)
        }
        return nil
    }

    /// Decodes a locally downloaded artwork file, downsampled to `maxPixelSize` and
    /// concurrency-limited, so scrolling fast through many already-downloaded albums can't
    /// spike memory the way full-resolution `UIImage(contentsOfFile:)` decodes would.
    func localImage(path: String, key: String, maxPixelSize: Int) async -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard await localDecodeLimiter.acquire() else { return nil }
        defer { Task { await localDecodeLimiter.release() } }
        guard !Task.isCancelled else { return nil }
        let img = await Task.detached(priority: .medium) {
            Self.downsampledImage(contentsOfFile: path, maxPixelSize: maxPixelSize)
        }.value
        guard let img, !Task.isCancelled else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    func image(url: URL, key: String) async -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }

        waiters[key, default: 0] += 1
        defer {
            let remaining = waiters[key, default: 1] - 1
            if remaining <= 0 {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = remaining
            }
        }

        if let existing = inflight[key] {
            return await withTaskCancellationHandler {
                await existing.value
            } onCancel: { [weak self] in
                Task { await self?.cancelIfLastWaiter(key) }
            }
        }

        let diskURL = cacheDir.appendingPathComponent(key.pathSafeComponent)
        let cache = self

        let task = Task.detached(priority: .medium) { () -> UIImage? in
            if Task.isCancelled { return nil }
            if let data = try? Data(contentsOf: diskURL),
               let img = UIImage(data: data) {
                if await CoverPlaceholderDetector.shared.isPlaceholder(data, template: url) {
                    try? FileManager.default.removeItem(at: diskURL)
                } else {
                    return img
                }
            }
            if Task.isCancelled { return nil }
            guard await cache.downloadLimiter.acquire() else { return nil }
            defer { Task { await cache.downloadLimiter.release() } }
            if Task.isCancelled { return nil }
            guard let (data, img) = await Self.downloadImage(from: url) else { return nil }
            if Task.isCancelled { return nil }
            // Not cached, so the next request asks the server again.
            if await CoverPlaceholderDetector.shared.isPlaceholder(data, template: url) { return nil }
            try? data.write(to: diskURL, options: .atomic)
            return img
        }

        inflight[key] = task
        let img = await withTaskCancellationHandler {
            await task.value
        } onCancel: { [weak self] in
            Task { await self?.cancelIfLastWaiter(key) }
        }
        inflight.removeValue(forKey: key)

        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: key as NSString, cost: cost)
            writesSinceTrim += 1
            if writesSinceTrim >= Self.writesPerTrimCheck {
                writesSinceTrim = 0
                let dir = cacheDir
                Task.detached(priority: .utility) {
                    Self.trimDiskCache(cacheDir: dir)
                }
            }
        }

        return img
    }

    /// Cancels the shared in-flight download only once every caller waiting
    /// on it has itself been cancelled — a scrolled-away cell shouldn't abort
    /// a fetch another still-visible cell is also waiting on.
    private func cancelIfLastWaiter(_ key: String) {
        if (waiters[key] ?? 0) <= 1 {
            inflight[key]?.cancel()
        }
    }

    nonisolated private static func downloadImage(from url: URL) async -> (Data, UIImage)? {
        let isRadioArtwork = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == RadioNowPlayingMetadata.artworkRevisionQueryItemName }) == true
        let maximumAttempts = isRadioArtwork ? 1 : 3
        let timeout: TimeInterval = isRadioArtwork ? 8 : 12
        for attempt in 1...maximumAttempts {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = timeout
            if let (data, response) = try? await URLSession.shared.data(for: request),
               isSuccessfulImageResponse(response),
               let image = UIImage(data: data) {
                return (data, image)
            }
            if attempt < maximumAttempts {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        return nil
    }

    /// Uses ImageIO's thumbnail generation instead of `UIImage(contentsOfFile:)` so the
    /// decoder never materializes the full-resolution source bitmap in memory — critical
    /// for locally embedded cover art, which can be several thousand pixels per side.
    nonisolated private static func downsampledImage(contentsOfFile path: String, maxPixelSize: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func isSuccessfulImageResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private nonisolated static func candidateKeys(for key: String, fallbackSizes: [Int]) -> [String] {
        var keys = [key]
        guard let lastUnderscore = key.lastIndex(of: "_") else { return keys }
        let idPrefix = String(key[key.startIndex..<lastUnderscore]) + "_"
        for size in fallbackSizes {
            let fallbackKey = "\(idPrefix)\(size)"
            guard fallbackKey != key else { continue }
            keys.append(fallbackKey)
        }
        return keys
    }

    private nonisolated static func trimDiskCache(cacheDir: URL) {
        let fm = FileManager.default
        guard fm.directorySize(at: cacheDir) > diskLimitBytes else { return }
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let sorted = items.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate,
                  let size = values?.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 < $1.1 }

        var total = sorted.reduce(0) { $0 + $1.2 }
        for (url, _, size) in sorted {
            if total <= diskTrimTarget { break }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    func clearAll() {
        memory.removeAllObjects()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func diskUsageBytes() -> Int {
        FileManager.default.directorySize(at: cacheDir)
    }
}
