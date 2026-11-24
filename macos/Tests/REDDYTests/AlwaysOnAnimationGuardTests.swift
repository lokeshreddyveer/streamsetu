import Testing
import Foundation

/// Always-on animation guard: endless loops (repeatForever, TimelineView(.animation), repeating timers) in the screens and design system are
/// rare and each one costs real CPU while visible, so every use is listed here with the reason it is acceptable. A new one fails this test.
struct AlwaysOnAnimationGuardTests {
    /// file (relative to Sources/REDDY) -> (patterns allowed, count allowed, reason)
    static let allowed: [String: (Int, String)] = [
        "DesignSystem/Components/Motion/BrandMotion.swift": (4, "loader, empty art, shimmer, pulse halo: all stop with Reduce Motion, off screen and while the app is in the background (AppActivity)"),
        "DesignSystem/Components/Images/ArtworkImage.swift": (1, "placeholder shimmer: only while a picture loads, gated by AppActivity and Reduce Motion"),
        "DesignSystem/Components/StartScreen/StartScreenStyle.swift": (5, "welcome screen only; every loop is gated by StartMotionGate (window visible, app live, Reduce Motion)"),
        "Features/Onboarding/Views/OnboardingView.swift": (1, "first-run only; gated by startMotion"),
        "Features/Opening/OpeningRenderer.swift": (1, "launch animation: pauses when frozen or Reduce Motion, ends after a few seconds"),
        "Features/Opening/OpeningCoordinator.swift": (1, "one-shot timer (repeats: false) that ends the launch animation"),
        "Features/Opening/OpeningView.swift": (1, "launch animation: paused once frozen"),
        "DesignSystem/Components/PlayerControls/AudioOnlyBackdrop.swift": (1, "radio level bars: paused unless playing, the app is live and Reduce Motion is off"),
        "DesignSystem/Components/Sidebar/ReddySidebar.swift": (1, "drag auto-scroll timer: exists only during a drag"),
        "Features/Player/Views/MultiViewWindow.swift": (1, "60 s guide refresh in the multi-view window only"),
        "Features/Shared/Views/AssistantView.swift": (1, "thinking dots: only while Setu works; gated by AppActivity and Reduce Motion"),
    ]

    @Test func noNewEndlessLoops() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        let pattern = try NSRegularExpression(pattern: #"repeatForever|TimelineView\(\s*\.animation|Timer\.publish|Timer\(timeInterval|Timer\.scheduledTimer|CVDisplayLink|\.displayLink\(|options: \.repeating"#)
        var offenders: [String] = []
        for dir in ["Features", "DesignSystem"] {
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty)
            for f in files {
                let text = try String(contentsOf: f, encoding: .utf8)
                let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                let count = lines.reduce(0) { $0 + pattern.numberOfMatches(in: String($1), range: NSRange(location: 0, length: String($1).utf16.count)) }
                guard count > 0 else { continue }
                let rel = String(f.path.dropFirst(root.path.count + 1))
                if let a = Self.allowed[rel], count <= a.0 { continue }
                offenders.append("\(rel): \(count) (allowed \(Self.allowed[rel]?.0 ?? 0))")
            }
        }
        #expect(offenders.isEmpty, "Endless animation or timer added; make it a layer animation, gate it with AppActivity, or list it with a reason: \(offenders)")
    }

    @Test func swiftUIKenBurnsIsNotUsedOnTheMac() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
        let slideshow = try String(contentsOf: root.appendingPathComponent("DesignSystem/Components/Cards/FeaturedSlideshow.swift"), encoding: .utf8)
        let i = try #require(slideshow.range(of: ".kenBurns()"))
        #expect(slideshow[..<i.lowerBound].components(separatedBy: "#if os(macOS)").count > 1 && slideshow[..<i.lowerBound].range(of: "#else", options: .backwards) != nil)
        #expect(slideshow.contains("KenBurnsArtwork("))
    }
}
