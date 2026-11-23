import SwiftUI

/// The one folder header: a lock when locked, the folder's name, and a quiet count (smaller, dim, in brackets, on the name's baseline, never wrapping).
/// Movies, Series and Live TV folders, on iPhone, iPad and Mac, all draw their header through this, so they cannot drift apart (FolderHeaderTests scans for it).
struct FolderHeaderLabel: View {
    enum Noun: String { case title, channel
        func spoken(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? rawValue : rawValue + "s")" } }

    let row: FolderRowsModel.Row
    var noun: Noun = .title
    var nameSize: CGFloat = 18
    var countSize: CGFloat = 13
    var nameWeight: Font.Weight = .semibold
    var tracking: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.locked { Image(systemName: "lock.fill").font(.system(size: countSize * scale)).foregroundStyle(.secondary) }
            Text(row.display).font(.system(size: nameSize * scale, weight: nameWeight)).tracking(tracking).lineLimit(1).truncationMode(.tail)
            if !row.locked { Text(row.countText).font(.system(size: countSize * scale)).foregroundStyle(.tertiary).lineLimit(1).fixedSize().layoutPriority(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityTitle(noun))
    }
}

extension FolderRowsModel.Row {
    /// "Name, 1,058 titles" / "Name, 12 channels" / "Name, locked folder".
    func accessibilityTitle(_ noun: FolderHeaderLabel.Noun) -> String { locked ? "\(spokenName), locked folder" : "\(spokenName), \(noun.spoken(count))" }
}
