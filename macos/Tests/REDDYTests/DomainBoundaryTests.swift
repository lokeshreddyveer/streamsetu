import Testing
import Foundation
@testable import REDDY

/// Source scans: the shared Domain layer stays free of WebKit, AppKit and SwiftUI, and service names live only in the catalog.
@Suite("Streaming domain boundary") struct DomainBoundaryTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/REDDY")
    private func files(_ rel: String) throws -> [(String, String)] {
        let dir = Self.root.appendingPathComponent(rel)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
    /// Code without comments and string literals, so prose cannot trip the scan.
    private func code(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line); if let r = l.range(of: "//") { l = String(l[..<r.lowerBound]) }
            return l
        }.joined(separator: "\n")
    }

    @Test func domainAndPolicyImportOnlyFoundationAndObservation() throws {
        for dir in ["Services/Streaming/Domain", "Services/Streaming/Policy"] {
            let fs = try files(dir); #expect(!fs.isEmpty)
            for (name, text) in fs {
                for line in text.split(separator: "\n") where line.hasPrefix("import ") { #expect(["import Foundation", "import Observation"].contains(String(line)), Comment(rawValue: "\(name): \(line)")) }
                let c = code(text)
                for token in ["WKWebView", "WKWebsiteDataStore", "WKNavigation", "NSWorkspace", "NSView", "NSApplication", "NSAlert", "UIKit", "AppKit", "SwiftUI", "import WebKit"] { #expect(!c.contains(token), Comment(rawValue: "\(name) uses \(token)")) }
            }
        }
    }

    @Test func serviceIdsAppearOnlyInTheCatalog() throws {
        let ids = ProviderID.allCases.map(\.rawValue)
        for dir in ["Services/Streaming/Domain", "Services/Streaming/Policy"] {
            for (name, text) in try files(dir) where name != "ProviderCatalog.swift" {
                let c = code(text)
                for id in ids { #expect(!c.contains("\"\(id)\""), Comment(rawValue: "\(name) names \(id)")); #expect(!c.contains(".\(id)\n") && !c.contains(".\(id),") && !c.contains(".\(id)]"), Comment(rawValue: "\(name) uses .\(id)")) }
            }
        }
    }

    @Test func storeIdentitiesAreCreatedOnlyThroughTheLiteralType() throws {
        for (name, text) in try files("Services/Streaming/Domain") where name != "ProviderDefinition.swift" { #expect(!code(text).contains("UUID(uuidString:"), Comment(rawValue: name)) }
    }

    @Test func domainFilesAreListedForTheIOSTarget() throws {
        let list = try String(contentsOf: Self.root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/SharedSources.txt"), encoding: .utf8)
        let lines = Set(list.split(separator: "\n").map(String.init))
        for (name, _) in try files("Services/Streaming/Domain") { #expect(lines.contains("Services/Streaming/Domain/\(name)"), Comment(rawValue: name)) }
        #expect(lines.contains("Services/Streaming/Policy/ProviderURLPolicy.swift") && lines.contains("Application/ServiceNavigation.swift"))
        #expect(!lines.contains("Services/Streaming/Policy/NavigationAdapter.swift"))
    }
}
