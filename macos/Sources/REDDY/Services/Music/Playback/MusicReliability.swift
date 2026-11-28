import Foundation
#if os(macOS)
import CoreAudio
#endif

// Three small reliability rules, each a plain function so it is tested alone: when a removed output should pause playback, when a failed request is tried
// again, and what to clear when the disk runs low. Nothing here touches the person's library, playlists, likes or downloads.

enum MusicOutputRemoval {
    /// Pause when the output that was playing went away (headphones unplugged, Bluetooth gone) and the person has not turned the rule off.
    static func shouldPause(previousWasRemovable: Bool, previousStillPresent: Bool, wasPlaying: Bool, enabled: Bool, changedByApp: Bool) -> Bool {
        enabled && wasPlaying && previousWasRemovable && !previousStillPresent && !changedByApp
    }
}

enum MusicRetryPolicy {
    static let maxRetries = 2
    /// Seconds to wait before retry number `attempt` (1-based): short, growing, never long enough to feel like a hang.
    static func delay(attempt: Int) -> TimeInterval { attempt <= 1 ? 0.4 : 1.2 }

    /// Only reads are repeated, only for what is usually momentary: a server hiccup (502, 503, 504) or a connection that dropped or timed out.
    static func shouldRetry(method: String, status: Int?, urlErrorCode: URLError.Code?, attempt: Int) -> Bool {
        guard attempt <= maxRetries, method.uppercased() == "GET" else { return false }
        if let status { return [502, 503, 504].contains(status) }
        guard let c = urlErrorCode else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(c)
    }
}

enum MusicStorageLevel: Int, Comparable, Sendable {
    case fine, low, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Low under 1 GB free or 5% of the disk; critical under 300 MB or 2%.
    static func level(freeBytes: Int64, totalBytes: Int64) -> MusicStorageLevel {
        let pct = totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 1
        if freeBytes < 300 * 1_048_576 || pct < 0.02 { return .critical }
        if freeBytes < 1_024 * 1_048_576 || pct < 0.05 { return .low }
        return .fine
    }
}

/// Watches free disk space and clears only what can be rebuilt: the picture cache when space is low, and the audio cache as well when it is critical.
@MainActor
final class MusicStorageGuard {
    static let shared = MusicStorageGuard()
    private var task: Task<Void, Never>?
    private(set) var last = MusicStorageLevel.fine

    func start(audioCache: @escaping @MainActor () -> MusicAudioCache?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.check(audioCache: audioCache())
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func check(audioCache: MusicAudioCache?) {
        guard let v = try? MusicStorage.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return }
        let level = MusicStorageLevel.level(freeBytes: free, totalBytes: Int64(total))
        defer { last = level }
        guard level > .fine else { return }
        Task { await MusicArtworkService.shared.clear() }
        if level == .critical { audioCache?.clear() }
        if level > last {
            MusicToasts.shared.show(level == .critical ? Localized.string("Your disk is almost full. Music cleared its caches to make room.")
                                                       : Localized.string("Your disk is getting full. Music cleared its picture cache."))
        }
    }
}

#if os(macOS)
/// Tells the player when the output it was using disappears (Bluetooth or USB headphones switched off or unplugged), so it can pause instead of
/// carrying on through the speakers.
@MainActor
final class MusicOutputWatcher {
    private var listener: AudioObjectPropertyListenerBlock?
    private var lastID: AudioDeviceID?
    private var lastRemovable = false
    private let onRemoved: @MainActor () -> Void
    private let onChanged: @MainActor (String?) -> Void

    init(onRemoved: @escaping @MainActor () -> Void, onChanged: @escaping @MainActor (String?) -> Void = { _ in }) { self.onRemoved = onRemoved; self.onChanged = onChanged }

    private static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
    private static var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard listener == nil else { return }
        remember()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed() } }
        }
        listener = block
        var a = Self.defaultAddress
        AudioObjectAddPropertyListenerBlock(Self.system, &a, DispatchQueue.main, block)
    }

    func stop() {
        guard let l = listener else { return }
        var a = Self.defaultAddress
        AudioObjectRemovePropertyListenerBlock(Self.system, &a, DispatchQueue.main, l)
        listener = nil
    }

    private func remember() {
        lastID = MusicCoreAudioOutputs.defaultOutputID()
        lastRemovable = lastID.map(Self.isRemovable) ?? false
    }

    private func changed() {
        let was = lastID, wasRemovable = lastRemovable
        remember()
        if lastID != was { onChanged(lastID.flatMap { MusicCoreAudioOutputs.string($0, kAudioDevicePropertyDeviceUID) }) }
        guard let was, wasRemovable, lastID != was else { return }
        // The old output is gone when it no longer lists as a device.
        let stillThere = MusicCoreAudioOutputs.isPresent(was)
        if !stillThere { onRemoved() }
    }

    /// Bluetooth and USB outputs are the ones a person takes away; built-in speakers and displays stay.
    private static func isRemovable(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE || t == kAudioDeviceTransportTypeUSB
    }
}

extension MusicCoreAudioOutputs {
    /// The unique id of the system's current output.
    static func defaultUID() -> String? { defaultOutputID().flatMap { string($0, kAudioDevicePropertyDeviceUID) } }

    /// True when a device with this id is still one of the system's outputs.
    static func isPresent(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains(id)
    }
}
#endif
