import Foundation
// Minimal Hardened-Runtime harness: loads the bundled libmpv and starts playback.
// usage: HardenedMPVCheck <libmpv.dylib> <media> [unsafe]   ("unsafe" skips the isolation options and is expected to be killed)
// Keep the option list in sync with MPVConfiguration.isolationOptions.
typealias Create = @convention(c) () -> OpaquePointer?
typealias Init = @convention(c) (OpaquePointer?) -> Int32
typealias SetOpt = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
typealias Cmd = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
typealias Wait = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
let args = CommandLine.arguments
guard let h = dlopen(args[1], RTLD_NOW) else { print("dlopen failed: \(String(cString: dlerror()))"); exit(2) }
func sym<T>(_ n: String) -> T { unsafeBitCast(dlsym(h, n)!, to: T.self) }
let create: Create = sym("mpv_create"), initialize: Init = sym("mpv_initialize"), setOpt: SetOpt = sym("mpv_set_option_string"), cmd: Cmd = sym("mpv_command"), wait: Wait = sym("mpv_wait_event")
let ctx = create()
var opts = [("vo", "null"), ("ao", "null"), ("terminal", "no"), ("osc", "no")]
if !(args.count > 3 && args[3] == "unsafe") {
    opts += [("load-scripts", "no"), ("config", "no"), ("load-auto-profiles", "no"), ("load-osd-console", "no"), ("load-stats-overlay", "no"), ("load-commands", "no"), ("load-positioning", "no"), ("load-select", "no"), ("load-console", "no"), ("load-context-menu", "no"), ("ytdl", "no"), ("input-default-bindings", "no")]
}
for (k, v) in opts { _ = setOpt(ctx, k, v) }
guard initialize(ctx) == 0 else { print("init failed"); exit(3) }
var c: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("loadfile")), UnsafePointer(strdup(args[2])), UnsafePointer(strdup("replace")), nil]
_ = cmd(ctx, &c)
var loaded = false
let end = Date().addingTimeInterval(6)
while Date() < end, let ev = wait(ctx, 0.3) {
    let id = ev.assumingMemoryBound(to: Int32.self).pointee
    if id == 8 { loaded = true }       // MPV_EVENT_FILE_LOADED
    if id == 21 { print("PLAYBACK_RESTART"); break }
}
print(loaded ? "OK file loaded, no crash" : "no file-loaded event")
exit(0)
