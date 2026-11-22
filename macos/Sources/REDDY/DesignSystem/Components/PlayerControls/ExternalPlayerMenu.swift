import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Play in Another App" in the player's menu: the apps found on this device, and a way to copy the address for any other.
struct ExternalPlayerMenu: View {
    let playback: PlaybackCoordinator

    var body: some View {
        if let url = ExternalPlayer.shareableURL(playback.current) {
            let apps = ExternalPlayer.installed()
            Menu {
                ForEach(apps) { app in Button(app.name) { playback.pause(); ExternalPlayer.open(url, with: app) } }
                if !apps.isEmpty { Divider() }
                Button("Copy Stream Address") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    #else
                    UIPasteboard.general.string = url.absoluteString
                    #endif
                }
            } label: { Label("Play in Another App", systemImage: "arrow.up.forward.app") }
        }
    }
}
