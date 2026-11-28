import SwiftUI

/// Settings for animated album artwork: Apple's looping clips (off until switched on), the clip cache, and the cover's slow drift.
struct MusicMotionSettingsSection: View {
    let hub: MusicHub
    @AppStorage(MusicMotionPrefs.motionKey) private var motionOn = false
    @AppStorage(MusicMotionPrefs.cellularKey) private var cellular = false
    @AppStorage(MusicMotionPrefs.coverMotionKey) private var coverMotion = true
    @State private var cacheText = ""

    static let unofficialNote = "Unofficial: this reads a third party's service that has no published agreement for apps, so it can stop working without notice."

    private var note: String {
        MusicMotionArtworkService.shared.sourceInfo.first?.privacyNote ?? ""
    }

    var body: some View {
        MusicSettingsGroup(title: "Animated artwork",
                           footer: "Clips are small, are saved on this device once, and are kept under 150 MB. Nothing is looked up or downloaded while this is off.") {
            MusicToggleRow(title: "Animated album art from Apple Music", detail: "Off by default",
                           info: note + " " + Self.unofficialNote, isOn: $motionOn)
            #if os(iOS)
            MusicToggleRow(title: "Allow on mobile data", info: "A clip is read again on every loop, so it is off on a metered connection unless you allow it.", isOn: $cellular)
            #endif
            MusicToggleRow(title: "Slow drift on covers", info: "A gentle zoom while a song plays and has no animated art. Uses no network.", isOn: $coverMotion)
            MusicSettingsRow(title: "Saved clips", detail: cacheText) {
                Button("Clear") {
                    Task { await MusicMotionArtworkService.shared.clearDisk(); await MusicMotionArtworkService.shared.clearMemory(); refresh() }
                }.atlas("control.music.musicClear")
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let bytes = MusicMotionArtworkService.shared.diskBytes()
        cacheText = bytes == 0 ? "None" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
