import Foundation
#if STREAMSETU_MPV
import Libmpv
#endif

struct mpv_event { var event_id: Int32; var error: Int32; var reply_userdata: UInt64; var data: UnsafeMutableRawPointer? }
struct mpv_render_param { var type: Int32; var data: UnsafeMutableRawPointer? }
struct mpv_event_end_file { var reason: Int32; var error: Int32 }
struct mpv_event_log_message { var prefix: UnsafePointer<CChar>?; var level: UnsafePointer<CChar>?; var text: UnsafePointer<CChar>?; var log_level: Int32 }

enum MPVConst {
    static let formatFlag: Int32 = 3, formatInt64: Int32 = 4, formatDouble: Int32 = 5
    static let evShutdown: Int32 = 1, evLog: Int32 = 2, evStartFile: Int32 = 6, evEndFile: Int32 = 7, evFileLoaded: Int32 = 8
    static let evPlaybackRestart: Int32 = 21
    static let endEOF: Int32 = 0, endStop: Int32 = 2, endQuit: Int32 = 3, endError: Int32 = 4
    static let renderAPIType: Int32 = 1, renderSWSize: Int32 = 17, renderSWFormat: Int32 = 18, renderSWStride: Int32 = 19, renderSWPointer: Int32 = 20
    static let updateFrame: UInt64 = 1
    static let errUnknownFormat: Int32 = -17, errNothingToPlay: Int32 = -16, errLoadingFailed: Int32 = -13
}

/// libmpv is loaded at runtime. REDDY runs without it; the MPV engine simply reports itself unavailable.
/// Search order: the app bundle's Frameworks folder, then common Homebrew locations.
final class MPVLibrary: @unchecked Sendable {
    static let shared = MPVLibrary()

    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias SetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Command = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias GetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
    typealias GetPropertyString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias WaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
    typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias RequestLog = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias RenderCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    typealias RenderRender = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    typealias RenderFree = @convention(c) (OpaquePointer?) -> Void
    typealias RenderCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias RenderSetCallback = @convention(c) (OpaquePointer?, RenderCallback?, UnsafeMutableRawPointer?) -> Void
    typealias RenderUpdate = @convention(c) (OpaquePointer?) -> UInt64

    let path: String?
    /// Why loading failed (for diagnostics), or nil when libmpv is loaded / simply not installed.
    private(set) var loadError: String?
    private var handle: UnsafeMutableRawPointer?
    // Set when the library is loaded, and by tests that stand in for libmpv (see `init(testing:)`); nothing else changes them.
    var create: Create?, initialize: Initialize?, terminateDestroy: Destroy?
    var setOption: SetString?, setProperty: SetString?, command: Command?
    var getProperty: GetProperty?, getPropertyString: GetPropertyString?, free: FreeFn?
    var wakeup: (@convention(c) (OpaquePointer?) -> Void)?
    var waitEvent: WaitEvent?, errorString: ErrorString?, requestLog: RequestLog?
    var renderCreate: RenderCreate?, renderRender: RenderRender?, renderFree: RenderFree?
    var renderSetCallback: RenderSetCallback?, renderUpdate: RenderUpdate?

    /// A library with nothing loaded. A test fills in the functions it needs, so the engine can be driven without libmpv.
    init(testing: Void) { path = nil }

    var isAvailable: Bool { create != nil && renderCreate != nil && waitEvent != nil }

    /// Where libmpv may be loaded from.
    ///
    /// A build signed by a team (the one that ships) loads ONLY the library bundled inside the app, which is signed with the app's own identity. The environment variable and the Homebrew folders are
    /// ignored there, however they are set: this app is allowed to load a library signed by another identity (the entitlement it ships with), so a library planted in a folder the user can write to, or
    /// named by an environment variable (`launchctl setenv`), would otherwise be loaded into a notarized app that holds the user's Photos access and Keychain items.
    /// An unsigned or ad-hoc build (a developer's own build, the test runs) may also use `REDDY_LIBMPV` and a Homebrew install: an explicit developer mode that cannot be the shipped app.
    static func searchPaths(signedBuild: Bool = StandardCredentialStore.hasStableIdentity(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            frameworks: String? = Bundle.main.privateFrameworksURL?.path) -> [String] {
        var p: [String] = []
        if let fw = frameworks { p += ["\(fw)/libmpv.2.dylib", "\(fw)/libmpv.dylib"] }
        guard !signedBuild else { return p }
        if let override = environment["REDDY_LIBMPV"] { p.insert(override, at: 0) }
        p += ["/opt/homebrew/lib/libmpv.dylib", "/opt/homebrew/opt/mpv/lib/libmpv.dylib", "/usr/local/lib/libmpv.dylib", "/usr/local/opt/mpv/lib/libmpv.dylib"]
        return p
    }

    #if STREAMSETU_MPV
    /// iOS cannot load a library at runtime, so libmpv (MPVKit) is linked into the app and the same table is filled directly.
    private init() {
        path = "MPVKit (linked)"
        create = mpv_create
        initialize = mpv_initialize
        terminateDestroy = mpv_terminate_destroy
        setOption = mpv_set_option_string
        setProperty = mpv_set_property_string
        command = mpv_command
        getProperty = unsafeBitCast(mpv_get_property as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Libmpv.mpv_format, UnsafeMutableRawPointer?) -> Int32, to: GetProperty.self)
        getPropertyString = mpv_get_property_string
        free = mpv_free
        wakeup = mpv_wakeup
        waitEvent = unsafeBitCast(mpv_wait_event as @convention(c) (OpaquePointer?, Double) -> UnsafeMutablePointer<Libmpv.mpv_event>?, to: WaitEvent.self)
        errorString = mpv_error_string
        requestLog = mpv_request_log_messages
        renderCreate = unsafeBitCast(mpv_render_context_create as @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<Libmpv.mpv_render_param>?) -> Int32, to: RenderCreate.self)
        renderRender = unsafeBitCast(mpv_render_context_render as @convention(c) (OpaquePointer?, UnsafeMutablePointer<Libmpv.mpv_render_param>?) -> Int32, to: RenderRender.self)
        renderFree = mpv_render_context_free
        renderSetCallback = mpv_render_context_set_update_callback
        renderUpdate = mpv_render_context_update
    }
    #else
    private init() {
        var found: String?
        var h: UnsafeMutableRawPointer?
        for candidate in Self.searchPaths() where FileManager.default.fileExists(atPath: candidate) {
            if let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) { h = handle; found = candidate; break }
            loadError = dlerror().map { String(cString: $0) } ?? "could not load \(candidate)"
        }
        handle = h; path = found
        if h != nil { loadError = nil }
        guard h != nil else { return }
        create = sym("mpv_create"); initialize = sym("mpv_initialize"); terminateDestroy = sym("mpv_terminate_destroy")
        setOption = sym("mpv_set_option_string"); setProperty = sym("mpv_set_property_string"); command = sym("mpv_command")
        getProperty = sym("mpv_get_property"); getPropertyString = sym("mpv_get_property_string"); free = sym("mpv_free")
        wakeup = sym("mpv_wakeup")
        waitEvent = sym("mpv_wait_event"); errorString = sym("mpv_error_string"); requestLog = sym("mpv_request_log_messages")
        renderCreate = sym("mpv_render_context_create"); renderRender = sym("mpv_render_context_render")
        renderFree = sym("mpv_render_context_free"); renderSetCallback = sym("mpv_render_context_set_update_callback")
        renderUpdate = sym("mpv_render_context_update")
    }
    #endif

    private func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    func errorMessage(_ code: Int32) -> String { errorString?(code).map { String(cString: $0) } ?? "error \(code)" }
}
