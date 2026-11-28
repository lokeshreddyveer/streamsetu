import Foundation
import SwiftUI
import Testing
@testable import REDDY

#if os(macOS)
@Suite("Get set up: the sheet")
struct FirstRunSetupShotsTests {
    @Test func everyListedServiceHasAUniqueIdAndAName() {
        let listed = ProviderRegistry.standard.listed(on: .macOS)
        print("SETUP-SERVICES", listed.map { "\($0.id.rawValue)=\($0.displayName)" })
        #expect(Set(listed.map(\.id)).count == listed.count, "a service twice would draw twice and collide in the grid")
        #expect(listed.allSatisfy { !$0.displayName.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Writes one picture per step to the folder named by SS_RENDER_SETUP (nothing happens without it), for looking at.
    @MainActor @Test func theStepsAreWrittenWhenAsked() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SS_RENDER_SETUP"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        await ServiceIconStore.preloadAndWait()
        for step in 0..<3 {
            let r = ImageRenderer(content: FirstRunSetupSheet(openMusic: {}, done: {}, initialStep: step, scrolls: false).environment(\.colorScheme, .dark).frame(width: 1200, height: 780))
            r.scale = 1
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: dir + "/step\(step + 1).png")) }
        }
    }
}
#endif
