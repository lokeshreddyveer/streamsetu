import SwiftUI

/// The rules of the comments panel that need no screen, so they can be tested.
enum MusicCommentsLogic {
    /// New rows only: a comment already shown (by id) is dropped when a later page repeats it.
    static func appended(_ existing: [YTMCommentThread], _ incoming: [YTMCommentThread]) -> [YTMCommentThread] {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    /// The panel follows the playing track unless a draft is being written or a send is pending.
    static func followsPlaying(hasDraft: Bool, sending: Bool) -> Bool { !hasDraft && !sending }

    /// Long text is clamped to this many characters or lines until "Show more".
    static let clampCharacters = 280
    static let clampLines = 6
    static func needsClamp(_ text: String) -> Bool {
        text.count > clampCharacters || text.split(separator: "\n", omittingEmptySubsequences: false).count > clampLines
    }

    static func countLabel(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text == "1" ? Localized.string("1 comment") : Localized.string("%@ comments", text)
    }

    static func repliesLabel(_ count: String?) -> String {
        guard let count, !count.isEmpty else { return Localized.string("Show replies") }
        return count == "1" ? Localized.string("1 reply") : Localized.string("%@ replies", count)
    }

    /// Which count to show for a vote state: the service sends one string for each.
    static func likeCount(_ c: YTMComment) -> String? { c.vote == .liked ? c.likeCountLiked : c.likeCountNotLiked }

    /// The action token a vote button replays, or nil when the service did not offer it.
    static func likeToken(_ c: YTMComment) -> String? { c.vote == .liked ? c.unlikeAction : c.likeAction }
    static func dislikeToken(_ c: YTMComment) -> String? { c.vote == .disliked ? c.undislikeAction : c.dislikeAction }

    static func voteAfterLike(_ v: YTMVote) -> YTMVote { v == .liked ? .none : .liked }
    static func voteAfterDislike(_ v: YTMVote) -> YTMVote { v == .disliked ? .none : .disliked }
}

@MainActor @Observable
final class MusicCommentsModel {
    enum Phase: Equatable { case idle, loading, loaded, failed(String), disabled, needsReload }
    enum Target: Equatable { case top, reply(String), edit(String) }

    private(set) var phase: Phase = .idle
    private(set) var threads: [YTMCommentThread] = []
    private(set) var header: YTMCommentsHeader?
    private(set) var next: String?
    private(set) var loadingMore = false
    private(set) var moreFailed = false
    private(set) var sortIndex = 0
    private(set) var videoID: String?
    var expanded: Set<String> = []
    private(set) var replyLoading: Set<String> = []
    private(set) var replyFailed: Set<String> = []
    private(set) var busyVotes: Set<String> = []
    private(set) var hidden: Set<String> = []
    var target: Target?
    var draft = ""
    private(set) var sending = false

    @ObservationIgnored private var identityKey = "guest"
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var epoch = -1
    @ObservationIgnored private var client: YouTubeMusicComments? { YouTubeMusicAccountBuiltIns.manager?.comments }

    var canPost: Bool { header?.createParams != nil && identityKey != "guest" }
    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var visibleThreads: [YTMCommentThread] { threads.filter { !hidden.contains($0.id) } }

    /// Loads comments for a video. Opening the panel again on the same video under the same sign-in costs nothing; `force` refetches.
    func load(videoID: String, force: Bool = false) async {
        let epochNow = YouTubeMusicAccountBuiltIns.manager?.epoch ?? 0
        if !force, self.videoID == videoID, epochNow == epoch, phase == .loaded || phase == .disabled { return }
        guard let client else { phase = .failed(MusicFriendlyErrors.unreachable); return }
        generation += 1
        let mine = generation
        self.videoID = videoID; epoch = epochNow
        phase = .loading; threads = []; next = nil; header = nil; expanded = []; hidden = []; moreFailed = false
        do {
            let page = try await client.firstPage(videoID: videoID)
            guard mine == generation else { return }
            apply(page, replacing: true)
        } catch {
            guard mine == generation else { return }
            phase = .failed(MusicFriendlyErrors.message(for: error))
        }
    }

    private func apply(_ page: YTMCommentsPage, replacing: Bool) {
        identityKey = page.identityKey
        if page.disabled { phase = .disabled; return }
        if replacing { header = page.header ?? header; threads = MusicCommentsLogic.appended([], page.threads) }
        else { threads = MusicCommentsLogic.appended(threads, page.threads) }
        if let i = header?.sortTokens.firstIndex(where: { $0.selected }) { sortIndex = i }
        next = page.next
        phase = .loaded
    }

    func reloadSession() { phase = .needsReload }

    func setSort(_ index: Int) async {
        guard let tokens = header?.sortTokens, tokens.indices.contains(index), index != sortIndex, let client else { return }
        let before = sortIndex, mine = generation + 1
        generation = mine
        sortIndex = index; phase = .loading; threads = []; next = nil
        do {
            let page = try await client.page(token: tokens[index].token, identityKey: identityKey)
            guard mine == generation else { return }
            apply(page, replacing: false)
        } catch {
            guard mine == generation else { return }
            sortIndex = before
            phase = .failed(MusicFriendlyErrors.message(for: error))
        }
    }

    func loadMore() async {
        guard let token = next, !loadingMore, !moreFailed, let client else { return }
        loadingMore = true
        let mine = generation
        defer { loadingMore = false }
        do {
            let page = try await client.page(token: token, identityKey: identityKey)
            guard mine == generation else { return }
            threads = MusicCommentsLogic.appended(threads, page.threads)
            next = page.next
        } catch { if mine == generation { moreFailed = true } }
    }

    func retryMore() async { moreFailed = false; await loadMore() }

    // MARK: replies

    func toggleReplies(_ thread: YTMCommentThread) async {
        if expanded.contains(thread.id) { expanded.remove(thread.id); return }
        expanded.insert(thread.id)
        if thread.replies.isEmpty { await moreReplies(thread.id) }
    }

    func moreReplies(_ id: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }), let token = threads[i].moreRepliesToken, let client, !replyLoading.contains(id) else { return }
        replyLoading.insert(id); replyFailed.remove(id)
        let mine = generation
        defer { replyLoading.remove(id) }
        do {
            let page = try await client.page(token: token, identityKey: identityKey)
            guard mine == generation, let j = threads.firstIndex(where: { $0.id == id }) else { return }
            // A replies page lists the replies as threads of their own.
            let fresh = page.threads.map(\.comment)
            var seen = Set(threads[j].replies.map(\.id))
            threads[j].replies += fresh.filter { seen.insert($0.id).inserted }
            threads[j].moreRepliesToken = page.next
        } catch { replyFailed.insert(id) }
    }

    // MARK: votes

    private func mutate(_ id: String, _ change: (inout YTMComment) -> Void) {
        for i in threads.indices {
            if threads[i].comment.id == id { change(&threads[i].comment); return }
            if let j = threads[i].replies.firstIndex(where: { $0.id == id }) { change(&threads[i].replies[j]); return }
        }
    }

    func vote(_ c: YTMComment, like: Bool) async {
        guard !busyVotes.contains(c.id), let client, let token = like ? MusicCommentsLogic.likeToken(c) : MusicCommentsLogic.dislikeToken(c) else { return }
        busyVotes.insert(c.id)
        let before = c.vote
        mutate(c.id) { $0.vote = like ? MusicCommentsLogic.voteAfterLike(before) : MusicCommentsLogic.voteAfterDislike(before) }
        defer { busyVotes.remove(c.id) }
        do { try await client.perform(action: token, identityKey: identityKey) }
        catch {
            mutate(c.id) { $0.vote = before }
            MusicToasts.shared.error(Self.wording(error, rejected: "The vote was not accepted.", failed: "The vote did not go through."))
        }
    }

    // MARK: writes

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let client, let target else { return }
        sending = true
        defer { sending = false }
        do {
            switch target {
            case .top:
                guard let p = header?.createParams else { return }
                try await client.postComment(text, createParams: p, identityKey: identityKey)
                MusicToasts.shared.success(Localized.string("Posted. It will show the next time comments load."))
            case .reply(let id):
                guard let c = find(id), let p = c.replyParams else { return }
                try await client.reply(text, replyParams: p, identityKey: identityKey)
                MusicToasts.shared.success(Localized.string("Reply posted. It will show the next time comments load."))
            case .edit(let id):
                guard let c = find(id), let p = c.editParams else { return }
                try await client.edit(text, updateParams: p, isReply: c.replyLevel > 0, identityKey: identityKey)
                mutate(id) { $0.text = text }
                MusicToasts.shared.success(Localized.string("Saved."))
            }
            draft = ""; self.target = nil
        } catch {
            // The text stays so nothing typed is lost.
            MusicToasts.shared.error(Self.wording(error, rejected: "That was not accepted.", failed: "That did not go through."))
        }
    }

    func cancelComposer() { draft = ""; target = nil }

    func beginEdit(_ c: YTMComment) { target = .edit(c.id); draft = c.text }

    func delete(_ c: YTMComment) async {
        guard let token = c.deleteAction, let client else { return }
        hidden.insert(c.id)
        do { try await client.delete(action: token, identityKey: identityKey) }
        catch {
            hidden.remove(c.id)
            MusicToasts.shared.error(Self.wording(error, rejected: "The comment was not deleted.", failed: "The comment could not be deleted."))
        }
    }

    private func find(_ id: String) -> YTMComment? {
        for t in threads { if t.comment.id == id { return t.comment }; if let r = t.replies.first(where: { $0.id == id }) { return r } }
        return nil
    }

    nonisolated static func wording(_ error: Error, rejected: String, failed: String) -> String {
        if let a = error as? YTMAccountError {
            switch a {
            case .actionRejected: return rejected
            case .writeUncertain: return "Could not confirm it went through. Check before sending again."
            case .signedOut: return "Sign in to do that."
            case .accountChanged: return "The account changed. Reload the comments."
            default: break
            }
        }
        let m = MusicFriendlyErrors.message(for: error)
        return m == MusicFriendlyErrors.unreachable ? m : failed
    }
}

/// The comments panel for one song: threads, votes, replies and a composer. Timecodes in a comment seek the song.
struct MusicCommentsView: View {
    let hub: MusicHub
    let track: MusicTrack
    @State private var model = MusicCommentsModel()
    @State private var confirmDelete: YTMComment?
    @Environment(\.reddyAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var videoID: String? { track.videoID ?? (track.providerID == YTM.providerID ? track.id : nil) }
    private var trackSeconds: Int { Int(track.durationMs / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comments").font(Typography.heading).padding(Spacing.lg).accessibilityAddTraits(.isHeader)
            if let label = MusicCommentsLogic.countLabel(model.header?.countText), model.phase == .loaded { sortRow(label) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if model.canPost, model.phase == .loaded { composer(for: .top, placeholder: model.header?.composerPlaceholder ?? "Add a comment") }
                    content
                }
                .padding(.horizontal, Spacing.lg).padding(.bottom, Spacing.xl)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: MusicTokens.commentsWidth).atlas("control.music.comments")
        .task(id: videoID) {
            if let id = videoID {
                if MusicCommentsLogic.followsPlaying(hasDraft: model.hasDraft, sending: model.sending) || model.videoID == nil { await model.load(videoID: id) }
            } else if MusicCommentsLogic.followsPlaying(hasDraft: model.hasDraft, sending: model.sending) {
                // The song now playing has no video to read comments from: the panel closes instead of keeping the previous song's thread (a post or a timecode would go to the wrong song).
                MusicChromeState.shared.comments = nil
            }
        }
        .onChange(of: hub.player.current?.uid) { _, _ in
            // The panel is about the song that is playing: it follows the next song, and closes when playback stops, unless a draft is being written.
            guard MusicCommentsLogic.followsPlaying(hasDraft: model.hasDraft, sending: model.sending) else { return }
            MusicChromeState.shared.comments = hub.player.current
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let c = confirmDelete { Task { await model.delete(c) } }; confirmDelete = nil }.atlas("control.music.commentsDelete")
            Button("Cancel", role: .cancel) { confirmDelete = nil }.atlas("control.music.commentsCancel")
        } message: { Text("Its replies go with it. This cannot be undone.") }
        .accessibilityElement(children: .contain).accessibilityLabel("Comments")
    }

    private func sortRow(_ label: String) -> some View {
        HStack(spacing: Spacing.md) {
            Text(verbatim: label).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            Spacer()
            ForEach(Array(["Top", "Newest"].enumerated()), id: \.offset) { i, name in
                Button { Task { await model.setSort(i) } } label: {
                    Text(LocalizedStringKey(name)).font(Typography.captionMedium).underline(model.sortIndex == i)
                        .foregroundStyle(model.sortIndex == i ? ColorTokens.textPrimary : ColorTokens.textSecondary)
                        .frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(model.sortIndex == i ? .isSelected : []).atlas("control.music.commentsMusiccommentsviewsortrowButton")
            }
        }
        .padding(.horizontal, Spacing.lg)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading: ForEach(0..<4, id: \.self) { _ in skeleton }
        case .failed(let m): messageBlock(m, button: "Try Again") { Task { if let id = videoID { await model.load(videoID: id, force: true) } } }
        case .needsReload: messageBlock("The account changed.", button: "Reload") { Task { if let id = videoID { await model.load(videoID: id, force: true) } } }
        case .disabled: Text("Comments are turned off for this song.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
        case .loaded:
            if model.visibleThreads.isEmpty { Text("No comments yet.").font(Typography.body).foregroundStyle(ColorTokens.textSecondary) }
            ForEach(model.visibleThreads) { thread in threadView(thread) }
            if model.moreFailed { messageBlock("More comments did not load.", button: "Try Again") { Task { await model.retryMore() } } }
            else if model.next != nil { MusicLoadingIcon(size: MusicIconSize.small).frame(maxWidth: .infinity).onAppear { Task { await model.loadMore() } } }
        }
    }

    private var skeleton: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle().fill(ColorTokens.elevated).frame(width: MusicTokens.avatarLarge, height: MusicTokens.avatarLarge)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Capsule().fill(ColorTokens.elevated).frame(width: 90, height: 8)
                Capsule().fill(ColorTokens.elevated).frame(height: 8)
                Capsule().fill(ColorTokens.card).frame(width: 140, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private func messageBlock(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: Spacing.sm) {
            Text(verbatim: text).font(Typography.body).foregroundStyle(ColorTokens.textSecondary).multilineTextAlignment(.center)
            Button(LocalizedStringKey(button), action: action).musicButton(.secondary).atlas("control.music.commentsMusiccommentsviewmessageblockButton")
        }.frame(maxWidth: .infinity)
    }

    // MARK: thread

    private func threadView(_ thread: YTMCommentThread) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            commentRow(thread.comment, isReply: false)
            if let inline = inlineComposer(for: thread.comment.id) { inline.padding(.leading, MusicTokens.avatarLarge + Spacing.sm) }
            if thread.comment.replyCount != nil || !thread.replies.isEmpty {
                Button { Task { await model.toggleReplies(thread) } } label: {
                    Label(MusicCommentsLogic.repliesLabel(thread.comment.replyCount), systemImage: model.expanded.contains(thread.id) ? "chevron.up" : "chevron.down")
                        .font(Typography.captionMedium).foregroundStyle(accent).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, MusicTokens.avatarLarge + Spacing.sm).atlas("control.music.commentsMusiccommentsviewthreadviewButton")
            }
            if model.expanded.contains(thread.id) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(thread.replies.filter { !model.hidden.contains($0.id) }) { r in
                        commentRow(r, isReply: true)
                        if let inline = inlineComposer(for: r.id) { inline.padding(.leading, MusicTokens.avatarSmall + Spacing.sm) }
                    }
                    if model.replyLoading.contains(thread.id) { MusicLoadingIcon(size: MusicIconSize.small) }
                    else if model.replyFailed.contains(thread.id) { Button("Try Again") { Task { await model.moreReplies(thread.id) } }.musicButton(.secondary).atlas("control.music.commentsTryAgain") }
                    else if thread.moreRepliesToken != nil { Button("Show more replies") { Task { await model.moreReplies(thread.id) } }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.commentsShowMoreReplies") }
                }
                .padding(.leading, Spacing.xl)
            }
        }
    }

    private func inlineComposer(for id: String) -> AnyView? {
        switch model.target {
        case .reply(let t) where t == id: AnyView(composer(for: .reply(id), placeholder: "Add a reply"))
        case .edit(let t) where t == id: AnyView(composer(for: .edit(id), placeholder: "Edit your comment"))
        default: nil
        }
    }

    private func commentRow(_ c: YTMComment, isReply: Bool) -> some View {
        let size = isReply ? MusicTokens.avatarSmall : MusicTokens.avatarLarge
        return HStack(alignment: .top, spacing: Spacing.sm) {
            avatar(c.author, size: size)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if c.isPinned { Label("Pinned", systemImage: "pin.fill").font(Typography.micro).foregroundStyle(ColorTokens.textTertiary) }
                HStack(spacing: Spacing.xs) {
                    Text(verbatim: c.author.name).font(Typography.captionMedium).lineLimit(2)
                    if c.author.isVerified { Image(systemName: "checkmark.seal.fill").font(Typography.micro).foregroundStyle(ColorTokens.textSecondary).accessibilityLabel("Verified") }
                    if c.author.isCreator { chip("Creator") }
                    if c.author.isArtist { chip("Artist") }
                    Text(verbatim: c.published).font(Typography.micro).foregroundStyle(ColorTokens.textTertiary)
                }
                MusicCommentText(text: c.text, trackSeconds: trackSeconds) { seek($0) }
                actions(c)
            }
        }
    }

    private func actions(_ c: YTMComment) -> some View {
        HStack(spacing: Spacing.sm) {
            let canVote = c.likeAction != nil || c.unlikeAction != nil
            if canVote {
                Button { Task { await model.vote(c, like: true) } } label: {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: c.vote == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        if let n = MusicCommentsLogic.likeCount(c) { Text(verbatim: n).font(Typography.caption) }
                    }
                    .foregroundStyle(c.vote == .liked ? accent : ColorTokens.textSecondary).frame(minHeight: MusicTokens.hitTarget).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.busyVotes.contains(c.id)).accessibilityLabel(c.vote == .liked ? "Remove like" : "Like").atlas("control.music.commentsMusiccommentsviewactionsButton")
                if c.dislikeAction != nil || c.undislikeAction != nil {
                    Button { Task { await model.vote(c, like: false) } } label: {
                        Image(systemName: c.vote == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .foregroundStyle(c.vote == .disliked ? accent : ColorTokens.textSecondary).frame(width: MusicTokens.hitTarget, height: MusicTokens.hitTarget).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.busyVotes.contains(c.id)).accessibilityLabel(c.vote == .disliked ? "Remove dislike" : "Dislike").atlas("control.music.commentsMusiccommentsviewactionsButton")
                }
            } else if let n = c.likeCountNotLiked ?? c.likeCountLiked {
                Label(n, systemImage: "hand.thumbsup").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            }
            if c.isHearted { Image(systemName: "heart.fill").font(Typography.caption).foregroundStyle(accent).accessibilityLabel("Hearted by the creator") }
            if c.replyParams != nil { Button("Reply") { model.target = .reply(c.id); model.draft = "" }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).atlas("control.music.commentsReply") }
            if c.editParams != nil { Button("Edit") { model.beginEdit(c) }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary).atlas("control.music.commentsEdit") }
            if c.deleteAction != nil { Button("Delete") { confirmDelete = c }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(ColorTokens.danger).atlas("control.music.commentsDelete") }
        }
    }

    private func composer(for t: MusicCommentsModel.Target, placeholder: String) -> some View {
        let active = model.target == t
        return VStack(alignment: .trailing, spacing: Spacing.xs) {
            TextField(LocalizedStringKey(placeholder), text: active ? Binding(get: { model.draft }, set: { model.draft = $0 }) : .constant(""), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(active ? 3...3 : 1...1).disabled(model.sending)
                .onTapGesture { if !active { model.target = t; model.draft = "" } }
                .accessibilityLabel(LocalizedStringKey(placeholder)).atlas("control.music.commentsMusiccommentsviewcomposerOnTapGesture")
                #if os(macOS)
                .onKeyPress(.escape) { model.cancelComposer(); return .handled }
                #endif
            if active {
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelComposer() }.musicButton(.secondary).atlas("control.music.commentsCancel")
                    Button(LocalizedStringKey(submitTitle(t))) { Task { await model.send() } }
                        .musicButton(.primary).disabled(!model.hasDraft || model.sending).keyboardShortcut(.return, modifiers: .command).atlas("control.music.commentsMusiccommentsviewcomposerKeyboardShortcut")
                }
            }
        }
    }

    private func submitTitle(_ t: MusicCommentsModel.Target) -> String {
        switch t { case .top: "Comment"; case .reply: "Reply"; case .edit: "Save" }
    }

    private func avatar(_ a: YTMCommentAuthor, size: CGFloat) -> some View {
        let initial = a.name.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).first.map { String($0).uppercased() } ?? "?"
        return ZStack {
            Circle().fill(ColorTokens.elevated)
            Text(verbatim: initial).font(Typography.captionMedium).foregroundStyle(ColorTokens.textSecondary)
            if let s = a.avatar, let url = URL(string: s) { AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }

    private func chip(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(Typography.micro).padding(.horizontal, Spacing.xs).padding(.vertical, 1)
            .background(ColorTokens.elevated, in: Capsule()).foregroundStyle(ColorTokens.textSecondary)
    }

    /// A timecode seeks this song, starting it first when something else is playing.
    private func seek(_ seconds: Int) {
        if hub.player.current?.uid == track.uid { hub.player.seek(to: TimeInterval(seconds)); return }
        hub.play([track], at: 0)
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); hub.player.seek(to: TimeInterval(seconds)) }
    }
}

/// A comment's text with each timecode as a link that calls back with the second to seek to. Long text is clamped until "Show more".
private struct MusicCommentText: View {
    let text: String
    let trackSeconds: Int
    let seek: (Int) -> Void
    @State private var open = false
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(attributed).font(Typography.body).lineLimit(open || !MusicCommentsLogic.needsClamp(text) ? nil : MusicCommentsLogic.clampLines).textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "streamsetu-seek", let s = Int(url.host ?? "") else { return .systemAction }
                    seek(s); return .handled
                })
            if MusicCommentsLogic.needsClamp(text) {
                Button(open ? "Show less" : "Show more") { open.toggle() }.buttonStyle(.plain).font(Typography.captionMedium).foregroundStyle(accent).atlas("control.music.commentsShowLess")
            }
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString(text)
        for m in YTMCommentTimecodes.matches(in: text, trackSeconds: trackSeconds) {
            if let r = Range(m.range, in: out) {
                out[r].link = URL(string: "streamsetu-seek://\(m.seconds)")
                out[r].foregroundColor = accent
            }
        }
        return out
    }
}
