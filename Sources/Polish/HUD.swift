import AppKit

/// Small floating, non-activating pill shown near the caret.
final class HUD {
    static let shared = HUD()

    enum Kind { case info, success, error }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private var hideWork: DispatchWorkItem?
    private var anchor: NSRect?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2

        let stack = NSStackView(views: [spinner, icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        panel.contentView = fx
    }

    func showProgress(_ text: String, near rect: NSRect?) {
        anchor = rect
        hideWork?.cancel()
        icon.isHidden = true
        spinner.startAnimation(nil)
        present(text)
    }

    func flash(_ text: String, kind: Kind, duration: TimeInterval = 1.6) {
        spinner.stopAnimation(nil)
        let (name, color): (String, NSColor) = {
            switch kind {
            case .info: return ("info.circle.fill", .secondaryLabelColor)
            case .success: return ("checkmark.circle.fill", .systemGreen)
            case .error: return ("exclamationmark.triangle.fill", .systemOrange)
            }
        }()
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.isHidden = false
        present(text.replacingOccurrences(of: "✓ ", with: ""))
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func present(_ text: String) {
        label.stringValue = text
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 34)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(anchor?.origin ?? mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        var p: NSPoint
        if let a = anchor, a.height < 200 {
            p = NSPoint(x: a.minX, y: a.minY - size.height - 6) // just below the caret / field
        } else if let a = anchor {
            p = NSPoint(x: a.midX - size.width / 2, y: a.minY + 12) // tall field: bottom inside
        } else {
            p = NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 80)
        }
        p.x = min(max(p.x, vis.minX + 8), vis.maxX - size.width - 8)
        p.y = min(max(p.y, vis.minY + 8), vis.maxY - size.height - 8)
        return p
    }
}
