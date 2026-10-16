import Foundation

nonisolated enum DiscoverAlbumList {
    /// Shelves stay short to scroll; the full list behind a shelf title shows more.
    static let shelfSize = 20
    static let fullListSize = 30

    /// The shelf's own albums first, so the list opens exactly as the shelf looked,
    /// then whatever the larger request returned on top of that.
    static func merged(shelf: [Album], fetched: [Album], limit: Int = fullListSize) -> [Album] {
        var seen = Set(shelf.map(\.id))
        var result = shelf
        for album in fetched where seen.insert(album.id).inserted {
            result.append(album)
        }
        return Array(result.prefix(limit))
    }
}
