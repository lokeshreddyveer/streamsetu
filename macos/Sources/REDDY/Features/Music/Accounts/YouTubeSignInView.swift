import SwiftUI
import WebKit
import Observation

// Sign-in to YouTube Music in a persistent web view. The page runs Google's own sign-in; we only read the youtube.com cookies afterwards.
// This web view has no bridge into the app: no script message handler is ever added to it.

@MainActor @Observable
final class YouTubeSignInModel: NSObject, WKNavigationDelegate {
    enum Phase: Equatable { case preparing, loading, waiting, finishing, failed(String) }

    private(set) var phase: Phase = .preparing
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let manager: YouTubeMusicAccountManager
    @ObservationIgnored private let addAccount: Bool
    @ObservationIgnored private var checking = false
    @ObservationIgnored var onFinished: (() -> Void)?

    init(manager: YouTubeMusicAccountManager, addAccount: Bool) {
        self.manager = manager
        self.addAccount = addAccount
        self.webView = YTMWebSession.makeWebView()
        super.init()
        webView.navigationDelegate = self
    }

    /// "Add account" first clears the web view's Google and YouTube cookies, because it holds exactly one Google session. If that fails it stops
    /// with an error rather than quietly signing the same account in again.
    func start() async {
        phase = .preparing
        if addAccount {
            guard await YTMWebSession.clearGoogleSession() else {
                phase = .failed(YTMAccountError.cannotClearWebSession.errorDescription ?? "Could not start.")
                return
            }
        }
        guard let url = addAccount ? YTMWebSession.addAccountURL : YTMWebSession.signInURL else { phase = .failed("Could not open the sign-in page."); return }
        phase = .loading
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == "music.youtube.com" else { if phase == .loading { phase = .waiting }; return }
        Task { await checkLogin() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled { return }
        phase = .failed("Could not load the page. Check your connection and try again.")
    }

    /// The page reached music.youtube.com. The cookie store is read off the navigation callback (reading inside it can stall), up to six
    /// times 500 ms apart, until the login cookie shows. If it never does the page stays open and we keep watching.
    private func checkLogin() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        phase = .finishing
        guard let jar = await YTMWebSession.waitForLoginJar() else { phase = .waiting; return }
        do {
            _ = try await manager.signIn(cookieHeader: jar.header)
            onFinished?()
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Sign-in failed.")
        }
    }

    var statusText: String {
        switch phase {
        case .preparing: "Getting ready"
        case .loading: "Loading"
        case .waiting: "Sign in with your Google account"
        case .finishing: "Finishing sign-in"
        case .failed(let m): m
        }
    }
}

#if os(macOS)
struct YTMWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct YTMWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

struct YouTubeSignInView: View {
    let manager: YouTubeMusicAccountManager
    let addAccount: Bool
    let onClose: () -> Void
    @State private var model: YouTubeSignInModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to YouTube Music").font(Typography.title).accessibilityAddTraits(.isHeader)
                    if let model {
                        Text(verbatim: model.statusText).font(Typography.caption)
                            .foregroundStyle(isFailed(model) ? ColorTokens.danger : ColorTokens.textSecondary)
                    }
                }
                Spacer()
                if let model, isFailed(model) {
                    Button("Try again") { Task { await model.start() } }.musicButton(.secondary).accessibilityLabel("Try signing in again").atlas("control.music.accountsTrySigningInAgain")
                }
                Button("Cancel") { onClose() }.musicButton(.secondary).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel sign-in").atlas("control.music.accountsCancelSignIn")
            }
            .padding(14)
            Divider().overlay(ColorTokens.line)
            if let model { YTMWebViewHost(webView: model.webView).accessibilityLabel("Google sign-in page") }
            else { Spacer() }
        }
        #if os(macOS)
        .frame(width: 480, height: 720)
        #endif
        .task {
            let m = YouTubeSignInModel(manager: manager, addAccount: addAccount)
            m.onFinished = { onClose() }
            model = m
            await m.start()
        }
    }

    private func isFailed(_ m: YouTubeSignInModel) -> Bool { if case .failed = m.phase { true } else { false } }
}
