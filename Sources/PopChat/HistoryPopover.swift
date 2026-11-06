import SwiftUI

/// Recent-conversations popover, anchored off the clock pill (⌘Y). Type-to-filter,
/// ↑/↓ to select and ↩ to open, day-group headers, delete (trash click or ⌘⌫).
///
/// Delta 3 (5b/5c/5d): the sheet pops out of the clock pill with a row cascade
/// instead of the stock NSPopover fade, opens at its FINAL size (see `Metrics` —
/// a LazyVStack made NSPopover present at an estimated size and re-size
/// mid-animation, which against the 120pt empty panel is the whole show), and
/// dismisses on a designed curve BEFORE the panel starts growing.
struct HistoryPopover: View {
    @ObservedObject var store: ChatStore
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filter = ""
    @State private var hoveredID: UUID?
    /// Keyboard selection, independent of hover. Preselected so ↩ works the
    /// instant the popover opens.
    @State private var selectedID: UUID?
    @State private var filterFocusBump = 0
    /// Drives the whole designed presentation (5b): flipped true in onAppear for
    /// the pop-in, and back to false to run the out-animation before the popover
    /// itself closes.
    @State private var appeared = false
    /// Set once `close` is running, so the same `appeared` change animates on the
    /// dismiss curve with no row cascade.
    @State private var isClosing = false
    /// The row flashing accent under the press (5d), ahead of the dismiss.
    @State private var pressedID: UUID?
    /// Every stored transcript, flattened for content search. Fetched from the
    /// store (which caches it across presentations) AFTER the popover is on
    /// screen — 5c: it opens at its final size and must not wait on disk — so
    /// title matching works from the first keystroke and body matching joins a
    /// moment later.
    @State private var fullText: [UUID: String] = [:]
    /// The filter applied, computed ONCE per change. Every consumer — the empty
    /// check, the row list, and the height sum that must agree with it — reads
    /// this. Recomputing per access meant matching all fifty transcripts about
    /// seven times per keystroke, and once more on every hover.
    @State private var results: [Result] = []

    struct Result: Identifiable {
        let meta: ConversationMeta
        /// The row's second line: the stored snippet, or the text around a body
        /// hit. Resolved here so the row and its fixed height agree by
        /// construction rather than by calling the same function twice.
        let subtitle: String
        var id: UUID { meta.id }
    }

    /// Fixed geometry, so the popover's height is known before it is presented
    /// and never changes afterwards (5c).
    private enum Metrics {
        static let width: CGFloat = 368
        static let rowWithSnippet: CGFloat = 56
        static let rowPlain: CGFloat = 44
        static let groupHeader: CGFloat = 24
        static let itemSpacing: CGFloat = 3
        static let listInset: CGFloat = 12
        static let maxListHeight: CGFloat = 360
        static let emptyHeight: CGFloat = 116
        /// History rows are cheap, but not free — the filter trims anything past
        /// this and the list stays a plain VStack.
        static let renderCap = 40
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                filterRow
            }
            .padding(14)

            Divider()
            if visible.isEmpty {
                emptyState
            } else {
                list
                Divider()
                keyboardHints
            }
        }
        .frame(width: Metrics.width)
        // The native popover supplies the outline, including its arrow.
        .background { PanelGlassBackground(cornerRadius: 0) }
        .presentationBackground(.clear)
        // Pop from the clock pill rather than materialize: origin top-right,
        // scale 0.92→1, y −6→0. Reduce Motion collapses it to opacity only.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.92, anchor: .topTrailing)
        .offset(y: appeared || reduceMotion ? 0 : -6)
        .opacity(appeared ? 1 : 0)
        .animation(shellAnimation, value: appeared)
        // ⌘F inside the popover means "search the histories": the filter field is
        // already focused on open, so this re-focuses and selects it.
        .keyCommand("f") { filterFocusBump += 1 }
        .onAppear {
            recompute()
            selectedID = visible.first?.id
            appeared = true
            loadFullText()
        }
        .onChange(of: filter) { _, _ in
            recompute()
            selectedID = visible.first?.id
        }
        .onChange(of: store.recent) { _, _ in recompute() }
    }

    private var accent: Color { Theme.color(accentHex) }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text("Recent Chats")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(filter.isEmpty ? "\(store.recent.count) saved" : "\(results.count) found")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var emptyState: some View {
        let hasHistory = !store.recent.isEmpty
        return VStack(spacing: 6) {
            Image(systemName: hasHistory ? "magnifyingglass" : "bubble.left.and.bubble.right")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(hasHistory ? "No matching chats" : "No saved chats")
                .font(.system(size: 13, weight: .semibold))
            Text(hasHistory ? "Try a different search term." : "Your conversations will appear here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.emptyHeight)
    }

    private var keyboardHints: some View {
        HStack(spacing: 14) {
            keyboardHint("↑ ↓", "Navigate")
            keyboardHint("↵", "Open")
            Spacer(minLength: 0)
            keyboardHint("⌘ F", "Search")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func keyboardHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            KeyRoutingTextField(
                text: $filter,
                placeholder: "Search chats…",
                fontSize: 12,
                focusBump: filterFocusBump,
                onMoveUp: { moveSelection(-1) },
                onMoveDown: { moveSelection(1) },
                onReturn: { _ in openSelected() },
                onEscape: {
                    close()
                    return true
                }
            )
            .frame(height: 18)
            if !filter.isEmpty {
                Button {
                    filter = ""
                    filterFocusBump += 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack with fixed item heights: a LazyVStack re-estimates
                // as rows realize, which is exactly what made the popover resize
                // mid-pop (5c).
                VStack(alignment: .leading, spacing: Metrics.itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemView(item)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared || reduceMotion ? 0 : 4)
                            .animation(cascade(index), value: appeared)
                    }
                }
                .padding(Metrics.listInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ListItem) -> some View {
        switch item {
        case let .header(title, _):
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .frame(height: Metrics.groupHeader, alignment: .bottomLeading)
        case let .chat(result):
            row(result)
        }
    }

    // MARK: - Motion

    private var shellAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isClosing ? .easeIn(duration: 0.13) : .spring(response: 0.24, dampingFraction: 0.85)
    }

    /// 18ms stagger capped at the first 8 rows, so a long list never feels slow —
    /// everything past row 8 arrives with it. No stagger on the way out.
    private func cascade(_ index: Int) -> Animation {
        if reduceMotion || isClosing { return .easeOut(duration: 0.13) }
        return .easeOut(duration: 0.16).delay(Double(min(index, 8)) * 0.018)
    }

    /// Runs the designed out-animation, then dismisses, then hands over. The
    /// ordering is the point (5d): the popover is gone before the panel grows,
    /// because two springs at once is what made this read as jumpy.
    private func close(afterFlash: Bool = false, then action: (() -> Void)? = nil) {
        guard !isClosing else { return }
        let run = {
            isClosing = true
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                dismiss()
                action?()
            }
        }
        if afterFlash {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: run)
        } else {
            run()
        }
    }

    private func open(_ meta: ConversationMeta) {
        guard !isClosing else { return }
        pressedID = meta.id
        close(afterFlash: true) { store.loadConversation(meta.id) }
    }

    // MARK: - Keyboard selection

    private func moveSelection(_ delta: Int) -> Bool {
        let items = visible
        guard !items.isEmpty else { return true }
        let current = items.firstIndex { $0.id == selectedID } ?? -1
        selectedID = items[min(max(current + delta, 0), items.count - 1)].id
        return true
    }

    private func openSelected() -> Bool {
        guard let result = visible.first(where: { $0.id == selectedID }) ?? visible.first else { return true }
        open(result.meta)
        return true
    }

    private func row(_ result: Result) -> some View {
        let meta = result.meta
        let isCurrent = meta.id == store.conversationID
        let isHovered = hoveredID == meta.id
        let isSelected = selectedID == meta.id
        let isPressed = pressedID == meta.id
        // Only one row may carry the ⌘⌫ equivalent at a time: hover wins while
        // the mouse is over the list, keyboard selection owns it otherwise.
        let ownsDelete = isHovered || (isSelected && hoveredID == nil)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 0) {
            Button {
                open(meta)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: meta.isFork ? "arrow.triangle.branch" : "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isCurrent ? accent : .secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            isCurrent ? accent.opacity(0.13) : .primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(meta.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if isCurrent {
                                Text("Current")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(accent.opacity(0.11), in: Capsule())
                                    .fixedSize()
                            }
                        }
                        if !result.subtitle.isEmpty {
                            Text(FindHighlight.paint(
                                result.subtitle,
                                find: filter.isEmpty ? nil : TextFind(query: filter, active: nil)
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(timestamp(meta.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .frame(height: rowHeight(result))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if ownsDelete {
                Button {
                    store.deleteConversation(meta.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete chat (⌘⌫)")
                .accessibilityLabel("Delete \(meta.title)")
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .padding(.trailing, 4)
        .background(
            isPressed ? accent.opacity(0.28)
                : isCurrent ? accent.opacity(0.08)
                : isHovered || isSelected ? .primary.opacity(0.055)
                : .clear,
            in: shape
        )
        .overlay {
            if isSelected {
                shape.strokeBorder(accent.opacity(0.58), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .id(meta.id)
        .onHover { inside in
            if inside {
                hoveredID = meta.id
            } else if hoveredID == meta.id {
                hoveredID = nil
            }
        }
    }

    // MARK: - Grouping & geometry

    /// Asks the store for the search corpus. Started from onAppear rather than
    /// lazily on first keystroke, so results never arrive one keystroke late.
    private func loadFullText() {
        Task {
            fullText = await store.searchableText()
            recompute()
        }
    }

    /// The single matching pass. Title, snippet, or anything said in the
    /// conversation — the body match is what makes this a search rather than a
    /// filter, since "the chat where I worked out the regex" is remembered by
    /// its content, never by its first line, which is all the title ever holds.
    private func recompute() {
        let query = filter
        results = store.recent.compactMap { meta in
            guard !query.isEmpty else { return Result(meta: meta, subtitle: meta.snippet) }
            if meta.title.localizedCaseInsensitiveContains(query)
                || meta.snippet.localizedCaseInsensitiveContains(query) {
                return Result(meta: meta, subtitle: meta.snippet)
            }
            // A result whose visible line doesn't contain what you searched for
            // reads as a bug, so a body hit shows the text AROUND the match.
            guard let text = fullText[meta.id],
                  text.localizedCaseInsensitiveContains(query) else { return nil }
            return Result(
                meta: meta,
                subtitle: ConversationStore.excerpt(of: text, matching: query) ?? meta.snippet
            )
        }
    }

    /// What actually renders — the render cap applies here so keyboard selection
    /// can never land on a row that isn't on screen.
    private var visible: [Result] {
        Array(results.prefix(Metrics.renderCap))
    }

    /// Day headers and rows flattened into one list, so the height math is a sum.
    private enum ListItem {
        case header(String, key: String)
        case chat(Result)

        var id: String {
            switch self {
            case let .header(_, key): "h:\(key)"
            case let .chat(result): "c:\(result.id.uuidString)"
            }
        }
    }

    private var items: [ListItem] {
        let calendar = Calendar.current
        var list: [ListItem] = []
        var lastKey: String?
        for result in visible {
            let day = calendar.startOfDay(for: result.meta.updatedAt)
            let key = day.formatted(.iso8601.year().month().day())
            if key != lastKey {
                list.append(.header(groupTitle(for: result.meta.updatedAt, calendar: calendar), key: key))
                lastKey = key
            }
            list.append(.chat(result))
        }
        return list
    }

    /// Keyed on the SAME string the row renders — both come from one `Result` —
    /// because the popover's total height is a sum of these computed before
    /// presentation (5c), and the two must never disagree about whether a second
    /// line exists.
    private func rowHeight(_ result: Result) -> CGFloat {
        result.subtitle.isEmpty ? Metrics.rowPlain : Metrics.rowWithSnippet
    }

    /// The list's presented height: the exact content height, capped. Known
    /// before the first layout pass, so the popover never resizes after it pops.
    private var listHeight: CGFloat {
        let items = items
        guard !items.isEmpty else { return 0 }
        let content = items.reduce(0) { total, item in
            switch item {
            case .header: total + Metrics.groupHeader
            case let .chat(result): total + rowHeight(result)
            }
        }
        let spacing = Metrics.itemSpacing * CGFloat(items.count - 1)
        return min(content + spacing + Metrics.listInset * 2, Metrics.maxListHeight)
    }

    private func groupTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)),
           date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func timestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
