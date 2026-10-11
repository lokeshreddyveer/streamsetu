import SwiftUI
import AppKit

@MainActor
enum WindowManager {
    static func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }
    static var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }

    static func exitFullScreen() { if isFullScreen { NSApp.keyWindow?.toggleFullScreen(nil) } }

    static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func chooseFile(types: [String], prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) } + [.plainText]
        panel.prompt = prompt
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(name: String, data: Data) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return (try? data.write(to: url)) != nil
    }
}
