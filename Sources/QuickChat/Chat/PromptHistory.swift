import Foundation

/// The prompts you have actually sent, newest first — what ↑ walks back through
/// from an empty composer.
///
/// Deliberately global rather than per-conversation: the recall you want in a
/// scratch panel is "that thing I asked earlier", and which chat it happened in
/// is not how anyone remembers it. Recorded by `ChatStore.send`, not by the
/// composer — the composer is not the only thing that sends (Retry does too),
/// and "a prompt you sent" is a fact about the send, not about the field it was
/// typed in.
enum PromptHistory {
    static let maxEntries = 50
    private static let key = "promptHistory"

    static var entries: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Records a sent prompt at the front, deduplicated: asking the same thing
    /// twice should not cost two ↑ presses to get past.
    static func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = entries
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxEntries)), forKey: key)
    }
}
