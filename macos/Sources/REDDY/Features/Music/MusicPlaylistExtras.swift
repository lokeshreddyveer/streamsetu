import SwiftUI
import Observation
import ImageIO
import UniformTypeIdentifiers

/// The description and cover of a playlist in Your library. They live beside the playlists on this Mac and never leave it.
@MainActor @Observable
final class MusicPlaylistExtras {
    static let shared = MusicPlaylistExtras()
    nonisolated static let descriptionLimit = 300
    nonisolated static let coverPixels = 640
    private static let key = "music.playlistDescriptions"

    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL = MusicHub.supportDirectory.appendingPathComponent("PlaylistCovers", isDirectory: true)) {
        self.defaults = defaults; self.directory = directory
    }

    /// Trims the text and keeps it to the limit.
    nonisolated static func cleaned(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(descriptionLimit))
    }

    func description(for id: UUID) -> String {
        _ = revision
        return (defaults.dictionary(forKey: Self.key) as? [String: String])?[id.uuidString] ?? ""
    }

    func setDescription(_ text: String, for id: UUID) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        let c = Self.cleaned(text)
        all[id.uuidString] = c.isEmpty ? nil : c
        if all.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(all, forKey: Self.key) }
        revision += 1
    }

    /// A cover is stored as `<id>-<milliseconds>.jpg`: a new choice gets a new name, so a replaced picture can never be served from a cache under the old name.
    /// (Earlier builds wrote `<id>.jpg`; that still counts, as the oldest.)
    private func files(_ id: UUID) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(id.uuidString) }.sorted { stamp($0, id) < stamp($1, id) }
    }
    private func stamp(_ url: URL, _ id: UUID) -> Int {
        let rest = url.deletingPathExtension().lastPathComponent.dropFirst(id.uuidString.count)
        return rest.hasPrefix("-") ? Int(rest.dropFirst()) ?? 0 : 0
    }

    func coverURL(for id: UUID) -> URL? {
        _ = revision
        return files(id).last
    }

    /// Scales the chosen picture down and keeps a copy; the original is not touched. Only JPEG or PNG, at most 8 MB. The new copy is stored first and the
    /// older ones are deleted only after it is safely on disk.
    func setCover(from source: URL, for id: UUID) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let type = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
        switch MusicPlaylistCover.validateCustom(byteCount: bytes, typeIdentifier: type) {
        case .ok: break
        case .tooLarge: throw MusicPlaylistCoverError.tooLarge
        case .wrongType: throw MusicPlaylistCoverError.wrongType
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Self.coverPixels]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw MusicError.unsupported("that picture")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = files(id)
        let target = directory.appendingPathComponent("\(id.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw MusicError.unsupported("that picture") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: target); throw MusicError.unsupported("that picture") }
        for old in older { try? FileManager.default.removeItem(at: old) }
        revision += 1
    }

    func removeCover(for id: UUID) {
        for f in files(id) { try? FileManager.default.removeItem(at: f) }
        revision += 1
    }

    /// Called when a playlist is deleted.
    func forget(_ id: UUID) {
        removeCover(for: id)
        setDescription("", for: id)
    }
}

enum MusicPlaylistCoverError: Error { case tooLarge, wrongType }

/// A playlist's own cover when the person chose one, else a local 2x2 of its songs' distinct covers (one cover when fewer differ, the designed tile when
/// none), never the service's collage.
struct MusicLocalCover: View {
    let id: UUID
    let fallback: [MusicThumbnail]
    /// The thumbnails of the playlist's songs in order (the first 60 are used).
    var members: [[MusicThumbnail]] = []
    var name: String = ""
    let size: CGFloat
    var corner: CGFloat = 16
    @State private var image: CGImage?
    @State private var loadedRevision = -1

    var body: some View {
        let extras = MusicPlaylistExtras.shared
        let url = extras.coverURL(for: id)
        Group {
            if url != nil, let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
                    .accessibilityHidden(true)
            } else {
                if members.isEmpty { MusicArtwork(fallback, size: size, corner: corner) }
                else {
                    MusicPlaylistCoverArt(members: members, name: name, size: size, corner: corner)
                        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(ColorTokens.line, lineWidth: 0.75))
                }
            }
        }
        .task(id: extras.revision) {
            guard let url else { image = nil; return }
            // A 640 pt picture decodes in a few milliseconds, so it is read here rather than handed across threads.
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) { image = CGImageSourceCreateImageAtIndex(src, 0, nil) } else { image = nil }
        }
    }
}

/// Rename, describe and choose a cover for one of the person's playlists.
struct MusicEditPlaylistSheet: View {
    let hub: MusicHub
    let playlist: LocalPlaylist
    let dismiss: () -> Void
    @State private var name: String
    @State private var text: String
    @State private var choosing = false
    @State private var problem: String?
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub, playlist: LocalPlaylist, dismiss: @escaping () -> Void) {
        self.hub = hub; self.playlist = playlist; self.dismiss = dismiss
        _name = State(initialValue: playlist.name)
        _text = State(initialValue: MusicPlaylistExtras.shared.description(for: playlist.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Edit playlist").font(MusicTokens.sheetTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(MusicTokens.iconSmall).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle()) }
                    .buttonStyle(.plain).hoverHighlight().accessibilityLabel("Close").atlas("control.music.playlistsClose")
            }
            HStack(alignment: .top, spacing: Spacing.lg) {
                VStack(spacing: Spacing.sm) {
                    MusicLocalCover(id: playlist.id, fallback: playlist.tracks.first?.thumbnails ?? [], members: playlist.tracks.prefix(MusicPlaylistCoverPlan.scanLimit).map(\.thumbnails),
                                    name: playlist.name, size: 120, corner: MusicTokens.radiusCard)
                    HStack(spacing: Spacing.sm) {
                        Button("Change") { choosing = true }.musicButton(.secondary).accessibilityLabel("Choose a cover picture").atlas("control.music.playlistCover")
                        if MusicPlaylistExtras.shared.coverURL(for: playlist.id) != nil {
                            Button("Remove") { MusicPlaylistExtras.shared.removeCover(for: playlist.id) }.musicButton(.tertiary, size: .compact)
                                .frame(minHeight: MusicTokens.hitTarget).accessibilityLabel("Remove the cover picture").atlas("control.music.playlistsRemoveTheCoverPicture")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Playlist name")
                    TextField("Description", text: $text, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder).accessibilityLabel("Playlist description")
                    Text(verbatim: "\(text.count)/\(MusicPlaylistExtras.descriptionLimit)").font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
                }
            }
            if let problem { Text(verbatim: problem).font(Typography.caption).foregroundStyle(ColorTokens.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.musicButton(.secondary).keyboardShortcut(.cancelAction).atlas("control.music.playlistsCancel")
                Button("Save") { save() }.musicButton(.primary).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).atlas("control.music.playlistsSave")
            }
        }
        .padding(Spacing.xl).frame(width: 520)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.jpeg, .png]) { result in
            switch result {
            case .success(let url):
                do { try MusicPlaylistExtras.shared.setCover(from: url, for: playlist.id); problem = nil }
                catch MusicPlaylistCoverError.tooLarge { problem = Localized.string("That picture is over 8 MB.") }
                catch MusicPlaylistCoverError.wrongType { problem = Localized.string("Choose a JPEG or PNG picture.") }
                catch { problem = Localized.string("That picture could not be used.") }
            case .failure: problem = Localized.string("That picture could not be used.")
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != playlist.name { hub.library.rename(playlist, to: n) }
        MusicPlaylistExtras.shared.setDescription(text, for: playlist.id)
        MusicToasts.shared.success(Localized.string("Playlist updated."))
        dismiss()
    }
}
