import SwiftUI
#if os(iOS)
import AVKit
#endif

/// Where Music plays. On the Mac the person picks one of the connected outputs: a device that is not connected yields to the system output
/// and is used again when it returns, and one that would not open is skipped until it is picked again. Music never takes an output away
/// from other apps. On iPhone and iPad the system's route picker chooses AirPlay, Bluetooth or the speaker.
struct MusicOutputDeviceSettingsSection: View {
    let hub: MusicHub

    private var outputs: MusicOutputDevices { hub.player.outputs }

    var body: some View {
        #if os(macOS)
        MusicSettingsGroup(title: "Output device", footer: "Applies to Music only. Music never takes a device away from other apps.") {
            MusicPickerRow(title: "Play through", atlas: "control.music.outputDevice",
                           info: "Pick where Music plays. If the device is unplugged, Music uses the system output and goes back to it when it returns.",
                           selection: Binding(get: { outputs.chosenUID ?? "" }, set: { outputs.choose($0.isEmpty ? nil : $0) }),
                           options: options)
            MusicValueRow(title: "Status", value: statusText)
        }
        .onAppear { outputs.start() }
        #else
        MusicSettingsGroup(title: "Output device", footer: "Choose AirPlay, Bluetooth or the speaker for Music.") {
            MusicSettingsRow(title: "Play through") {
                MusicRoutePickerButton().frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget)
            }
        }
        #endif
    }

    /// "System default", every connected output, and the chosen one even while it is unplugged.
    private var options: [(value: String, label: String)] {
        var list: [(value: String, label: String)] = [("", "System default")]
        list += outputs.available.map { ($0.uid, $0.name) }
        if let c = outputs.chosenUID, !outputs.available.contains(where: { $0.uid == c }) {
            list.append((c, Localized.string("%@ (not connected)", outputs.chosenName ?? c)))
        }
        return list
    }

    private var statusText: String {
        let name = outputs.chosenName ?? outputs.chosenUID ?? ""
        switch outputs.resolution {
        case .systemDefault: return Localized.string("Following the system output")
        case .device: return Localized.string("Playing on %@", name)
        case .yieldedMissing: return Localized.string("%@ is not connected. Using the system output until it returns.", name)
        case .yieldedFailed: return Localized.string("%@ would not open. Using the system output. Pick it again to retry.", name)
        }
    }
}

#if os(iOS)
/// The system route picker (AirPlay, Bluetooth, speaker) as a small button.
struct MusicRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
#endif
