import Foundation
import Testing
@testable import AtlasScanCore

@Suite struct ScannerTests {
    func scan(_ s: String) -> [Hit] { Scanner.scan(source: s, file: "macos/Sources/REDDY/Features/Home/X.swift", folder: "macos/Features/Home") }

    @Test func unmarkedButtonIsAViolation() {
        let r = Report.evaluate(hits: scan("struct V: View { var body: some View { Button(\"Go\") { } } }"), exemptions: .init(), files: 1)
        #expect(r.violations.count == 1 && r.violations[0].construct == "Button")
        #expect(!r.problems(acceptingExemptions: false).isEmpty)
    }

    @Test func markerAnywhereInTheChainPasses() {
        let src = """
        struct V: View { var body: some View {
            Button("Go") { }.buttonStyle(.plain).atlas("control.go")
            Toggle("On", isOn: $x).atlas("control.toggle").padding()
            Text("x").onTapGesture { }.atlas("control.tap")
            Picker("P", selection: $p) { }.atlasCovers("setting.p")
        } }
        """
        let r = Report.evaluate(hits: scan(src), exemptions: .init(), files: 1)
        #expect(r.hits.count == 4 && r.marked.count == 4 && r.violations.isEmpty)
    }

    @Test func markerOnAnotherViewDoesNotCount() {
        let src = "struct V: View { var body: some View { VStack { Button(\"a\") { }; Text(\"b\").atlas(\"x\") } } }"
        #expect(Report.evaluate(hits: scan(src), exemptions: .init(), files: 1).violations.count == 1)
    }

    @Test func docCommentCoversAHelperView() {
        let src = """
        /// atlas: exempt decorative close button
        struct Close: View { var body: some View { Button("x") { } } }
        """
        let r = Report.evaluate(hits: scan(src), exemptions: .init(), files: 1)
        #expect(r.documented.count == 1 && r.violations.isEmpty)
    }

    @Test func exemptionNeedsAReasonAndGrowthIsReviewed() {
        let h = scan("struct V: View { var body: some View { Button(\"a\") { } } }")
        var f = ExemptionFile(approvedCount: 0, exemptions: [Exemption(file: h[0].file, symbol: h[0].symbol, kind: "Button", reason: "player seek handle, not a feature")])
        var r = Report.evaluate(hits: h, exemptions: f, files: 1)
        #expect(r.violations.isEmpty && r.exempt.count == 1)
        #expect(r.problems(acceptingExemptions: false).count == 1)       // grew past the reviewed size
        #expect(r.problems(acceptingExemptions: true).isEmpty)
        f.exemptions[0].reason = "short"
        r = Report.evaluate(hits: h, exemptions: f, files: 1)
        #expect(r.problems(acceptingExemptions: true).count == 1)
    }

    @Test func staleExemptionIsReported() {
        let f = ExemptionFile(approvedCount: 1, exemptions: [Exemption(file: "gone.swift", symbol: "Gone.body", kind: "Button", reason: "was a player handle")])
        #expect(Report.evaluate(hits: [], exemptions: f, files: 0).staleExemptions.count == 1)
    }

    @Test func iconOnlyButtonNeedsALabel() {
        let bad = "struct V: View { var body: some View { Button { } label: { Image(systemName: \"xmark\") }.atlas(\"a\") } }"
        #expect(Report.evaluate(hits: scan(bad), exemptions: .init(), files: 1).violations.map(\.kind) == [.iconOnly])
        let good = "struct V: View { var body: some View { Button { } label: { Image(systemName: \"xmark\") }.accessibilityLabel(\"Close\").atlas(\"a\") } }"
        #expect(Report.evaluate(hits: scan(good), exemptions: .init(), files: 1).violations.isEmpty)
        let text = "struct V: View { var body: some View { Button { } label: { Label(\"Close\", systemImage: \"xmark\") }.atlas(\"a\") } }"
        #expect(Report.evaluate(hits: scan(text), exemptions: .init(), files: 1).violations.isEmpty)
    }

    @Test func plainModifiersAndOtherCallsAreIgnored() {
        let src = "struct V: View { var body: some View { Text(\"a\").padding().foregroundStyle(.red); Image(\"b\") } }"
        #expect(scan(src).isEmpty)
    }

    @Test func folderGrouping() {
        #expect(Runner.folder(of: "macos/Sources/REDDY/Features/Home/HomeScreen.swift") == "macos/Features/Home")
        #expect(Runner.folder(of: "ios/StreamSetu/Screens/RootView.swift") == "ios/Screens")
    }
}
