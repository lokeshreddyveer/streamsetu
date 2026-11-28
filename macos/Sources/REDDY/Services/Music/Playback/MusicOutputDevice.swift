import Foundation
import Observation
#if os(macOS)
import AVFoundation
import CoreAudio
#endif

// Output device choice for Music. The rules are plain values (`MusicOutputDevicePolicy`) so they can be tested without a sound card. The
// controller (`MusicOutputDevices`) lists the devices, remembers the choice and tells the player which device to use. Music never takes a
// device away from other apps: there is no exclusive hold and no change of the device's own sample rate.

struct MusicOutputDeviceInfo: Hashable, Sendable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }
}

/// Which device to use, given the person's choice, what is plugged in, and which devices refused to open.
struct MusicOutputDevicePolicy: Sendable, Equatable {
    enum Resolution: Equatable, Sendable {
        /// No choice: follow the system output.
        case systemDefault
        /// The chosen device is in use.
        case device(String)
        /// The chosen device is not connected right now: the system output is used, and the choice returns when the device does.
        case yieldedMissing(String)
        /// The chosen device was listed but would not open: skipped until it is chosen again or until it leaves and returns.
        case yieldedFailed(String)

        /// The device uid to open, or nil for the system output.
        var effectiveUID: String? { if case .device(let u) = self { u } else { nil } }
    }

    private(set) var chosen: String?
    private(set) var failed: Set<String> = []

    init(chosen: String? = nil) { self.chosen = chosen }

    /// The person picked a device (nil is "system default"). Picking a device again gives it a fresh try.
    mutating func choose(_ uid: String?) {
        chosen = uid
        if let uid { failed.remove(uid) }
    }

    /// The device would not open.
    mutating func openFailed(_ uid: String) { failed.insert(uid) }

    /// The list of devices changed. A failure is forgotten once the device has left the list, so it gets a fresh try when it returns.
    mutating func listChanged(available: [MusicOutputDeviceInfo]) {
        let live = Set(available.map(\.uid))
        failed = failed.filter { live.contains($0) }
    }

    func resolve(available: [MusicOutputDeviceInfo]) -> Resolution {
        guard let c = chosen else { return .systemDefault }
        guard available.contains(where: { $0.uid == c }) else { return .yieldedMissing(c) }
        if failed.contains(c) { return .yieldedFailed(c) }
        return .device(c)
    }
}

/// The device list, the remembered choice and the hand-over to the player. Main-actor owned.
@MainActor @Observable
final class MusicOutputDevices {
    static let uidKey = "music.output.deviceUID"
    static let nameKey = "music.output.deviceName"

    private(set) var available: [MusicOutputDeviceInfo] = []
    private(set) var resolution: MusicOutputDevicePolicy.Resolution = .systemDefault
    /// The chosen device's name as last seen, so "X is not connected" can still say X.
    private(set) var chosenName: String?
    var chosenUID: String? { policy.chosen }

    @ObservationIgnored private var policy: MusicOutputDevicePolicy
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lister: @MainActor () -> [MusicOutputDeviceInfo]
    /// Opens `uid` for the player's engines (nil is the system output). Returns false when it would not open. Set by the player.
    @ObservationIgnored var apply: (@MainActor (String?) -> Bool)?
    @ObservationIgnored private var applied: String??
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watcher: AnyObject?

    init(defaults: UserDefaults = .standard, lister: (@MainActor () -> [MusicOutputDeviceInfo])? = nil) {
        self.defaults = defaults
        #if os(macOS)
        self.lister = lister ?? { MusicCoreAudioOutputs.list() }
        #else
        self.lister = lister ?? { [] }
        #endif
        let uid = defaults.string(forKey: Self.uidKey).flatMap { $0.isEmpty ? nil : $0 }
        policy = MusicOutputDevicePolicy(chosen: uid)
        chosenName = defaults.string(forKey: Self.nameKey)
    }

    /// Lists the devices, applies the choice and starts watching for devices coming and going. Safe to call again.
    func start() {
        guard !started else { return }
        started = true
        #if os(macOS)
        watcher = MusicCoreAudioOutputs.watch { [weak self] defaultChanged in
            MainActor.assumeIsolated { self?.refresh(defaultChanged: defaultChanged) }
        }
        #endif
        refresh()
    }

    /// The person picked a device; nil follows the system output.
    func choose(_ uid: String?) {
        policy.choose(uid)
        defaults.set(uid ?? "", forKey: Self.uidKey)
        if let uid {
            chosenName = available.first { $0.uid == uid }?.name ?? chosenName
            defaults.set(chosenName ?? "", forKey: Self.nameKey)
        } else {
            chosenName = nil
            defaults.removeObject(forKey: Self.nameKey)
        }
        refresh()
    }

    /// Re-reads the devices and applies what the policy says. `defaultChanged` re-applies even when nothing else moved, because a
    /// player that follows the system output must follow it to the new default.
    func refresh(defaultChanged: Bool = false) {
        available = lister()
        policy.listChanged(available: available)
        if let c = policy.chosen, let n = available.first(where: { $0.uid == c })?.name, n != chosenName {
            chosenName = n
            defaults.set(n, forKey: Self.nameKey)
        }
        var r = policy.resolve(available: available)
        let unchanged = applied.map { $0 == r.effectiveUID } ?? false
        let wantsApply = !unchanged || (defaultChanged && r.effectiveUID == nil)
        if wantsApply {
            if let uid = r.effectiveUID, apply?(uid) == false {
                policy.openFailed(uid)
                r = policy.resolve(available: available)
                _ = apply?(nil)
                applied = .some(nil)
            } else {
                if r.effectiveUID == nil { _ = apply?(nil) }
                applied = .some(r.effectiveUID)
            }
        }
        resolution = r
    }

    /// For an engine created after the choice was made: the device it should open (nil is the system output).
    var currentUID: String? { resolution.effectiveUID }
}

#if os(macOS)
// MARK: CoreAudio (macOS only)

/// Listing, looking up and assigning output devices through CoreAudio. Only reads and sets the device an engine points at: it never takes
/// the device from other apps.
enum MusicCoreAudioOutputs {
    private static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device that has at least one output channel.
    static func list() -> [MusicOutputDeviceInfo] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MusicOutputDeviceInfo(uid: uid, name: name)
        }
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var out = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), p, &size, &out)
        }
        return status == noErr && out != 0 ? out : nil
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var out = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &out) == noErr, out != 0 else { return nil }
        return out
    }

    /// Points an engine's output at `uid` (nil is the current system output). Returns false when the device cannot be found or refuses.
    @MainActor
    static func assign(uid: String?, to engine: AVAudioEngine) -> Bool {
        let target: AudioDeviceID
        if let uid { guard let d = deviceID(forUID: uid) else { return false }; target = d }
        else { guard let d = defaultOutputID() else { return false }; target = d }
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        do { try engine.outputNode.auAudioUnit.setDeviceID(target) } catch { return false }
        if wasRunning { do { try engine.start() } catch { return false } }
        return true
    }

    /// Calls `handler` (on the main queue) when devices come or go (`false`) or the system output changes (`true`). The returned object
    /// removes the listeners when it goes away.
    static func watch(_ handler: @escaping @Sendable (Bool) -> Void) -> AnyObject {
        Watcher(handler)
    }

    private final class Watcher {
        private let listChanged: AudioObjectPropertyListenerBlock
        private let defaultChanged: AudioObjectPropertyListenerBlock
        private var listAddress = MusicCoreAudioOutputs.address(kAudioHardwarePropertyDevices)
        private var defaultAddress = MusicCoreAudioOutputs.address(kAudioHardwarePropertyDefaultOutputDevice)

        init(_ handler: @escaping @Sendable (Bool) -> Void) {
            listChanged = { _, _ in handler(false) }
            defaultChanged = { _, _ in handler(true) }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddress, DispatchQueue.main, listChanged)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, defaultChanged)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddress, DispatchQueue.main, listChanged)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, defaultChanged)
        }
    }
}
#endif
