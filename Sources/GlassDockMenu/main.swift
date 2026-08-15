import AppKit
import GlassDockMenuKit

@main
struct GlassDockMenuApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate(arguments: CommandLine.arguments)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private let model = MenuModel()
    private var popoverController: StatusPopoverController?

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusPopoverController(model: model)
        popoverController = controller

        if arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.showPopover()
            }
        }

        Task { await model.refresh() }
    }
}
