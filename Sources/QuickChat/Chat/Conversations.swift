import Foundation

struct Conversation: Codable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    /// For a fork: only the messages AFTER the fork point — the shared prefix
    /// lives in the parent chain and is resolved on load.
    var messages: [ChatMessage]
    /// Conversation this one was forked from; nil for a root conversation.
    var parentID: UUID? = nil
    /// Last shared message (inclusive) in the parent's resolved transcript.
    var forkMessageID: UUID? = nil
}

struct ConversationMeta: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    /// One-line preview for the history popover (last real message).
    let snippet: String
    let isFork: Bool

    static func snippet(for messages: [ChatMessage]) -> String {
        let last = messages.last { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
        let flattened = (last?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(120))
    }
}

/// One JSON file per conversation in Application Support. Forked conversations
/// form a tree: a fork's file stores a parent pointer plus only the messages
/// added after the fork, so shared history is never duplicated on disk. The
/// full transcript is resolved by walking the parent chain. Deleting or pruning
/// a parent first materializes its direct children (their files absorb the
/// shared prefix and become standalone), so forks are never silently orphaned.
/// Capped at `maxStored` conversations; oldest are pruned.
enum ConversationStore {
    static let maxStored = 50

    /// Test hook: smoke harnesses point this at a scratch directory so synthetic
    /// conversations never touch the user's real history.
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static var directory: URL {
        let dir = overrideDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PopChat/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: url(for: conversation.id), options: [.atomic])
    }

    static func load(id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: data)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    // MARK: - Fork resolution

    /// Full transcript: the parent chain's shared prefix plus this
    /// conversation's own tail. `missingParent` is true when the chain is
    /// broken (parent file gone or fork point no longer present) — the caller
    /// should surface that instead of degrading silently.
    static func resolveMessages(_ conversation: Conversation) -> (messages: [ChatMessage], missingParent: Bool) {
        resolveMessages(conversation, lookup: { load(id: $0) }, visited: [conversation.id])
    }

    private static func resolveMessages(
        _ conversation: Conversation,
        lookup: (UUID) -> Conversation?,
        visited: Set<UUID>
    ) -> ([ChatMessage], Bool) {
        guard let parentID = conversation.parentID, let forkMessageID = conversation.forkMessageID else {
            return (conversation.messages, false)
        }
        guard !visited.contains(parentID), let parent = lookup(parentID) else {
            return (conversation.messages, true)
        }
        let (parentMessages, parentBroken) = resolveMessages(
            parent, lookup: lookup, visited: visited.union([parentID])
        )
        guard let cut = parentMessages.firstIndex(where: { $0.id == forkMessageID }) else {
            return (conversation.messages, true)
        }
        return (Array(parentMessages.prefix(through: cut)) + conversation.messages, parentBroken)
    }

    static func loadResolved(id: UUID) -> (conversation: Conversation, messages: [ChatMessage], missingParent: Bool)? {
        guard let conversation = load(id: id) else { return nil }
        let (messages, missingParent) = resolveMessages(conversation)
        return (conversation, messages, missingParent)
    }

    /// Direct children of `id` absorb the shared prefix and become standalone
    /// roots. Call before a conversation's transcript stops being able to serve
    /// them — deletion, pruning, or a truncation that cuts away a fork point.
    static func materializeChildren(of id: UUID) {
        let all = loadAll()
        for child in all.values where child.parentID == id {
            materialize(child, in: all)
        }
    }

    /// Delete with fork safety: direct children absorb the shared prefix and
    /// become standalone roots before the parent's file is removed.
    static func deleteMaterializingChildren(id: UUID) {
        materializeChildren(of: id)
        delete(id: id)
    }

    private static func materialize(_ conversation: Conversation, in all: [UUID: Conversation]) {
        var standalone = conversation
        (standalone.messages, _) = resolveMessages(conversation, lookup: { all[$0] }, visited: [conversation.id])
        standalone.parentID = nil
        standalone.forkMessageID = nil
        save(standalone)
    }

    /// Every stored conversation with its transcript already resolved through
    /// the fork chain — the one walk `listRecent` and `fullTextIndex` both need,
    /// memoized so a chain shared by several forks is resolved once.
    private static func loadAllResolved() -> (all: [UUID: Conversation], resolved: [UUID: [ChatMessage]]) {
        let all = loadAll()
        var resolved: [UUID: [ChatMessage]] = [:]
        for conversation in all.values {
            guard resolved[conversation.id] == nil else { continue }
            (resolved[conversation.id], _) = resolveMessages(
                conversation, lookup: { all[$0] }, visited: [conversation.id]
            )
        }
        return (all, resolved)
    }

    private static func loadAll() -> [UUID: Conversation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [UUID: Conversation] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conversation = try? decoder.decode(Conversation.self, from: data) else { continue }
            result[conversation.id] = conversation
        }
        return result
    }

    // MARK: - Cross-conversation search

    /// Every stored conversation's resolved transcript, flattened to one
    /// searchable string each, for the history popover's content search.
    ///
    /// A full linear read, deliberately: the store is capped at `maxStored`, so
    /// this is a bounded scan rather than an index that can drift out of sync
    /// with the files. It is also why the popover builds it OFF the main actor
    /// after presenting — decoding fifty transcripts is milliseconds, but not
    /// zero, and the popover's designed pop-in must never wait on it.
    ///
    /// Reasoning is excluded: it lives behind a collapsed disclosure, so a hit
    /// there would send the user to a chat with nothing visibly matching.
    static func fullTextIndex() -> [UUID: String] {
        loadAllResolved().resolved.mapValues { messages in
            messages
                .filter { $0.role == .user || $0.role == .assistant }
                .map(\.text)
                .joined(separator: "\n")
        }
    }

    /// The text around the first case-insensitive hit, for a search result row:
    /// enough before it to read as a sentence, tail-padded, newlines collapsed
    /// so it stays exactly one line (the popover's row heights are fixed).
    ///
    /// The match comes from `FindHighlight.ranges` — the same matcher whose
    /// options decide what the row then PAINTS. Spelling the search out here
    /// again is how an excerpt ends up containing a "hit" the painter won't tint.
    static func excerpt(of text: String, matching query: String, context: Int = 44) -> String? {
        guard let first = FindHighlight.ranges(in: text, query: query).first,
              let range = Range(first, in: text) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex)
        let end = text.index(range.upperBound, offsetBy: context * 2, limitedBy: text.endIndex)
        var excerpt = String(text[(start ?? text.startIndex)..<(end ?? text.endIndex)])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if start != nil, start != text.startIndex { excerpt = "…" + excerpt }
        if end != nil, end != text.endIndex { excerpt += "…" }
        return excerpt
    }

    /// Newest first, snippets from the fully-resolved transcript. Also prunes
    /// storage beyond `maxStored` (materializing children of pruned parents).
    static func listRecent() -> [ConversationMeta] {
        let (all, resolved) = loadAllResolved()
        var metas = all.values.map { conversation in
            ConversationMeta(
                id: conversation.id,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                snippet: ConversationMeta.snippet(for: resolved[conversation.id] ?? conversation.messages),
                isFork: conversation.parentID != nil
            )
        }
        metas.sort { $0.updatedAt > $1.updatedAt }
        for stale in metas.dropFirst(maxStored) {
            guard let conversation = all[stale.id] else { continue }
            for child in all.values where child.parentID == conversation.id {
                materialize(child, in: all)
            }
            delete(id: stale.id)
        }
        return Array(metas.prefix(maxStored))
    }
}
