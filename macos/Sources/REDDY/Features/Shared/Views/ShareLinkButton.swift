import SwiftUI

/// "Share Link" in a context menu: the system share sheet with a streamsetu:// link to the channel or title.
struct ShareLinkButton: View {
    let link: URL?
    let name: String

    var body: some View {
        if let link {
            ShareLink(item: link, subject: Text(name), message: Text("Open “\(name)” in StreamSetu")) { Label("Share Link", systemImage: "square.and.arrow.up") }
        }
    }
}
