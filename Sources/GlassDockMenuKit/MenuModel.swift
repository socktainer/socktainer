import AppKit
import Combine
import GlassDockControl

public enum MenuSection: String, Hashable, CaseIterable {
    case containers = "Containers"
    case system = "System"
}

@MainActor
public final class MenuModel: ObservableObject {
    @Published public private(set) var snapshot: ControlSnapshot?
    @Published public private(set) var supportReport: SupportReport?
    @Published public private(set) var containerLog: LogOutput?
    @Published public private(set) var presentedContainer: ContainerSummary?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoadingContainerLog = false
    @Published public private(set) var didCopySupportReport = false
    @Published public var selectedSection = MenuSection.containers
    @Published public var errorMessage: String?

    private let client: ControlClient

    public init(client: ControlClient = ControlClient()) {
        self.client = client
    }

    public var statusLabel: String { snapshot?.daemon.state.rawValue.capitalized ?? "Checking" }

    public var statusSymbol: String {
        switch snapshot?.daemon.state {
        case .running: "shippingbox.fill"
        case .starting: "clock"
        case .unhealthy: "exclamationmark.triangle.fill"
        case .stopped, nil: "shippingbox"
        }
    }

    public func refresh() async {
        isLoading = true
        snapshot = await client.snapshot()
        isLoading = false
    }

    public func refreshSupportReport() async {
        isLoading = true
        supportReport = await client.supportReport()
        snapshot = supportReport?.snapshot
        isLoading = false
    }

    public func perform(_ action: ControlAction) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await client.perform(action)
            try await Task.sleep(for: .milliseconds(400))
            snapshot = await client.snapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func showContainerLogs(for container: ContainerSummary) async {
        presentedContainer = container
        containerLog = nil
        isLoadingContainerLog = true
        defer { isLoadingContainerLog = false }
        do {
            containerLog = try await client.containerLogs(identifier: container.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func closeContainerLogs() {
        presentedContainer = nil
        containerLog = nil
    }

    public func copyContainerLogs() {
        guard let text = containerLog?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func copySupportReport() async {
        if supportReport == nil {
            await refreshSupportReport()
        }
        guard let text = supportReport?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopySupportReport = true
        try? await Task.sleep(for: .seconds(2))
        didCopySupportReport = false
    }
}
