import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global toggle for the chat panel. Option+Space by default; user-configurable
    /// via the recorder in Settings. Carbon-based, so no Accessibility permission needed.
    static let toggleQuickChat = Self("togglePopChat", default: .init(.space, modifiers: [.option]))
}
