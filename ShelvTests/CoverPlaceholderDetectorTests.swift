import CryptoKit
import XCTest

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data)?)?
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".placeholder.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requestedURLs.append(url) }
        if let (response, data) = Self.handler?(request) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoverPlaceholderDetectorTests: XCTestCase {
    private let placeholder = Data([0x01, 0x02, 0x03, 0x04])
    private let realCover = Data([0x0A, 0x0B, 0x0C])

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.requestedURLs = []
        StubProtocol.handler = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func template(host: String, path: String = "/rest/getCoverArt", size: Int = 300) -> URL {
        URL(string: "https://\(host)\(path)?u=a&t=tok&s=salt&id=al-1&size=\(size)")!
    }

    private func uniqueHost() -> String { "\(UUID().uuidString.lowercased()).placeholder.test" }

    private func serve(_ data: Data, contentType: String = "image/webp", status: Int = 200) {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!
            return (response, data)
        }
    }

    func testDetectsServerPlaceholderAndKeepsRealCover() async {
        serve(placeholder)
        let url = template(host: uniqueHost())

        let isPlaceholder = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)
        let isReal = await CoverPlaceholderDetector.shared.isPlaceholder(realCover, template: url)

        XCTAssertTrue(isPlaceholder)
        XCTAssertFalse(isReal)
    }

    func testProbeUsesUnknownIdAndRequestedSizeButKeepsAuthItems() async {
        serve(placeholder)
        let url = template(host: uniqueHost())

        _ = await CoverPlaceholderDetector.shared.isPlaceholder(realCover, size: 150, template: url)

        let probe = try? XCTUnwrap(StubProtocol.requestedURLs.first)
        let items = URLComponents(url: probe!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        XCTAssertEqual(value("id"), "al-shelv-placeholder-probe")
        XCTAssertEqual(value("size"), "150")
        XCTAssertEqual(value("t"), "tok")
        XCTAssertEqual(value("s"), "salt")
    }

    func testReferenceIsFetchedOnlyOncePerHostAndSize() async {
        serve(placeholder)
        let url = template(host: uniqueHost())

        _ = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)
        _ = await CoverPlaceholderDetector.shared.isPlaceholder(realCover, template: url)
        _ = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)

        XCTAssertEqual(StubProtocol.requestedURLs.count, 1)
    }

    func testNonImageProbeAnswerMeansNoReference() async {
        serve(Data("<error/>".utf8), contentType: "text/xml")
        let url = template(host: uniqueHost())

        let result = await CoverPlaceholderDetector.shared.isPlaceholder(Data("<error/>".utf8), template: url)

        XCTAssertFalse(result)
    }

    func testFailedProbeNeverFlagsAnImage() async {
        StubProtocol.handler = nil
        let url = template(host: uniqueHost())

        let result = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)

        XCTAssertFalse(result)
    }

    func testFailedProbeIsNotRetriedImmediately() async {
        StubProtocol.handler = nil
        let url = template(host: uniqueHost())

        _ = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)
        _ = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)

        XCTAssertEqual(StubProtocol.requestedURLs.count, 1)
    }

    func testIgnoresUrlsThatAreNotCoverArt() async {
        serve(placeholder)
        let url = template(host: uniqueHost(), path: "/radio/artwork")

        let result = await CoverPlaceholderDetector.shared.isPlaceholder(placeholder, template: url)

        XCTAssertFalse(result)
        XCTAssertTrue(StubProtocol.requestedURLs.isEmpty)
    }

    func testSizeParsedFromCacheKeys() {
        XCTAssertEqual(CoverPlaceholderDetector.size(fromCacheKey: "al-1_300"), 300)
        XCTAssertEqual(CoverPlaceholderDetector.size(fromCacheKey: "host_al-1_600"), 600)
        XCTAssertNil(CoverPlaceholderDetector.size(fromCacheKey: "nounderscore"))
        XCTAssertNil(CoverPlaceholderDetector.size(fromCacheKey: "al-1_abc"))
    }
}

final class KnownPlaceholderTests: XCTestCase {
    func testMatchesWhenCountAndHashAgree() {
        let bytes = Data(repeating: 7, count: 10)
        let hash = SHA256Hex.of(bytes)

        XCTAssertTrue(CoverPlaceholderDetector.isKnownPlaceholder(bytes, in: [10: [hash]]))
        XCTAssertFalse(CoverPlaceholderDetector.isKnownPlaceholder(Data(repeating: 8, count: 10), in: [10: [hash]]))
        XCTAssertFalse(CoverPlaceholderDetector.isKnownPlaceholder(Data(repeating: 7, count: 11), in: [10: [hash]]))
    }

    func testBuiltInTableHoldsNavidromesPlaceholder() {
        XCTAssertEqual(
            CoverPlaceholderDetector.knownPlaceholderHashes[69228],
            ["273a4dbd61dfbb0a12d5d8ffe780eb7a3d4d000bc9771c5411cc70ae4dfa8a1f"]
        )
    }

    func testIsDetectedWithoutAnyTemplateOrNetwork() async {
        // A table entry for the real placeholder cannot be forged without its bytes, so
        // this only checks that a missing template is accepted and means "not a placeholder".
        let result = await CoverPlaceholderDetector.shared.isPlaceholder(Data([1, 2, 3]), template: nil)
        XCTAssertFalse(result)
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
