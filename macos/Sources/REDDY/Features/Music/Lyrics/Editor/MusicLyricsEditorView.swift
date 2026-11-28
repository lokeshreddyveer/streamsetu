import SwiftUI
import UniformTypeIdentifiers

// The lyric editor: three steps (Text, Timing, Send). Tap F or J as each word starts; the line loops at a slower speed; a preview plays the
// draft in the real lyrics view; Send is the only thing that talks to the service.

struct MusicLyricsEditorView: View {
    let hub: MusicHub
    let onClose: () -> Void
    private let start: MusicLyricsDraft

    @State private var model: MusicLyricsEditorModel
    @State private var otherSources: [(id: String, lyrics: MusicLyrics?, state: String)] = []
    @State private var pasting = false
    @State private var pasteText = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var confirmDiscard = false
    @State private var selectedWord: Int?
    @FocusState private var keysFocused: Bool
    @Environment(\.reddyAccent) private var accent

    init(hub: MusicHub, track: MusicTrack, videoID: String, startLyrics: MusicLyrics?, onClose: @escaping () -> Void) {
        self.hub = hub; self.onClose = onClose
        let s = startLyrics.map { MusicLyricsDraft(videoID: videoID, from: $0, baseRevision: $0.providerID == MusicLyricsCommunity.providerID ? $0.revision : nil) }
            ?? MusicLyricsDraft(videoID: videoID, lines: [MusicLyricsDraftLine(id: 1)], nextID: 2)
        start = s
        _model = State(initialValue: MusicLyricsEditorModel(track: track, videoID: videoID, player: hub.player, start: s))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ColorTokens.line)
            if let b = model.banner { banner(b) }
            if let n = model.notice { banner(n) }
            content
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(ColorTokens.background)
        .onAppear { model.open(); keysFocused = true }
        .onDisappear { model.close() }
        .sheet(isPresented: $pasting) { pasteSheet }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .xml, .json, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard draft", role: .destructive) { model.discardDraft(restoringTo: start) }.atlas("control.music.lyricsEditorDiscardDraft")
        } message: { Text("Your timings are deleted and the starting lyrics are loaded again.") }
        .accessibilityElement(children: .contain).accessibilityLabel("Lyric editor")
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            Text(verbatim: model.draft.improving ? "Improve lyrics" : "Sync lyrics").font(Typography.heading)
            Text(verbatim: "\(model.track.title) - \(model.track.displayArtistLine)").font(Typography.caption).foregroundStyle(ColorTokens.textSecondary).lineLimit(1)
            Spacer()
            Picker("Step", selection: $model.step) {
                ForEach(MusicLyricsEditorModel.Step.allCases, id: \.self) { s in Text(verbatim: "\(s.rawValue) \(s.title)").tag(s) }
            }
            .pickerStyle(.segmented).frame(width: 300).labelsHidden().accessibilityLabel("Editor step").atlas("control.music.lyricsEditorEditorStep")
            Button("Close") { onClose() }.musicButton(.secondary).keyboardShortcut(.cancelAction).accessibilityLabel("Close the editor").atlas("control.music.lyricsEditorCloseTheEditor")
        }
        .padding(14)
    }

    private func banner(_ text: String) -> some View {
        HStack {
            Image(systemName: "info.circle")
            Text(verbatim: text).font(Typography.caption)
            Spacer()
            if model.banner == text { Button("Discard draft") { confirmDiscard = true }.buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Discard draft").atlas("control.music.lyricsEditorDiscardDraft") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(accent.opacity(0.12))
    }

    @ViewBuilder
    private var content: some View {
        if model.previewing { preview } else {
            switch model.step {
            case .text: textStep
            case .timing: timingStep
            case .send: sendStep
            }
        }
    }

    // MARK: step 1: text

    private var textStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu("Start from") {
                    Button("Reload the starting lyrics") { model.discardDraft(restoringTo: start) }.atlas("control.music.lyricsEditorReloadTheStartingLyrics")
                    Divider()
                    if otherSources.isEmpty { Button("Looking at other sources...") {}.disabled(true).atlas("control.music.lyricsEditorLookingAtOtherSources") }
                    ForEach(otherSources, id: \.id) { s in
                        Button("\(MusicLyricsSources.name(s.id)): \(s.state)") { if let l = s.lyrics { model.draft = MusicLyricsDraft(videoID: model.videoID, from: l) } }
                            .disabled(s.lyrics == nil).atlas("control.music.lyricsEditorMusiclyricseditorviewtextstepButton")
                    }
                    Divider()
                    Button("Paste text...") { pasteText = ""; pasting = true }.atlas("control.music.lyricsEditorPasteText")
                    Button("Import a file...") { importing = true }.atlas("control.music.lyricsEditorImportAFile")
                }
                .accessibilityLabel("Choose where the lyrics start from").atlas("control.music.lyricsEditorChooseWhereTheLyricsStartFrom")
                if let e = importError { Text(verbatim: e).font(Typography.caption).foregroundStyle(.red) }
                Spacer()
                Button { model.draft.addLine(below: model.selectedID); model.selectedID = model.draft.lines.last?.id } label: { Label("Add line", systemImage: "plus") }
                    .accessibilityLabel("Add a line").atlas("control.music.lyricsEditorAddALine")
                Button { model.draft.addBreak(below: model.selectedID) } label: { Label("Add break", systemImage: "ellipsis") }
                    .accessibilityLabel("Add an instrumental break").atlas("control.music.lyricsEditorAddAnInstrumentalBreak")
            }
            Text(verbatim: Localized.string("A space ends a word. Type | inside a word to tap its parts separately, like danc|ing.")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
            List {
                ForEach(model.draft.lines) { line in textRow(line) }
            }
            .listStyle(.plain)
            HStack {
                Text(verbatim: model.draft.progressText).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button("Next: timing") { model.step = .timing; model.selectNextToDo() }.musicButton(.primary).accessibilityLabel("Go to the timing step").atlas("control.music.lyricsEditorGoToTheTimingStep")
            }
        }
        .padding(14)
        .task { await loadOtherSources() }
    }

    private func textRow(_ line: MusicLyricsDraftLine) -> some View {
        HStack(spacing: 8) {
            if line.isBreak {
                Label("Instrumental break", systemImage: "ellipsis").font(Typography.body).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
            } else {
                TextField("Line", text: Binding(get: { line.words.map(\.text).joined() }, set: { model.draft.setText($0, line: line.id) }))
                    .textFieldStyle(.plain).font(Typography.body).accessibilityLabel("Lyric line")
            }
            Image(systemName: line.done ? "checkmark.circle.fill" : "circle").foregroundStyle(line.done ? accent : ColorTokens.textTertiary).accessibilityLabel(line.done ? "Timed" : "Not timed")
            Menu {
                if !line.isBreak {
                    Button("Join with next line") { model.draft.joinWithNext(line: line.id) }.atlas("control.music.lyricsEditorJoinWithNextLine")
                    Button("Split the words again") { model.draft.resplit(line: line.id) }.atlas("control.music.lyricsEditorSplitTheWordsAgain")
                    Menu("Singer") {
                        Button("No singer") { model.draft.setVoice(nil, line: line.id) }.atlas("control.music.lyricsEditorNoSinger")
                        Button("Singer 1") { model.draft.setVoice("v1", line: line.id) }.atlas("control.music.lyricsEditorSinger1")
                        Button("Singer 2") { model.draft.setVoice("v2", line: line.id) }.atlas("control.music.lyricsEditorSinger2")
                        Button("Everyone") { model.draft.setVoice("v1000", line: line.id) }.atlas("control.music.lyricsEditorEveryone")
                    }.atlas("control.music.lyricsEditorSinger")
                }
                Button("Add a line below") { model.draft.addLine(below: line.id) }.atlas("control.music.lyricsEditorAddALineBelow")
                Button("Add a break below") { model.draft.addBreak(below: line.id) }.atlas("control.music.lyricsEditorAddABreakBelow")
                Button("Delete", role: .destructive) { model.draft.delete(line: line.id) }.disabled(model.draft.lines.count < 2).atlas("control.music.lyricsEditorDelete")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Line actions").atlas("control.music.lyricsEditorLineActions")
        }
    }

    private func loadOtherSources() async {
        let ids = hub.lyrics.sourceEntries.filter(\.enabled).map(\.id)
        otherSources = ids.map { ($0, nil, "asking...") }
        let track = model.track
        for id in ids {
            let answer = await hub.lyrics.ask(providerID: id, for: track)
            let row: (String, MusicLyrics?, String)
            switch answer {
            case .hit(let l): let n = l.synced?.count ?? l.plain?.split(whereSeparator: \.isNewline).count ?? 0; row = (id, l.instrumental ? nil : l, "\(n) lines, \(l.kind.label.lowercased())")
            case .none: row = (id, nil, "not found")
            case .error: row = (id, nil, "unreachable")
            }
            if let k = otherSources.firstIndex(where: { $0.id == id }) { otherSources[k] = row }
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: Localized.string("Paste lyrics")).font(Typography.heading)
            Text(verbatim: Localized.string("LRC, word-timed LRC, TTML, or plain text with one line per row.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
            TextEditor(text: $pasteText).font(.system(.body, design: .monospaced)).frame(minHeight: 260).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ColorTokens.line))
                .accessibilityLabel("Pasted lyrics")
            HStack {
                Spacer()
                Button("Cancel") { pasting = false }.musicButton(.secondary).atlas("control.music.lyricsEditorCancel")
                Button("Use this text") {
                    do { model.draft = try MusicLyricsImporter.draft(fromText: pasteText, videoID: model.videoID); importError = nil; pasting = false }
                    catch let e as MusicLyricsImportError { importError = e.message } catch { importError = "That text could not be read." }
                }.musicButton(.primary).atlas("control.music.lyricsEditorUseThisText")
            }
        }
        .padding(18).frame(width: 520)
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { model.draft = try MusicLyricsImporter.draft(fromFile: url, videoID: model.videoID); importError = nil }
        catch let e as MusicLyricsImportError { importError = e.message } catch { importError = "That file could not be read." }
    }

    // MARK: step 2: timing

    private var timingStep: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                progressBar
                if let l = model.selectedLine { bigLine(l) } else { Text(verbatim: Localized.string("Pick a line on the right.")).font(Typography.body) }
                controls
                if let l = model.selectedLine, !l.isBreak { MusicLyricsTimelineStrip(model: model, line: l, selectedWord: $selectedWord) }
                if model.celebrated, model.draft.allDone { celebration }
                Spacer(minLength: 0)
            }
            .padding(14)
            Divider().overlay(ColorTokens.line)
            lineList.frame(width: 250)
        }
        .focusable().focused($keysFocused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.step == .timing, !model.previewing, press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.key {
        case .upArrow: model.move(by: -1); return .handled
        case .downArrow: model.move(by: 1); return .handled
        case .leftArrow, .rightArrow:
            guard let w = selectedWord, let l = model.selectedLine, l.words.indices.contains(w), let s = l.words[w].startMs else { return .ignored }
            let step: Int64 = press.modifiers.contains(.shift) ? 50 : 10
            model.draft.setStart(s + (press.key == .rightArrow ? step : -step), line: l.id, word: w, songLengthMs: Int64(model.player.duration * 1000))
            return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "f", "j": model.tap(); return .handled
        case "r": model.restartLine(); return .handled
        case "l": model.loopOn.toggle(); return .handled
        case "b": model.backgroundPass.toggle(); model.pass = nil; return .handled
        case "v": model.backgroundPass.toggle(); model.pass = nil; return .handled
        default: return .ignored
        }
    }

    private var progressBar: some View {
        let n = model.draft.total
        return VStack(alignment: .leading, spacing: 4) {
            if n <= 100 {
                HStack(spacing: 2) { ForEach(model.draft.lines) { l in Capsule().fill(l.done ? accent : ColorTokens.line).frame(height: 5) } }
            } else {
                ProgressView(value: Double(model.draft.doneCount), total: Double(max(1, n)))
            }
            Text(verbatim: model.draft.progressText).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
        }
    }

    private func bigLine(_ l: MusicLyricsDraftLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if l.isBreak {
                Text(verbatim: l.startMs == nil ? "This break has no start yet. Tap when it begins." : "Break starts at \(MusicTime.clock(Double(l.startMs ?? 0) / 1000))").font(Typography.heading)
            } else {
                if l.needsStart, model.pass == nil { Text(verbatim: Localized.string("This line has no start yet. Tap when it begins.")).font(Typography.bodyMedium).foregroundStyle(accent) }
                FlowWords(words: l.words, nextIndex: model.pass?.nextWord, tapped: model.pass?.wordIndices.prefix(model.pass?.taps.count ?? 0).map { $0 } ?? [], accent: accent, selected: $selectedWord)
                if let p = model.pass, p.taps.count == p.expected { Text(verbatim: Localized.string("One more tap when the last word ends.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorTokens.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { model.tap() } label: { Label("Tap (F or J)", systemImage: "hand.tap").frame(minWidth: 120) }
                    .musicButton(.primary).accessibilityLabel("Tap: a word starts now").atlas("control.music.lyricsEditorTapAWordStartsNow")
                Button { model.player.toggle() } label: { Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play").atlas("control.music.lyricsEditorMusiclyricseditorviewcontrolsButton")
                Button("Restart (R)") { model.restartLine() }.accessibilityLabel("Restart this line").atlas("control.music.lyricsEditorRestartThisLine")
                Toggle("Loop (L)", isOn: $model.loopOn).toggleStyle(.checkbox).accessibilityLabel("Loop the line").atlas("control.music.lyricsEditorLoopTheLine")
                if model.voiceOwed.background || model.selectedLine?.hasBackground == true {
                    Picker("Voice", selection: $model.backgroundPass) { Text("Lead").tag(false); Text("Background").tag(true) }
                        .pickerStyle(.segmented).frame(width: 190).labelsHidden().accessibilityLabel("Voice being timed").atlas("control.music.lyricsEditorVoiceBeingTimed")
                }
                Menu("Singer") {
                    Button("No singer") { if let l = model.selectedLine { model.draft.setVoice(nil, line: l.id) } }.atlas("control.music.lyricsEditorNoSinger")
                    Button("Singer 1") { if let l = model.selectedLine { model.draft.setVoice("v1", line: l.id) } }.atlas("control.music.lyricsEditorSinger1")
                    Button("Singer 2") { if let l = model.selectedLine { model.draft.setVoice("v2", line: l.id) } }.atlas("control.music.lyricsEditorSinger2")
                    Button("Everyone") { if let l = model.selectedLine { model.draft.setVoice("v1000", line: l.id) } }.atlas("control.music.lyricsEditorEveryone")
                }.fixedSize().accessibilityLabel("Singer of this line").atlas("control.music.lyricsEditorSingerOfThisLine")
            }
            HStack(spacing: 16) {
                HStack { Text(verbatim: Localized.string("Speed")).font(Typography.caption)
                    Slider(value: $model.tempo, in: MusicLyricsTapMath.tempoRange, step: 0.05).frame(width: 130).accessibilityLabel("Editor playback speed")
                    Text(verbatim: String(format: "%.2fx", model.tempo)).font(Typography.timestamp) }
                HStack { Text(verbatim: Localized.string("Tap offset")).font(Typography.caption)
                    Stepper(value: $model.tapOffsetMs, in: -500...500, step: 10) { Text(verbatim: "\(Int(model.tapOffsetMs)) ms").font(Typography.timestamp) }
                        .accessibilityLabel("Tap offset in milliseconds") }
                Button { if let l = model.selectedLine, let w = selectedWord, l.words.indices.contains(w) { model.draft.toggleBackground(line: l.id, word: w) } } label: { Text(verbatim: Localized.string("Mark background (B on a selected word)")) }
                    .font(Typography.caption).accessibilityLabel("Toggle the selected word as a background vocal").atlas("control.music.lyricsEditorToggleTheSelectedWordAsA")
            }
            Text(verbatim: Localized.string("Tap F or J as each word starts. Up and Down change line. Left and Right move a selected word by 10 ms (Shift 50).")).font(Typography.caption).foregroundStyle(ColorTokens.textTertiary)
        }
    }

    private var celebration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Localized.string("Every line is timed")).font(Typography.heading)
            HStack {
                Button("Watch the preview") { model.celebrated = false; model.previewing = true; model.player.seek(to: 0); if !model.player.isPlaying { model.player.resume() } }
                    .musicButton(.secondary).atlas("control.music.lyricsEditorWatchThePreview")
                Button("Send lyrics") { model.celebrated = false; model.step = .send }.musicButton(.primary).atlas("control.music.lyricsEditorSendLyrics")
            }
        }
        .padding(14).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: LayoutTokens.radius, style: .continuous))
    }

    private var lineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Button("Next to do") { model.selectNextToDo() }.disabled(model.draft.nextToDo == nil).padding(8).accessibilityLabel("Go to the next line to do").atlas("control.music.lyricsEditorGoToTheNextLineTo")
                ForEach(model.draft.lines) { l in
                    Button { model.select(l.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: l.done ? "checkmark.circle.fill" : (l.timedWordCount > 0 ? "circle.lefthalf.filled" : (l.needsStart ? "clock" : "circle")))
                                .foregroundStyle(l.done ? accent : ColorTokens.textTertiary)
                            Text(verbatim: l.isBreak ? "Instrumental break" : l.text).font(Typography.caption).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                        .background(l.id == model.selectedID ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).accessibilityLabel(l.isBreak ? "Instrumental break" : l.text)
                    .accessibilityValue(l.done ? "Timed" : (l.needsStart ? "Needs a start" : "Needs words")).atlas("control.music.lyricsEditorMusiclyricseditorviewlinelistButton")
                }
            }
        }
    }

    // MARK: preview

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Text(verbatim: Localized.string("Preview at normal speed. Lines not timed yet are left out.")).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                Spacer()
                Button { model.player.toggle() } label: { Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(model.player.isPlaying ? "Pause" : "Play").atlas("control.music.lyricsEditorMusiclyricseditorviewpreviewButton")
                Button("Back to editing") { model.previewing = false; model.step = .timing }.musicButton(.secondary).atlas("control.music.lyricsEditorBackToEditing")
                Button("Send lyrics") { model.previewing = false; model.step = .send }.musicButton(.primary).atlas("control.music.lyricsEditorSendLyrics")
            }
            .padding(.horizontal, 14).padding(.top, 8)
            MusicLyricsView(player: model.player, lyrics: model.previewLyrics, trackKey: "editor-preview-\(model.videoID)", style: .expanded)
        }
    }

    // MARK: step 3: send

    private var sendStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let r = model.rejection {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: Localized.string("A reviewer turned down your last version")).font(Typography.bodyMedium)
                        Text(verbatim: r.reason).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                    }.padding(12).background(ColorTokens.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(verbatim: "\(model.draft.buildLines().count) lines, every word timed").font(Typography.heading)
                Text(verbatim: Localized.string("Sent as: Anonymous. No name is attached.")).font(Typography.body)
                Text(verbatim: Localized.string("Then: A reviewer checks them before they go live.")).font(Typography.body)
                Text(verbatim: MusicLyricsEditorModel.privacyLine).font(Typography.caption).foregroundStyle(ColorTokens.textSecondary)
                switch model.readiness {
                case .blocked(let why): Text(verbatim: why).font(Typography.caption).foregroundStyle(.orange)
                case .ready: EmptyView()
                }
                sendResult
                HStack {
                    Button("Preview") { model.previewing = true; model.player.seek(to: 0); if !model.player.isPlaying { model.player.resume() } }.musicButton(.secondary).atlas("control.music.lyricsEditorPreview")
                    Button { Task { await model.submit() } } label: {
                        if model.send == .sending { MusicLoadingIcon(size: MusicIconSize.small) } else { Text(verbatim: Localized.string("Submit")) }
                    }
                    .musicButton(.primary)
                    .disabled(model.send == .sending || { if case .ready = model.readiness { return false } else { return true } }())
                    .accessibilityLabel("Submit these lyrics to the community lyrics service").atlas("control.music.lyricsEditorSubmitTheseLyricsToTheCommunity")
                }
            }
            .padding(18)
        }
        .task { await model.loadRejection() }
    }

    @ViewBuilder
    private var sendResult: some View {
        switch model.send {
        case .idle, .sending: EmptyView()
        case .done(let r):
            Text(verbatim: r.status == .published ? "Your lyrics are live." : "Sent. They go live once a reviewer approves them.").font(Typography.bodyMedium).foregroundStyle(accent)
        case .failed(let e):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: e.message).font(Typography.body).foregroundStyle(.orange)
                if e == .stale {
                    HStack {
                        Button("Load the new version") { model.discardDraft(restoringTo: start); model.step = .text }.atlas("control.music.lyricsEditorLoadTheNewVersion")
                        Button("Send mine on top") { Task { await model.sendMineOnTopOfLive() } }.musicButton(.primary).atlas("control.music.lyricsEditorSendMineOnTop")
                    }
                }
            }
        }
    }
}

// MARK: - word chips

private struct FlowWords: View {
    let words: [MusicLyricsDraftWord]
    let nextIndex: Int?
    let tapped: [Int]
    let accent: Color
    @Binding var selected: Int?

    var body: some View {
        MusicLyricsFlowLayout(rowSpacing: 6) {
            ForEach(words.indices, id: \.self) { i in
                let w = words[i]
                Button { selected = (selected == i) ? nil : i } label: {
                    Text(verbatim: w.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 26, weight: w.background ? .regular : .bold)).italic(w.background)
                        .padding(.horizontal, 4)
                        .foregroundStyle(i == nextIndex ? accent : (w.timed || tapped.contains(i) ? ColorTokens.textPrimary : ColorTokens.textTertiary))
                        .background(selected == i ? accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .underline(i == nextIndex, color: accent)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel(w.text).accessibilityValue(w.timed ? "Timed" : "Not timed").atlas("control.music.lyricsEditorFlowwordsbodyButton")
            }
        }
    }
}

// MARK: - timeline strip

/// The line's timed words as blocks on a ruler around the loop; drag a block's left or right edge to move it.
struct MusicLyricsTimelineStrip: View {
    let model: MusicLyricsEditorModel
    let line: MusicLyricsDraftLine
    @Binding var selectedWord: Int?
    @State private var dragBase: Int64?
    @Environment(\.reddyAccent) private var accent

    var body: some View {
        let range = model.loopRange ?? ((line.firstStart ?? 0) - 1200)...((line.lastEnd ?? (line.firstStart ?? 0) + 3000) + 600)
        let span = Double(max(1, range.upperBound - range.lowerBound))
        GeometryReader { g in
            let w = g.size.width
            let x: (Int64) -> CGFloat = { ms in CGFloat(Double(ms - range.lowerBound) / span) * w }
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: (range.lowerBound / 500) * 500, through: range.upperBound, by: 500)), id: \.self) { t in
                    Rectangle().fill(ColorTokens.line).frame(width: 1, height: t % 1000 == 0 ? 8 : 4).offset(x: x(t))
                }
                ForEach(line.words.indices, id: \.self) { i in
                    if let s = line.words[i].startMs, let e = line.words[i].endMs {
                        let lane: CGFloat = line.words[i].background ? 34 : 14
                        let bw = max(6, x(e) - x(s))
                        RoundedRectangle(cornerRadius: 4).fill(selectedWord == i ? accent : accent.opacity(0.45)).frame(width: bw, height: 18)
                            .overlay(Text(verbatim: line.words[i].text.trimmingCharacters(in: .whitespaces)).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 2))
                            .overlay(alignment: .leading) { handle(i, edge: .start, range: range, width: w) }
                            .overlay(alignment: .trailing) { handle(i, edge: .end, range: range, width: w) }
                            .offset(x: x(s), y: lane)
                            .onTapGesture { selectedWord = i; model.player.seek(to: Double(s) / 1000) }
                            .accessibilityLabel(line.words[i].text).atlas("control.music.lyricsEditorMusiclyricstimelinestripbodyOnTapGesture")
                    }
                }
                let pos = Int64(model.player.position * 1000)
                if range.contains(pos) { Rectangle().fill(.white).frame(width: 2, height: 56).offset(x: x(pos)) }
            }
        }
        .frame(height: 62)
        .background(ColorTokens.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .clipped()
    }

    private enum Edge { case start, end }

    private func handle(_ i: Int, edge: Edge, range: ClosedRange<Int64>, width: CGFloat) -> some View {
        Rectangle().fill(.white.opacity(0.001)).frame(width: 8)
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                guard let s = line.words[i].startMs, let e = line.words[i].endMs else { return }
                if dragBase == nil { dragBase = edge == .start ? s : e }
                let delta = Int64(Double(v.translation.width) / Double(max(1, width)) * Double(range.upperBound - range.lowerBound))
                let length = Int64(model.player.duration * 1000)
                let target = (dragBase ?? 0) + delta
                if edge == .start { model.draft.setStart(target, line: line.id, word: i, songLengthMs: length) } else { model.draft.setEnd(target, line: line.id, word: i, songLengthMs: length) }
            }.onEnded { _ in dragBase = nil })
    }
}
