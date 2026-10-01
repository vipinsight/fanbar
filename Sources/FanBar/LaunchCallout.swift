import AppKit

/// A short "FanBar is running" callout under the status item.
///
/// FanBar has no window of its own, so without this a launch from Finder or
/// Spotlight looks like nothing happened. It fades in under the menu bar
/// readout, stays a few seconds, and goes away on its own or when clicked.
final class LaunchCallout {
    private var panel: NSPanel?

    func show(below button: NSStatusBarButton?) {
        dismiss()
        let size = NSSize(width: 270, height: 68)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismiss)))

        let icon = NSImageView(image: NSApp.applicationIconImage)
        let title = NSTextField(labelWithString: "FanBar is running")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let detail = NSTextField(labelWithString: "Find it here in the menu bar.")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background

        panel.setFrameOrigin(origin(for: size, below: button))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.dismiss()
        }
    }

    /// Centered under the status item, kept on screen; top center of the screen if it has no window yet.
    private func origin(for size: NSSize, below button: NSStatusBarButton?) -> NSPoint {
        let screen = button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let anchor = button?.window?.frame else {
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8)
        }
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: anchor.minY - size.height - 6)
    }

    @objc func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
