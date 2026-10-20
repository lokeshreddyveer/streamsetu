import SwiftUI

/// Where a title sits: the folder it is in, as "In folder  ENGLISH | NETFLIX". Choosing it opens that folder. It tells the person where a title found by search lives, so they
/// can browse what is next to it.
struct FolderPathButton: View {
    let name: String?
    let open: () -> Void

    var body: some View {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(ColorTokens.accentDefault)
                    Text("In folder").foregroundStyle(.secondary)
                    Text(name).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("In folder \(name). Opens the folder.")
        }
    }
}
