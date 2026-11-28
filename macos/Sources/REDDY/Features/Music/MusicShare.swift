import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds a `streamsetu://music/...` link for something and copies it or hands it to the system share sheet.
@MainActor
enum MusicShare {
    static func link(for track: MusicTrack) -> URL? { MusicDeepLinks.link(track: track) }
    static func link(for album: MusicAlbum) -> URL? { MusicDeepLinks.link(album: album) }
    static func link(for artist: MusicArtist) -> URL? { MusicDeepLinks.link(artist: artist) }
    static func link(for playlist: MusicPlaylist) -> URL? { MusicDeepLinks.link(playlist: playlist) }

    static func copy(_ url: URL) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.string = url.absoluteString
        #endif
    }

    #if os(macOS)
    /// Shows the system share picker next to the pointer (or the window centre when there is no window).
    static func showPicker(for url: URL) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let p = view.window?.mouseLocationOutsideOfEventStream ?? .zero
        picker.show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
    #endif
}

