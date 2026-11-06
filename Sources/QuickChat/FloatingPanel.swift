import AppKit
import SwiftUI

/// The popup window. `.nonactivatingPanel` is the load-bearing style: the panel can
/// take keyboard focus without activating QuickChat, so the previously active app stays
/// active and regains typing focus the instant the panel closes.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onAttachablePaste: (() -> Void)?

    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    private var leftGuide: NSPanel?
    private var rightGuide: NSPanel?
    private var topGuide: NSPanel?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Dragging is confined to the top pill strip (WindowDragStrip in
        // ChatView) — whole-background dragging stole drags that should start
        // text selections in the transcript.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // The SwiftUI content draws its own rounded glass shell; the window itself
        // is a clear canvas (the system shadow follows the drawn shape).
        isOpaque = false
        backgroundColor = .clear
        // The controller hand-animates show/hide (fade + rise); the system
        // animation would double up.
        animationBehavior = .none
        isReleasedWhenClosed = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func beginDrag(at pointer: NSPoint) {
        stopDragGuides()
        dragStart = (pointer, frame.origin)
    }

    func continueDrag(at pointer: NSPoint) {
        guard let dragStart else { return }
        // Keep the unsnapped position tied to the original grab point so the
        // pointer can pull the window out of the snap area without a jump in offset.
        let proposedOrigin = NSPoint(
            x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
            y: dragStart.origin.y + pointer.y - dragStart.pointer.y
        )
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? screen else {
            hideDragGuides()
            setFrameOrigin(proposedOrigin)
            return
        }

        let area = display.visibleFrame
        let top = min(area.maxY, max(area.minY + frame.height, display.frame.maxY - display.frame.height * 0.15))
        let target = NSRect(x: area.midX - frame.width / 2, y: top - frame.height,
                            width: frame.width, height: frame.height)
        let dx = proposedOrigin.x - target.minX
        let dy = proposedOrigin.y - target.minY
        let distance = hypot(dx, dy)
        // Ease from full alignment to free movement with a flat slope at both
        // boundaries. Pulling away follows the same curve as approaching.
        let progress = min(1, max(0, (distance - 10) / 36))
        let movement = progress * progress * (3 - 2 * progress)
        let origin = NSPoint(x: target.minX + dx * movement, y: target.minY + dy * movement)
        if frame.origin != origin { setFrameOrigin(origin) }
        updateDragGuides(for: target, in: area, withinSnapArea: progress < 1)
    }

    func finishDrag() {
        dragStart = nil
        for guide in [leftGuide, rightGuide, topGuide] {
            (guide?.contentView as? DragGuideView)?.finishDrag()
        }
    }

    func stopDragGuides() {
        dragStart = nil
        hideDragGuides()
    }

    private func hideDragGuides() {
        for guide in [leftGuide, rightGuide, topGuide] {
            (guide?.contentView as? DragGuideView)?.reset()
            guide?.orderOut(nil)
        }
    }

    private func updateDragGuides(for target: NSRect, in area: NSRect, withinSnapArea: Bool) {
        let thickness: CGFloat = 2
        showDragGuide(&leftGuide, at: NSRect(
            x: target.minX - thickness, y: area.minY, width: thickness, height: area.height
        ), in: area, aligned: withinSnapArea && abs(frame.minX - target.minX) < 0.5)
        showDragGuide(&rightGuide, at: NSRect(
            x: target.maxX, y: area.minY, width: thickness, height: area.height
        ), in: area, aligned: withinSnapArea && abs(frame.maxX - target.maxX) < 0.5)
        showDragGuide(&topGuide, at: NSRect(
            x: area.minX, y: target.maxY, width: area.width, height: thickness
        ), in: area, aligned: withinSnapArea && abs(frame.maxY - target.maxY) < 0.5)
    }

    private func showDragGuide(_ guide: inout NSPanel?, at rect: NSRect, in area: NSRect, aligned: Bool) {
        guard area.intersects(rect) else {
            (guide?.contentView as? DragGuideView)?.reset()
            if guide?.isVisible == true { guide?.orderOut(nil) }
            return
        }
        if guide == nil { guide = makeDragGuide() }
        guard let guide, let view = guide.contentView as? DragGuideView else { return }
        if guide.frame != rect { view.reset() }
        if guide.frame.size != rect.size {
            guide.contentView?.needsDisplay = true
            guide.setFrame(rect, display: true)
        } else if guide.frame.origin != rect.origin {
            guide.setFrameOrigin(rect.origin)
        }
        if !guide.isVisible { guide.order(.below, relativeTo: windowNumber) }
        view.setAligned(aligned)
    }

    private func makeDragGuide() -> NSPanel {
        let guide = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        guide.level = level
        guide.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        guide.ignoresMouseEvents = true
        guide.hidesOnDeactivate = false
        guide.animationBehavior = .none
        guide.isOpaque = false
        guide.hasShadow = false
        guide.backgroundColor = .clear
        guide.contentView = DragGuideView()
        return guide
    }

    /// ⌘V with files or a raw image on the pasteboard becomes an attachment.
    /// Must run here, before the Edit menu's Paste equivalent fires — otherwise
    /// `paste:` would insert file paths as text into the field editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let onAttachablePaste,
           Self.pasteboardHasAttachable(NSPasteboard.general) {
            onAttachablePaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func pasteboardHasAttachable(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return true
        }
        return pasteboard.string(forType: .string) == nil
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}

private final class DragGuideView: NSView {
    private static let pulseDuration: TimeInterval = 3
    private var pulseTimer: Timer?
    private var pulseStarted: TimeInterval = 0
    private var releasedAt: TimeInterval?
    private var isAligned = false

    func setAligned(_ aligned: Bool) {
        guard aligned != isAligned else { return }
        isAligned = aligned
        guard aligned, pulseTimer == nil else { return }
        pulseStarted = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                if ProcessInfo.processInfo.systemUptime - self.pulseStarted >= Self.pulseDuration {
                    self.stopPulse()
                }
                self.needsDisplay = true
            }
        }
        pulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finishDrag() {
        if pulseTimer == nil {
            window?.orderOut(nil)
        } else {
            releasedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    func reset() {
        releasedAt = nil
        isAligned = false
        stopPulse()
        needsDisplay = true
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        if releasedAt != nil { window?.orderOut(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let horizontal = bounds.width > bounds.height
        let path = NSBezierPath()
        if horizontal {
            path.move(to: NSPoint(x: bounds.minX, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        } else {
            path.move(to: NSPoint(x: bounds.midX, y: bounds.maxY))
            path.line(to: NSPoint(x: bounds.midX, y: bounds.minY))
        }
        path.lineWidth = 2
        path.setLineDash([7, 11], count: 2, phase: 0)
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let gray = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 0.46)
        let blue = NSColor(srgbRed: 0.39, green: 0.72, blue: 1, alpha: 0.92)
        let elapsed = ProcessInfo.processInfo.systemUptime - pulseStarted
        let progress = min(1, elapsed / Self.pulseDuration)
        let tint = pulseTimer == nil ? 0 : pow(sin(.pi * progress), 2)
        let color = gray.blended(withFraction: tint, of: blue) ?? gray
        let fade = releasedAt.map {
            max(0, Self.pulseDuration - elapsed) / max(0.001, Self.pulseDuration - ($0 - pulseStarted))
        } ?? 1
        color.withAlphaComponent(color.alphaComponent * fade).setStroke()
        path.stroke()
    }
}

/// Transparent surface that drags the window — placed behind the top pill row,
/// the only draggable region of the panel.
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? FloatingPanel {
            panel.beginDrag(at: panel.convertPoint(toScreen: event.locationInWindow))
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        (window as? FloatingPanel)?.continueDrag(at: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        (window as? FloatingPanel)?.finishDrag()
    }

    /// The strip overlays the transcript; forward scroll events so two-finger
    /// scrolling keeps working when the cursor is over it.
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = Self.findScrollView(window?.contentView) {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private static func findScrollView(_ view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = findScrollView(sub) { return found }
        }
        return nil
    }
}

struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}
