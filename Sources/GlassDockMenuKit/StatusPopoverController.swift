import AppKit
import SwiftUI

@MainActor
protocol StatusPopoverPresenting: AnyObject {
    var isShown: Bool { get }
    func show()
    func close()
}

@MainActor
protocol ApplicationFocusControlling: AnyObject {
    func activateForPopover()
    func restorePreviousApplication()
}

@MainActor
private final class ApplicationFocusController: ApplicationFocusControlling {
    private var previousApplication: NSRunningApplication?

    func activateForPopover() {
        let currentIdentifier = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != currentIdentifier
        {
            previousApplication = frontmost
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func restorePreviousApplication() {
        defer { previousApplication = nil }
        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        else {
            return
        }
        previousApplication?.activate()
    }
}

@MainActor
private final class AppKitStatusPopoverPresenter: NSObject, StatusPopoverPresenting, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    var onToggle: (() -> Void)?
    var onClose: (() -> Void)?

    override init() {
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Glass Dock")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Glass Dock"
            button.setAccessibilityLabel("Glass Dock menu")
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 680)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func install<Content: View>(content: Content) {
        popover.contentViewController = NSHostingController(rootView: content)
    }

    func show() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }

    @objc private func togglePopover() {
        onToggle?()
    }
}

@MainActor
public final class StatusPopoverController {
    private let popover: any StatusPopoverPresenting
    private let applicationFocus: any ApplicationFocusControlling

    public convenience init(model: MenuModel) {
        let presenter = AppKitStatusPopoverPresenter()
        self.init(popover: presenter, applicationFocus: ApplicationFocusController())
        presenter.onToggle = { [weak self] in self?.togglePopover() }
        presenter.onClose = { [weak self] in self?.didClosePopover() }
        presenter.install(
            content: StatusPopoverView(
                model: model,
                closePopover: { [weak self] in self?.closePopover() }
            )
        )
    }

    init(
        popover: any StatusPopoverPresenting,
        applicationFocus: any ApplicationFocusControlling
    ) {
        self.popover = popover
        self.applicationFocus = applicationFocus
    }

    public func togglePopover() {
        if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        guard !popover.isShown else { return }
        applicationFocus.activateForPopover()
        popover.show()
    }

    public func closePopover() {
        guard popover.isShown else { return }
        popover.close()
    }

    func didClosePopover() {
        applicationFocus.restorePreviousApplication()
    }
}
