import AppKit
import SwiftUI
import Observation


/// The window side of fullscreen, so the state machine can be tested without a real window server.
@MainActor
protocol FullscreenWindowing: AnyObject {
    var onDidEnter: (() -> Void)? { get set }
    var onDidExit: (() -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    /// Shows the window over the main window's frame and calls back when it is in place.
    func present(over mainWindow: NSWindow?, completion: @escaping () -> Void)
    /// Called once the system has finished leaving fullscreen. The window goes away; the video is already shown again by
    /// the view the user came from.
    func finishExit(completion: @escaping () -> Void)
    func toggleNativeFullscreen()
    func dismiss()
}

/// Fullscreen playback in its own native window. The main REDDY window is never touched: its frame, sidebar,
/// selected section and scroll position stay as they are while the video fills a separate Space.
///
/// There is one playback session. Nothing here loads or restarts a stream; the video layers simply move to the
/// fullscreen window (see `PlaybackCoordinator.surfaceOwner`) and move back when the window has really left fullscreen.
/// Every phase change comes from an AppKit window callback, never from a timer.
@MainActor @Observable
final class FullscreenController {
    private(set) var phase: FullscreenPhase = .windowed
    private let playback: PlaybackCoordinator
    private let makeWindow: () -> FullscreenWindowing
    private var window: FullscreenWindowing?
    private var desired = false

    init(playback: PlaybackCoordinator, makeWindow: @escaping () -> FullscreenWindowing) {
        self.playback = playback; self.makeWindow = makeWindow
    }

    /// Ask for fullscreen on or off. Requests made mid-transition are remembered and applied when it finishes,
    /// so rapid toggling settles on the last request instead of fighting the animation.
    func request(_ on: Bool) {
        desired = on
        advance()
    }

    private func advance() {
        switch (phase, desired) {
        case (.windowed, true):
            guard playback.current != nil else { desired = false; playback.isFullscreen = false; return }
            let w = makeWindow()
            w.onDidEnter = { [weak self] in self?.didEnter() }
            w.onDidExit = { [weak self] in self?.didExit() }
            w.onClosed = { [weak self] in self?.closedExternally() }
            window = w
            let main = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
            // Where the video was when fullscreen was asked for. Leaving fullscreen returns to a visible player: the Live TV
            // preview when that is where it was, otherwise the expanded player. It never retreats into the small bar.
            if playback.surfaceOwner == .bar || playback.surfaceOwner == .expanded { playback.restoreExpandedAfterFullscreen = true }
            set(.entering)                         // the video moves to the new window before it animates
            w.present(over: main) { [weak self] in
                guard let self, self.phase == .entering else { return }
                self.window?.toggleNativeFullscreen()
            }
        case (.fullscreen, false):
            set(.exiting)
            window?.toggleNativeFullscreen()
        default: break                              // mid-transition: reconciled in didEnter / didExit
        }
    }

    private func set(_ p: FullscreenPhase) { phase = p; playback.fullscreenPhase = p }

    private func didEnter() {
        guard phase == .entering else { return }
        set(.fullscreen)
        advance()
    }

    private func didExit() {
        // Leaving by the green button, the menu or Escape handled by the system arrives here without a request.
        if desired { desired = false; playback.isFullscreen = false }
        guard let w = window else { return }
        w.finishExit { [weak self] in
            guard let self else { return }
            self.window = nil
            self.set(.windowed)                     // the view the user came from takes the video back
            // Let that hand-over render before the fullscreen window goes away (no blank frame).
            DispatchQueue.main.async { [weak self] in
                w.dismiss()
                guard let self else { return }
                self.playback.finishFullscreen()
                self.advance()                      // a request that arrived during the exit
            }
        }
    }

    private func closedExternally() {
        window = nil; desired = false
        set(.windowed)
        playback.isFullscreen = false
        playback.finishFullscreen()
    }
}

// MARK: - the real window

@MainActor
final class PlayerFullscreenWindow: NSWindow, NSWindowDelegate, FullscreenWindowing {
    var onDidEnter: (() -> Void)?
    var onDidExit: (() -> Void)?
    var onClosed: (() -> Void)?
    private var closing = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init<Content: View>(title: String, content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.title = title
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        backgroundColor = .black
        collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: content)
        delegate = self
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
    }

    func present(over main: NSWindow?, completion: @escaping () -> Void) {
        // Open on the screen the app is on, so fullscreen goes to that display.
        setFrame(main?.frame ?? NSRect(x: 80, y: 80, width: 1100, height: 700), display: false)
        makeKeyAndOrderFront(nil)
        completion()
    }

    func finishExit(completion: @escaping () -> Void) { completion() }

    func toggleNativeFullscreen() { toggleFullScreen(nil) }

    func dismiss() { closing = true; orderOut(nil); close() }

    func windowDidEnterFullScreen(_ notification: Notification) { onDidEnter?() }
    func windowDidExitFullScreen(_ notification: Notification) { onDidExit?() }
    func windowWillClose(_ notification: Notification) { if !closing { onClosed?() } }
}

/// Fullscreen content: the video, the same controls, and Escape / double-click / the button all leave fullscreen.
struct FullscreenPlayerRoot: View {
    let container: AppContainer
    @State private var program: EPGProgram?
    @State private var nextProgram: EPGProgram?

    var body: some View {
        let p = container.playback
        FullscreenPlayerView(playback: p, program: program, nextProgram: nextProgram) { p.isFullscreen = false }
            .environment(container.settings).environment(\.container, container)
            .reddyTheme(container.settings)
            .task(id: p.currentChannel?.id) {
                guard let id = p.currentChannel?.id else { program = nil; nextProgram = nil; return }
                let list = await Task.detached { (try? container.epgRepo.nowNext(channelIDs: [id], at: Date()))?[id] ?? [] }.value
                program = list.first { $0.isLive() }; nextProgram = list.first { $0.start > Date() }
            }
    }
}
