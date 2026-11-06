import SwiftUI
import AppKit

/// Attachment state lives here so drops (handled at the panel root) and the
/// composer share it without the root view observing keystrokes.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var pendingAttachments: [Attachment] = []
    @Published var attachNotice: String?
    /// Text to load into the field from outside the composer (Edit prompt).
    /// ComposerView consumes it and clears it — it is a one-shot message, not
    /// a mirror of the draft, which stays private to the composer so keystrokes
    /// never reach the transcript.
    @Published var injectedDraft: String?

    func handleFiles(_ urls: [URL]) {
        attachNotice = nil
        for url in urls {
            Task {
                let result = await AttachmentLoader.load(url: url)
                switch result {
                case .success(let attachment):
                    pendingAttachments.append(attachment)
                    if let note = attachment.note, attachment.noteKind == .warning {
                        attachNotice = "\(attachment.filename): \(note)"
                    }
                    updateSizeWarning()
                case .failure(let error):
                    attachNotice = error.message
                }
            }
        }
    }

    /// ⌘V with a file or image on the pasteboard attaches it; plain text never
    /// reaches this (the Edit menu handles it).
    func handlePasteboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            handleFiles(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            handleImage(image, suggestedName: "pasted-image.jpg")
        }
    }

    /// Raw image data with no backing file — pasted screenshots and drags whose
    /// pasteboard offers only bitmap data (e.g. an image out of a browser).
    func handleImage(_ image: NSImage, suggestedName: String) {
        attachNotice = nil
        switch AttachmentLoader.load(image: image, suggestedName: suggestedName) {
        case .success(let attachment):
            pendingAttachments.append(attachment)
            updateSizeWarning()
        case .failure(let error):
            attachNotice = error.message
        }
    }

    func remove(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        if pendingAttachments.isEmpty { attachNotice = nil }
    }

    func clear() {
        pendingAttachments = []
        attachNotice = nil
    }

    private func updateSizeWarning() {
        let totalChars = pendingAttachments.reduce(0) { total, attachment in
            switch attachment.content {
            case .text(let text): return total + text.count
            // Counted at its text size: that's what lands in context on the
            // (default) extracted-text path, and a fair proxy either way.
            case .pdf(_, let extractedText): return total + extractedText.count
            case .image: return total
            }
        }
        if totalChars > 50_000 {
            attachNotice = "Attachments total ~\(totalChars / 4 / 1000)k tokens — may exceed smaller models' context windows."
        }
    }
}

/// NSTextView that reports input-method composition changes.
///
/// While an IME is composing (pinyin, kana, hangul, and any candidate-window
/// input), the in-progress text is MARKED text: uncommitted, owned by the input
/// context, and — crucially — it does NOT post `textDidChange`. So the SwiftUI
/// binding would sit stale for the whole composition, and the next unrelated
/// re-render (a streaming token, an attachment chip) would see string != binding
/// and "restore" the binding's value, destroying the composition mid-word. These
/// overrides keep the binding in step; `updateNSView` additionally refuses to
/// write while marked text exists. Both halves are needed: this one keeps the
/// placeholder and height right, that one is the actual safety net.
final class ComposingTextView: NSTextView {
    var onCompositionChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
}

private final class ComposerScrollView: NSScrollView {
    // Keep AppKit's caret tracking while ignoring wheel and trackpad gestures.
    override func scrollWheel(with event: NSEvent) {}
}

/// AppKit-backed multiline input: grows with content up to `maxVisibleLines`,
/// then scrolls internally so the caret always stays visible. A stable layout
/// boundary — the height callback fires only when the measured height actually
/// changes, never per keystroke. Native undo, IME and editing shortcuts.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var maxVisibleLines = 8
    var focusBump = 0
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Return true to consume the key (completion/submit); false = default edit.
    var onReturn: () -> Bool = { false }
    var onMoveUp: () -> Bool = { false }
    var onMoveDown: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposingTextView()
        textView.onCompositionChange = { [weak coordinator = context.coordinator] in
            coordinator?.syncFromTextView()
        }
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Message input")
        // File drops fall through to the panel-wide attachment target.
        textView.unregisterDraggedTypes()

        let scroll = ComposerScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        context.coordinator.textView = textView
        context.coordinator.observeWidth(of: scroll)
        context.coordinator.remeasure()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        // Never write to the text view mid-composition: assigning `string` clears
        // the input context's marked text and aborts the IME session, so any
        // re-render arriving while the user was composing (streaming tokens do it
        // ~30×/s) made Chinese/Japanese/Korean input impossible. The binding is
        // kept in step by ComposingTextView, and resyncs on commit either way.
        if !textView.hasMarkedText(), textView.string != text {
            // Every external write REPLACES the draft with something the user
            // continues typing after — a completed slash command, a recalled
            // prompt, a message pulled back for editing — so the caret has to
            // end up at the end. Assigning `string` already does that in both
            // directions (verified against longer AND shorter replacements by
            // --smoke-recall, which is why those caret checks are there): an
            // explicit setSelectedRange here would be dead code.
            textView.string = text
            coordinator.remeasure()
        }
        if coordinator.lastFocusBump != focusBump {
            coordinator.lastFocusBump = focusBump
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusBump = Int.min
        private var lastHeight: CGFloat = -1
        private var widthObserver: NSObjectProtocol?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        deinit {
            if let widthObserver {
                NotificationCenter.default.removeObserver(widthObserver)
            }
        }

        func observeWidth(of scroll: NSScrollView) {
            scroll.contentView.postsFrameChangedNotifications = true
            widthObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.remeasure()
            }
        }

        func textDidChange(_ notification: Notification) {
            syncFromTextView()
        }

        /// Push the view's text into the binding. Also called for marked-text
        /// changes, which post no textDidChange of their own — without it the
        /// placeholder stays visible under an in-progress composition and the
        /// field doesn't grow as it gets longer.
        func syncFromTextView() {
            guard let textView else { return }
            parent.text = textView.string
            remeasure()
        }

        /// Reports the clamped content height — asynchronously, because this can
        /// be reached during a layout pass, and only when it actually changed.
        func remeasure() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
            let used = layoutManager.usedRect(for: container).height
            let clamped = min(max(used, lineHeight), lineHeight * CGFloat(parent.maxVisibleLines))
            let height = ceil(clamped) + textView.textContainerInset.height * 2
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(height) }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false } // IME confirm
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false } // ⇧↩ newline
                return parent.onReturn()
            // Arrow keys drive the slash popup and prompt recall — but only over
            // committed text. Mid-composition they belong to the input method's
            // candidate window, and consuming them here would make an IME
            // unusable in the composer.
            case #selector(NSResponder.moveUp(_:)):
                if textView.hasMarkedText() { return false }
                return parent.onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                if textView.hasMarkedText() { return false }
                return parent.onMoveDown()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape() // would otherwise open NSTextView's completion popup
                return true
            default:
                return false
            }
        }
    }
}

/// The input area: capsule field (grows to 8 lines, then scrolls), slash-command
/// popup and attachment chips. Owns transient typing state so keystrokes
/// invalidate only this subtree.
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    /// Observed for the capability warning: it must re-resolve when the switcher
    /// commits a different provider/model while attachments are pending.
    @ObservedObject var providerStore: ProviderStore
    let shortcutStore: ShortcutStore
    let isStreaming: Bool
    let focusBump: Int
    let homeStyle: Bool
    @Binding var pinned: Bool
    let onSend: (String, [Attachment]) -> Void
    let onStop: () -> Void
    let onFocusRequest: () -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @State private var completionIndex = 0
    @State private var inputHeight: CGFloat = 21
    /// ↑ recall. Nil means "not browsing"; otherwise a snapshot of the history
    /// taken when the walk started — so a send landing mid-walk can't shift the
    /// list under the user — together with the position in it. One optional
    /// makes index-in-range structural rather than something to re-check.
    @State private var recall: (entries: [String], index: Int)?
    @AppStorage("webSearchEnabled") private var webEnabled = true
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @AppStorage("liquidGlass") private var liquidGlass = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accent: Color { Theme.color(accentHex) }

    private var placeholder: String {
        if homeStyle { return "Ask anything, or type / for commands…" }
        return "Message…  (“/” for shortcuts)"
    }

    var body: some View {
        VStack(spacing: 8) {
            if !completionCandidates.isEmpty {
                slashCard
                    .transition(.opacity)
            }
            if !model.pendingAttachments.isEmpty || model.attachNotice != nil {
                attachCard
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 10) {
                composerCard
                composerButtons
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
        .padding([.horizontal, .bottom], 7)
        .animation(.easeOut(duration: 0.12), value: completionCandidates.isEmpty)
        .animation(.easeOut(duration: 0.12), value: model.pendingAttachments.count)
        .animation(.easeOut(duration: 0.12), value: model.attachNotice)
        .onChange(of: draft) { _, newValue in
            if completionIndex != 0 { completionIndex = 0 }
            // Editing a recalled prompt makes it yours again: further ↑ then
            // starts a fresh walk from the top rather than continuing the old
            // one and discarding what was just typed.
            if let recall, recall.entries[recall.index] != newValue { self.recall = nil }
        }
        .onChange(of: model.injectedDraft) { _, injected in
            guard let injected else { return }
            draft = injected
            model.injectedDraft = nil
            recall = nil
            onFocusRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .popChatAttachPasteboard)) { _ in
            model.handlePasteboard()
        }
    }

    private var composerCard: some View {
        composerField
            .frame(height: inputHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, 8.5)
            .background {
                composerSurface(in: RoundedRectangle(cornerRadius: 21.5, style: .continuous))
            }
    }

    @ViewBuilder
    private func composerSurface<S: InsettableShape>(in shape: S) -> some View {
        // Switch only the backdrop so the native text view keeps its identity.
        if #available(macOS 26.0, *), liquidGlass, !reduceTransparency {
            Color.clear.glassEffect(.regular, in: shape)
                .allowsHitTesting(false)
        } else {
            Color.clear.glassCard(shape)
                .allowsHitTesting(false)
        }
    }

    private var commandMenu: some View {
        composerMenu("Chat commands", symbol: "command") {
            Toggle("Keep on top", isOn: $pinned)
            Divider()
            Button("Browse slash commands") {
                draft = "/"
                onFocusRequest()
            }
            .disabled(!draft.isEmpty || shortcutStore.shortcuts.isEmpty)
        }
    }

    private func composerMenu<MenuContent: View>(
        _ title: String, symbol: String, @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 38, height: 38)
        .background { composerSurface(in: Circle()) }
        .accessibilityLabel(title)
        .help(title)
    }

    private var actionsMenu: some View {
        composerMenu("Message actions", symbol: "option") {
            Button("Attach files…", action: attachViaPicker)
            Toggle("Web access", isOn: $webEnabled)
            Divider()
            if isStreaming {
                Button("Stop generating", action: onStop)
            } else {
                Button("Send message", action: submit)
                    .disabled(!canSend)
            }
        }
    }

    private var composerButtons: some View {
        HStack(spacing: 10) {
            actionsMenu
            commandMenu
        }
    }

    private var composerField: some View {
        ComposerTextView(
            text: $draft,
            maxVisibleLines: 8,
            focusBump: focusBump,
            onHeightChange: { inputHeight = $0 },
            onReturn: {
                if !completionCandidates.isEmpty {
                    complete()
                    return true
                }
                submit()
                return true
            },
            onMoveUp: {
                guard completionCandidates.isEmpty else {
                    completionIndex = max(0, completionIndex - 1)
                    return true
                }
                return recallOlder()
            },
            onMoveDown: {
                guard completionCandidates.isEmpty else {
                    completionIndex = min(completionCandidates.count - 1, completionIndex + 1)
                    return true
                }
                return recallNewer()
            },
            onTab: {
                guard !completionCandidates.isEmpty else { return false }
                complete()
                return true
            },
            onEscape: onClose
        )
        .overlay(alignment: .topLeading) {
            if draft.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Prompt recall (↑ / ↓)

    /// ↑ walks back through prompts you have sent, shell-style. It only STARTS
    /// from an empty composer — ↑ in a draft you are writing has to keep meaning
    /// "move the caret up", or a multi-line draft becomes uneditable and a
    /// half-typed one gets eaten.
    private func recallOlder() -> Bool {
        // Starting a walk needs an empty draft; continuing one does not.
        let entries = recall?.entries ?? (draft.isEmpty ? PromptHistory.entries : [])
        let next = recall.map { $0.index + 1 } ?? 0
        guard next < entries.count else {
            // Already at the oldest: consume the key rather than letting it move
            // the caret. Not browsing at all: let ↑ mean what it usually means.
            return recall != nil
        }
        recall = (entries, next)
        draft = entries[next]
        return true
    }

    /// ↓ walks back toward the present, and past the newest entry returns the
    /// empty composer you started from.
    private func recallNewer() -> Bool {
        guard let recall else { return false }
        if recall.index == 0 {
            self.recall = nil
            draft = ""
        } else {
            self.recall = (recall.entries, recall.index - 1)
            draft = recall.entries[recall.index - 1]
        }
        return true
    }

    // MARK: - Slash-command completion

    private var completionCandidates: [PromptShortcut] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let query = String(draft.dropFirst()).lowercased()
        return shortcutStore.shortcuts.filter {
            query.isEmpty || $0.name.lowercased().hasPrefix(query)
        }
    }

    private var slashCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(completionCandidates.enumerated()), id: \.element.id) { index, shortcut in
                HStack(spacing: 8) {
                    Text("/" + shortcut.name)
                        .fontWeight(.medium)
                    Text(shortcut.template.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    index == completionIndex ? accent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture { complete(with: shortcut) }
            }
        }
        .padding(6)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func complete(with shortcut: PromptShortcut? = nil) {
        let candidates = completionCandidates
        guard let chosen = shortcut ?? (candidates.indices.contains(completionIndex) ? candidates[completionIndex] : candidates.first) else { return }
        draft = "/" + chosen.name + " "
    }

    // MARK: - Attachments

    private var attachCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                model.remove(attachment.id)
                            }
                        }
                    }
                }
            }
            // fixedSize(vertical) on both notices is what keeps them whole: the
            // empty panel's height FOLLOWS the measured content, so a Text that
            // yields to the current (still-short) window truncates or paints past
            // the card, and the height report never learns the missing lines.
            if let notice = model.attachNotice {
                HStack(alignment: .top, spacing: 6) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(scheme == .dark ? Theme.warningOrange : Theme.warningTextLight)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        model.attachNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            // No dismiss here: this one is DERIVED (re-resolves live from the
            // pending attachments + current model), so it clears itself when the
            // attachment is removed or the model changes — an ✕ would just have
            // it reappear on the next render.
            if let notice = capabilityNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(scheme == .dark ? Theme.warningOrange : Theme.warningTextLight)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The explicit-warning half of the capability design: images are ALWAYS
    /// sent, so a model KNOWN to refuse them (metadata or a recorded exception)
    /// must say so before the send, not after. Unknown stays silent — optimistic
    /// send, and a rejection surfaces (and is learned) as an explicit error.
    /// Separate from `model.attachNotice` so switching provider/model while
    /// attachments are pending re-resolves it live.
    private var capabilityNotice: String? {
        guard !model.pendingAttachments.isEmpty else { return nil }
        let capabilities = providerStore.currentAttachmentCapabilities()
        let modelName = providerStore.currentModel
        let hasImages = model.pendingAttachments.contains {
            if case .image = $0.content { return true } else { return false }
        }
        if hasImages, capabilities.images == false {
            return "\(modelName) doesn't accept images — pick another model, or this send will likely be rejected."
        }
        let hasTextlessPDF = model.pendingAttachments.contains {
            if case .pdf(_, let extractedText) = $0.content { return extractedText.isEmpty } else { return false }
        }
        if hasTextlessPDF, capabilities.files != true {
            return "A scanned PDF has no extractable text, and \(modelName) doesn't take PDF files directly — its content can't be sent."
        }
        return nil
    }

    private func attachViaPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            model.handleFiles(panel.urls)
        }
        onFocusRequest()
    }

    // MARK: - Sending

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.pendingAttachments.isEmpty
    }

    private func submit() {
        guard !isStreaming, canSend else { return }
        onSend(draft, model.pendingAttachments)
        draft = ""
        recall = nil
        model.clear()
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    @State private var showNote = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
            Text(attachment.filename)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 160)
            if let note = attachment.note {
                Button {
                    showNote.toggle()
                } label: {
                    Image(systemName: attachment.noteKind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(attachment.noteKind == .warning ? Theme.warningOrange : Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(note)
                .popover(isPresented: $showNote, arrowEdge: .bottom) {
                    Text(note)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: 320)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
            in: Capsule()
        )
    }

    private var icon: String {
        if case .image = attachment.content { return "photo" }
        if case .pdf = attachment.content { return "doc.richtext" }
        return "doc.text"
    }
}
