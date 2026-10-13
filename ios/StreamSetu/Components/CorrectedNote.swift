import SwiftUI

/// "Showing results for …" when a misspelt search was corrected.
struct CorrectedNote: View {
    let original: String
    let corrected: String
    var body: some View {
        Text("Showing results for “\(corrected)” instead of “\(original)”").appFont(12).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
    }
}
