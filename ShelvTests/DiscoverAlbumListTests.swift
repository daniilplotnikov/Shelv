import XCTest

final class DiscoverAlbumListTests: XCTestCase {
    private func album(_ id: String) -> Album {
        Album(id: id, name: id)
    }

    func testKeepsShelfOrderAndAppendsNewAlbums() {
        let shelf = ["a", "b", "c"].map(album)
        let fetched = ["b", "a", "d", "e"].map(album)

        let ids = DiscoverAlbumList.merged(shelf: shelf, fetched: fetched).map(\.id)

        XCTAssertEqual(ids, ["a", "b", "c", "d", "e"])
    }

    func testCapsAtLimit() {
        let shelf = (0..<20).map { album("s\($0)") }
        let fetched = (0..<40).map { album("f\($0)") }

        XCTAssertEqual(DiscoverAlbumList.merged(shelf: shelf, fetched: fetched).count, 30)
        XCTAssertEqual(DiscoverAlbumList.merged(shelf: shelf, fetched: fetched, limit: 25).count, 25)
    }

    func testEmptyFetchKeepsShelf() {
        let shelf = ["a", "b"].map(album)
        XCTAssertEqual(DiscoverAlbumList.merged(shelf: shelf, fetched: []).map(\.id), ["a", "b"])
    }

    func testShelfIsTwentyAndFullListThirty() {
        XCTAssertEqual(DiscoverAlbumList.shelfSize, 20)
        XCTAssertEqual(DiscoverAlbumList.fullListSize, 30)
    }
}
