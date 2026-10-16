import CryptoKit
import Foundation

/// Navidrome answers `getCoverArt` for albums whose artwork is not available yet (for
/// example right after an upload, before the scan has finished) with a generic placeholder
/// image and HTTP 200. Cached like a real cover, that placeholder would stick forever because
/// a disk hit is never re-checked. This detects it so callers can skip caching it and ask
/// the server again next time.
///
/// Two checks: the bytes of Navidrome's built-in placeholder (it is returned unscaled, so
/// the same file comes back for every requested size), and the server's own answer for a
/// cover id that cannot exist, which covers servers with a different placeholder.
actor CoverPlaceholderDetector {
    static let shared = CoverPlaceholderDetector()

    private static let probeCoverID = "al-shelv-placeholder-probe"
    private static let referenceMaxAge: TimeInterval = 7 * 24 * 3600
    private static let failureBackoff: TimeInterval = 10 * 60

    /// Byte count -> SHA-256 of placeholder images known to be served by Navidrome.
    /// The count is a cheap pre-filter so ordinary covers are never hashed.
    nonisolated static let knownPlaceholderHashes: [Int: Set<String>] = [
        69228: ["273a4dbd61dfbb0a12d5d8ffe780eb7a3d4d000bc9771c5411cc70ae4dfa8a1f"]
    ]

    private let dir: URL
    private var references: [String: Data] = [:]
    private var inflight: [String: Task<Data?, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    private init() {
        dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_cover_placeholder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// `template` is any getCoverArt URL of the server in question; its auth items are reused.
    /// `size` defaults to the template's own size.
    func isPlaceholder(_ data: Data, size: Int? = nil, template: URL?) async -> Bool {
        if Self.isKnownPlaceholder(data) { return true }
        guard let template, template.path.contains("getCoverArt"),
              let components = URLComponents(url: template, resolvingAgainstBaseURL: false)
        else { return false }
        let resolvedSize = size
            ?? Int(components.queryItems?.first(where: { $0.name == "size" })?.value ?? "")
        guard let resolvedSize, resolvedSize > 0,
              let reference = await reference(size: resolvedSize, components: components)
        else { return false }
        return data == reference
    }

    nonisolated static func isKnownPlaceholder(
        _ data: Data,
        in table: [Int: Set<String>] = knownPlaceholderHashes
    ) -> Bool {
        guard let hashes = table[data.count] else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hashes.contains(digest)
    }

    /// Cache keys of all three platforms end in `_<size>`.
    nonisolated static func size(fromCacheKey key: String) -> Int? {
        guard let underscore = key.lastIndex(of: "_") else { return nil }
        return Int(key[key.index(after: underscore)...])
    }

    private func reference(size: Int, components: URLComponents) async -> Data? {
        let host = components.host ?? "local"
        let raw = "\(host)_\(components.port ?? 0)_\(size)"
        let key = raw.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        if let hit = references[key] { return hit }

        let file = dir.appendingPathComponent(key)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.referenceMaxAge,
           let data = try? Data(contentsOf: file), !data.isEmpty {
            references[key] = data
            return data
        }

        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") { return nil }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.failureBackoff { return nil }
        if let running = inflight[key] { return await running.value }

        var probe = components
        var items = (probe.queryItems ?? []).filter { $0.name != "id" && $0.name != "size" }
        items.append(URLQueryItem(name: "id", value: Self.probeCoverID))
        items.append(URLQueryItem(name: "size", value: "\(size)"))
        probe.queryItems = items
        guard let url = probe.url else { return nil }

        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/"),
                  !data.isEmpty
            else { return nil }
            return data
        }
        inflight[key] = task
        let data = await task.value
        inflight[key] = nil

        if let data {
            references[key] = data
            try? data.write(to: file, options: .atomic)
        } else {
            failedAt[key] = Date()
        }
        return data
    }
}
