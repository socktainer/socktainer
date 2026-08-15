import AppKit
import GlassDockControl
import SwiftUI

public struct StatusPopoverView: View {
    @ObservedObject private var model: MenuModel
    private let closePopover: () -> Void

    public init(model: MenuModel, closePopover: @escaping () -> Void) {
        self.model = model
        self.closePopover = closePopover
    }

    public var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider()

            if model.presentedContainer != nil {
                ContainerLogSurface(model: model)
            } else {
                VStack(spacing: 10) {
                    Picker("View", selection: $model.selectedSection) {
                        ForEach(MenuSection.allCases, id: \.self) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { model.errorMessage = nil }
                            .padding(.horizontal, 16)
                    }

                    switch model.selectedSection {
                    case .containers:
                        ContainersSurface(model: model)
                    case .system:
                        SystemSurface(model: model)
                    }
                }
            }

            Divider()
            PopoverFooter(model: model, closePopover: closePopover)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 480, height: 680)
        .onExitCommand(perform: closePopover)
        .task {
            if model.snapshot == nil {
                await model.refresh()
            }
        }
    }
}

private struct PopoverHeader: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: model.statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Glass Dock \(model.statusLabel)")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing Glass Dock")
            }

            Button {
                Task {
                    if model.selectedSection == .system {
                        await model.refreshSupportReport()
                    } else {
                        await model.refresh()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh")
            .accessibilityLabel("Refresh Glass Dock")
        }
    }

    private var subtitle: String {
        let containers = model.snapshot?.containers ?? []
        let counts = "\(containers.filter(\.isRunning).count) running, \(containers.count) total"
        if let version = model.snapshot?.daemon.version {
            return "Version \(version) · \(counts)"
        }
        return model.snapshot?.daemon.message ?? counts
    }

    private var statusColor: Color {
        switch model.snapshot?.daemon.state {
        case .running: .green
        case .unhealthy: .orange
        case .starting: .blue
        case .stopped, nil: .secondary
        }
    }
}

private struct ContainersSurface: View {
    @ObservedObject var model: MenuModel
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    init(model: MenuModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search containers", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)
                .accessibilityLabel("Search containers by name, image, state, or identifier")
                .padding(.horizontal, 16)

            Group {
                if model.snapshot == nil {
                    ProgressView("Checking containers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.snapshot?.daemon.healthy != true {
                    ContentUnavailableView(
                        "Containers unavailable",
                        systemImage: "shippingbox",
                        description: Text(model.snapshot?.daemon.message ?? "Glass Dock is not available.")
                    )
                } else if filteredContainers.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No containers" : "No matching containers",
                        systemImage: searchText.isEmpty ? "shippingbox" : "magnifyingglass",
                        description: searchText.isEmpty
                            ? Text("Created containers will appear here.")
                            : Text("Change the search text and try again.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredContainers) { container in
                                ContainerRow(model: model, container: container)
                                if container.id != filteredContainers.last?.id {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 2)
        .task { searchIsFocused = true }
    }

    private var filteredContainers: [ContainerSummary] {
        let containers = model.snapshot?.containers ?? []
        guard !searchText.isEmpty else { return containers }
        return containers.filter {
            [$0.name, $0.image, $0.state, $0.status, $0.id]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

private struct ContainerRow: View {
    @ObservedObject var model: MenuModel
    let container: ContainerSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: container.isRunning ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(container.isRunning ? .green : .secondary)
                .frame(width: 28, height: 28)
                .accessibilityLabel(container.isRunning ? "Running" : "Stopped")

            VStack(alignment: .leading, spacing: 3) {
                Text(container.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(container.image) · \(container.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button("Logs") {
                Task { await model.showContainerLogs(for: container) }
            }
            .controlSize(.small)
            .help("Show logs for \(container.name)")

            if container.isRunning {
                Button("Stop", role: .destructive) {
                    Task { await model.perform(.stopContainer(container.id)) }
                }
                .controlSize(.small)
                .accessibilityHint("Stops \(container.name)")
            } else {
                Button("Start") {
                    Task { await model.perform(.startContainer(container.id)) }
                }
                .controlSize(.small)
                .accessibilityHint("Starts \(container.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
    }
}

private struct ContainerLogSurface: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.closeContainerLogs()
                } label: {
                    Label("Containers", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text(model.presentedContainer?.name ?? "Container logs")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button("Copy") { model.copyContainerLogs() }
                    .disabled(model.containerLog?.text.isEmpty != false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.isLoadingContainerLog {
                ProgressView("Loading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView(
                    "Logs unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                        .textSelection(.enabled)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logText: String {
        guard let text = model.containerLog?.text, !text.isEmpty else {
            return "No logs are available."
        }
        return text
    }
}

private struct SystemSurface: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot {
                    SystemGroup(title: "Health", systemImage: "heart.text.square") {
                        InfoGrid(rows: [
                            ("Daemon", snapshot.daemon.healthy ? "Healthy" : "Unavailable"),
                            ("VM", snapshot.daemon.virtualMachineHealth?.rawValue.capitalized ?? "Not reported"),
                            ("Socket", snapshot.daemon.socketReachable ? "Connected" : "Unavailable"),
                            ("Socket file", snapshot.daemon.socketExists ? "Present" : "Missing"),
                        ])
                    }

                    SystemGroup(title: "Build", systemImage: "hammer") {
                        InfoGrid(rows: [
                            ("Version", snapshot.daemon.version ?? "Not reported"),
                            ("Docker API", snapshot.daemon.apiVersion ?? "Not reported"),
                            ("Git commit", snapshot.daemon.gitCommit ?? "Not reported"),
                            ("Build time", snapshot.daemon.buildTime ?? "Not reported"),
                        ])
                    }

                    SystemGroup(title: "Control", systemImage: "switch.2") {
                        InfoGrid(rows: [
                            ("Ownership", ownershipText(snapshot.diagnostics.ownership)),
                            ("Installation", installationText(snapshot.diagnostics.installation.kind)),
                            ("Executable", snapshot.diagnostics.installation.executablePath ?? "Not found"),
                        ])
                    }

                    SystemGroup(title: "Disk", systemImage: "internaldrive") {
                        if let disk = snapshot.diagnostics.diskSpace {
                            InfoGrid(rows: [
                                ("Signal", disk.level.rawValue.capitalized),
                                ("Available", ByteCountFormatter.string(fromByteCount: disk.availableBytes, countStyle: .file)),
                                ("Total", ByteCountFormatter.string(fromByteCount: disk.totalBytes, countStyle: .file)),
                                ("Volume", disk.volumePath),
                            ])
                        } else {
                            Text("Disk-space data is not available.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup("Paths") {
                        InfoGrid(rows: pathRows(snapshot.diagnostics.paths))
                            .padding(.top, 8)
                        Button("Open Log Folder") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: snapshot.diagnostics.paths.logDirectory, isDirectory: true)
                            )
                        }
                        .disabled(!FileManager.default.fileExists(atPath: snapshot.diagnostics.paths.logDirectory))
                        .padding(.top, 6)
                    }
                    .disclosureGroupStyle(.automatic)
                    .padding(12)
                    .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))

                    DisclosureGroup("Recent managed logs") {
                        RecentLogsView(logs: model.supportReport?.recentLogs ?? [])
                            .padding(.top, 8)
                    }
                    .padding(12)
                    .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))

                    Button {
                        Task { await model.copySupportReport() }
                    } label: {
                        Label(
                            model.didCopySupportReport ? "Support Report Copied" : "Copy Support Report",
                            systemImage: model.didCopySupportReport ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHint("Copies bounded status and diagnostic data")
                } else {
                    ProgressView("Collecting system information…")
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .task {
            if model.supportReport == nil {
                await model.refreshSupportReport()
            }
        }
    }

    private var snapshot: ControlSnapshot? { model.supportReport?.snapshot ?? model.snapshot }

    private func ownershipText(_ ownership: ControlOwnership) -> String {
        switch ownership {
        case .managedLaunchAgent: "Managed by this app"
        case .unmanaged: "Started outside this app"
        case .none: "Not running"
        }
    }

    private func installationText(_ kind: InstallationKind) -> String {
        switch kind {
        case .localBuild: "Local build"
        case .notFound: "Not found"
        default: kind.rawValue.capitalized
        }
    }

    private func pathRows(_ paths: ControlPaths) -> [(String, String)] {
        [
            ("Socket", paths.socket),
            ("Logs", paths.logDirectory),
            ("Standard output", paths.standardOutputLog),
            ("Standard error", paths.standardErrorLog),
            ("LaunchAgent", paths.launchAgent),
            ("Control lock", paths.controlLock),
            ("Engine state", paths.defaultEngineStateDirectory),
        ]
    }
}

private struct SystemGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private struct RecentLogsView: View {
    let logs: [LogOutput]

    var body: some View {
        if logs.isEmpty {
            Text("No managed logs are available. A daemon that was started outside this app writes to its own output streams.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(logHeading(log))
                            .font(.caption.weight(.semibold))
                        ScrollView(.horizontal) {
                            Text(log.text.isEmpty ? "No log content." : log.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
        }
    }

    private func logHeading(_ log: LogOutput) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(log.byteCount), countStyle: .file)
        return "\(log.source) · \(bytes)\(log.truncated ? " · truncated" : "")"
    }
}

private struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    Text(row.1)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(9)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct PopoverFooter: View {
    @ObservedObject var model: MenuModel
    let closePopover: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            lifecycleControls
            Spacer(minLength: 8)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var lifecycleControls: some View {
        if let snapshot = model.snapshot {
            switch snapshot.diagnostics.ownership {
            case .unmanaged:
                Label("Started outside this app", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("This app will not stop or restart the current daemon.")
            case .managedLaunchAgent:
                if snapshot.daemon.state == .stopped {
                    Button("Start Glass Dock") { Task { await model.perform(.startDaemon) } }
                } else {
                    Button("Restart") { Task { await model.perform(.restartDaemon) } }
                    Button("Stop", role: .destructive) { Task { await model.perform(.stopDaemon) } }
                }
            case .none:
                Button("Start Glass Dock") { Task { await model.perform(.startDaemon) } }
            }
        } else {
            Text("Checking control…")
                .foregroundStyle(.secondary)
        }
    }
}
