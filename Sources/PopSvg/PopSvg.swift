import AppKit

public enum PopSvg {
    public static let edit = load("edit")
    public static let history = load("history")
    public static let pin = load("pin")
    public static let reasoning = load("reasoning")
    public static let copy = load("copy")
    public static let copyCheck = load("copy-check")
    public static let fork = load("fork")
    public static let retry = load("retry")
    public static let editPrompt = load("Edit-prompt")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
