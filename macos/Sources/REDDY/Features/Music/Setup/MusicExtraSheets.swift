import SwiftUI

/// The windows Music opens from anywhere (first-run setup, the Ragas window on a raga, Sounds Like). Kept in one modifier so the main view's chain of sheets stays short.
struct MusicExtraSheets: ViewModifier {
    let hub: MusicHub
    @Bindable var chrome: MusicChromeState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $chrome.setupOpen, onDismiss: { UserDefaults.standard.set(true, forKey: MusicSetupGate.doneKey) }) { MusicSetupSheet(hub: hub) { chrome.setupOpen = false } }   // closing it any way counts as seen: it is offered once
            .sheet(item: $chrome.ragaRequest) { r in MusicRagaSheet(hub: hub, initialRaga: r.raga) { chrome.ragaRequest = nil } }
            .sheet(isPresented: $chrome.marksOpen) { MusicTrackMarksSheet(hub: hub) { chrome.marksOpen = false } }
            .sheet(isPresented: $chrome.healthOpen) { MusicLibraryHealthSheet(hub: hub) { chrome.healthOpen = false } }
            .sheet(isPresented: $chrome.visualizerOpen) { MusicVisualizerSheet(hub: hub) { chrome.visualizerOpen = false } }
            .sheet(item: $chrome.convertFiles) { f in MusicConvertSheet(hub: hub, initial: f.urls) { chrome.convertFiles = nil } }
            .sheet(isPresented: $chrome.modesOpen) { MusicListeningModeSheet(hub: hub) { chrome.modesOpen = false } }
            .sheet(isPresented: $chrome.paletteOpen) { MusicCommandPalette(hub: hub) { chrome.paletteOpen = false } }
            .sheet(isPresented: $chrome.automationOpen) { MusicAutomationSheet(hub: hub) { chrome.automationOpen = false } }
            .sheet(item: $chrome.soundsLike) { t in MusicSonicSheet(hub: hub, track: t, close: { chrome.soundsLike = nil }) }
    }
}
