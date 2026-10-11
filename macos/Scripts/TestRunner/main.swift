// Minimal Swift Testing host for machines with only the Command Line Tools (no Xcode), where `swift test`
// does not launch swift-testing bundles. Usage: test-runner <path-to-REDDYPackageTests binary> [filter]
import Foundation

typealias EntryPoint = @convention(thin) @Sendable (
    _ configurationJSON: UnsafeRawBufferPointer?,
    _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
) async throws -> Bool

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    var started = 0, passed = 0, failedTests = Set<String>(), issues: [String] = [], names: [String: String] = [:]
    func with(_ f: (Tally) -> Void) { lock.lock(); f(self); lock.unlock() }
}

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count >= 2 else { print("usage: test-runner <test binary> [filter]"); exit(2) }
guard let handle = dlopen(CommandLine.arguments[1], RTLD_NOW) else { print("cannot load bundle: \(String(cString: dlerror()))"); exit(2) }
guard let sym = dlsym(handle, "swt_abiv0_getEntryPoint") else { print("swift-testing entry point not found"); exit(2) }
let getEntry = unsafeBitCast(sym, to: (@convention(c) () -> UnsafeRawPointer).self)
let entry = unsafeBitCast(getEntry(), to: EntryPoint.self)

let tally = Tally()
var config: [String: Any] = ["verbosity": -1]
if CommandLine.arguments.count > 2 { config["filter"] = [CommandLine.arguments[2]] }
let configData = try JSONSerialization.data(withJSONObject: config)

let cfg = UnsafeMutableRawBufferPointer.allocate(byteCount: configData.count, alignment: 1)
configData.copyBytes(to: cfg)
defer { cfg.deallocate() }
let ok: Bool = try await {
    try await entry(UnsafeRawBufferPointer(cfg)) { record in
        guard let obj = try? JSONSerialization.jsonObject(with: Data(record)) as? [String: Any],
              let kind = obj["kind"] as? String, let payload = obj["payload"] as? [String: Any] else { return }
        if kind == "test", let id = payload["id"] as? String, let name = payload["name"] as? String { tally.with { $0.names[id] = name } }
        guard kind == "event", let ek = payload["kind"] as? String else { return }
        let id = payload["testID"] as? String ?? ""
        switch ek {
        case "testStarted": tally.with { $0.started += 1 }
        case "issueRecorded":
            let issue = payload["issue"] as? [String: Any]
            guard (issue?["isFailure"] as? Bool) ?? true else { return }
            let msgs = (payload["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
            let loc = issue?["sourceLocation"] as? [String: Any]
            let where_ = "\((loc?["fileID"] as? String) ?? ""):\((loc?["line"] as? Int) ?? 0)"
            tally.with { $0.failedTests.insert(id); $0.issues.append("\($0.names[id] ?? id) — \(msgs) [\(where_)]") }
        default: break
        }
    }
}()
tally.with { t in
    let failed = t.failedTests.count
    print("\n== \(t.started) tests run, \(max(0, t.started - failed)) passed, \(failed) failed ==")
    for i in t.issues { print("  ✘ \(i)") }
}
exit(ok ? 0 : 1)
