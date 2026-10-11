import SwiftUI

enum LegalPage: String, CaseIterable, Identifiable {
    case privacy, terms, licenses
    var id: String { rawValue }
    var title: String { switch self { case .privacy: "Privacy Policy"; case .terms: "Terms of Use"; case .licenses: "Open-Source Licenses" } }
    var text: String { switch self { case .privacy: LegalText.privacy; case .terms: LegalText.terms; case .licenses: LegalText.licenses } }
}

/// Shows one of the legal documents. The same text is on the website; both come from legal/*.md.
struct LegalView: View {
    let page: LegalPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(page.text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                    let line = String(raw)
                    if line.hasPrefix("# ") { Text(line.dropFirst(2)).font(.title.bold()).padding(.bottom, 4) }
                    else if line.hasPrefix("## ") { Text(line.dropFirst(3)).font(.headline).padding(.top, 8) }
                    else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(inline(String(line.dropFirst(2)))) }.font(.callout)
                    } else { Text(inline(line)).font(.callout) }
                }
            }
            .frame(maxWidth: 720, alignment: .leading).padding(20).frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .background(ColorTokens.background)
        .foregroundStyle(ColorTokens.textPrimary)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
