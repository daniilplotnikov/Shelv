import OSLog
import SwiftUI

private struct DuplicateSongsPrompt: Identifiable {
    let id: String
    let playlist: Playlist
    let songIds: [String]
    let duplicateIds: Set<String>

    init(playlist: Playlist, songIds: [String], duplicateIds: Set<String>) {
        self.id = playlist.id
        self.playlist = playlist
        self.songIds = songIds
        self.duplicateIds = duplicateIds
    }
}

struct AddToPlaylistPanel: View {
    let songIds: [String]
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State private var newPlaylistName = ""
    @State private var showDuplicatePrompt = false
    @State private var duplicatePrompt: DuplicateSongsPrompt?
    @State private var addFailed = false

    private var visiblePlaylists: [Playlist] { libraryStore.playlists }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(String(localized: "add_to_playlist_2"))
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            List {
                // Existing playlists
                if !visiblePlaylists.isEmpty {
                    Section(String(localized: "existing_playlists")) {
                        ForEach(Array(visiblePlaylists.enumerated()), id: \.element.id) { index, playlist in
                            Button {
                                Task {
                                    let duplicateIds = await libraryStore.songIdsAlreadyInPlaylist(playlist, songIds: songIds)
                                    if duplicateIds.isEmpty {
                                        let success = await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
                                        finish(success)
                                    } else {
                                        duplicatePrompt = DuplicateSongsPrompt(playlist: playlist, songIds: songIds, duplicateIds: duplicateIds)
                                        showDuplicatePrompt = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    CoverArtView(
                                        url: playlist.coverArt.flatMap {
                                            SubsonicAPIService.shared.coverArtURL(id: $0, size: 60)
                                        },
                                        size: 36,
                                        cornerRadius: 4
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                        if let count = playlist.songCount {
                                            Text(String(format: String(localized: "count_tracks_format"), count))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                        }
                    }
                }

                // Create new
                Section(String(localized: "create_new")) {
                    HStack {
                        TextField(String(localized: "playlist_name"), text: $newPlaylistName)
                            .textFieldStyle(.roundedBorder)
                        Button(String(localized: "create")) {
                            let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            playlistAddLogger.info("create tapped songsInPanel=\(songIds.count)")
                            Task {
                                // Created with its songs in one request. Looking the new playlist
                                // up by name afterwards could pick another playlist of that name.
                                let success = await libraryStore.createPlaylist(name: name, songIds: songIds)
                                finish(success)
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                        .tint(themeColor)
                    }
                    .listRowSeparator(.hidden, edges: .top)
                }
            }
            .listStyle(.inset)

            if addFailed {
                Text(String(localized: "add_to_playlist_failed"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .frame(width: 380, height: 440)
        .task {
            if libraryStore.playlists.isEmpty {
                await libraryStore.loadPlaylists()
            }
        }
        .alert(
            String(localized: "song_already_in_playlist_title"),
            isPresented: $showDuplicatePrompt,
            presenting: duplicatePrompt
        ) { prompt in
            Button(String(localized: "discard"), role: .cancel) {
                let remaining = prompt.songIds.filter { !prompt.duplicateIds.contains($0) }
                guard !remaining.isEmpty else { return }
                Task {
                    let success = await libraryStore.addSongsToPlaylist(prompt.playlist, songIds: remaining)
                    finish(success)
                }
            }
            Button(String(localized: "add_anyway")) {
                Task {
                    let success = await libraryStore.addSongsToPlaylist(prompt.playlist, songIds: prompt.songIds)
                    finish(success)
                }
            }
        } message: { prompt in
            Text(String(
                format: String(localized: prompt.duplicateIds.count == 1
                    ? "song_already_in_playlist_message"
                    : "songs_already_in_playlist_message_format"),
                prompt.duplicateIds.count
            ))
        }
    }

    /// Closes the panel only when the songs really are in the playlist. Otherwise it stays
    /// open with a message, instead of looking like it worked.
    private func finish(_ success: Bool) {
        playlistAddLogger.info("panel finished success=\(success)")
        if success {
            dismiss()
        } else {
            addFailed = true
        }
    }
}
