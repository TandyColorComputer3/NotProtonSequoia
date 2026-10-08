import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: "Status"
        case .prefixes: "Prefixes"
        case .backups: "Prefix Backups"
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        }
    }
}

struct RootView: View {

    @Environment(SystemStatus.self) private var status
    @Binding var pane: Pane

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $pane) {
                    ForEach(Pane.allCases) { item in
                        Label(item.label, systemImage: item.symbol)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
                .frame(height: 124)

                Divider()
                SetupGuide()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch pane {
            case .status: StatusView()
            case .prefixes: PrefixesView()
            case .backups: BackupsView()
            }
        }
        .task { await watchSteam() }
    }

    private func watchSteam() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            let running = await Task.detached(priority: .utility) {
                SteamBundle.isRunning
            }.value
            if status.snapshot?.steamRunning != running {
                status.snapshot?.steamRunning = running
            }
        }
    }
}

private struct SetupGuide: View {
    @Environment(SystemStatus.self) private var status

    private var steamReady: Bool {
        guard let snapshot = status.snapshot else { return false }
        guard case .installed(let version) = snapshot.steam,
              version == AppVersion.bundled
        else { return false }
        return snapshot.installContent == .current || snapshot.installContent == .unchecked
    }

    private var crossOverReady: Bool {
        if toolReady { return true }
        guard let runner = status.snapshot?.runner else { return false }
        return runner.builds.isEmpty ? status.usableCrossOver != nil : status.repairSource != nil
    }

    private var requiredCrossOver: RunnerBuild? {
        guard !toolReady, let runner = status.snapshot?.runner else { return nil }
        return runner.builds.compactMap(SupportedRunners.build(id:)).first
    }

    private var crossOverInstruction: String {
        if toolReady {
            return "Your existing compatibility tool is ready. You do not need to choose CrossOver again."
        }
        if crossOverReady {
            return "The CrossOver build that matches your compatibility tool is selected."
        }
        if let requiredCrossOver {
            return "Choose CrossOver Preview " + requiredCrossOver.releaseVersion
                + ". A green dot on a different CrossOver only means that app is supported."
        }
        return "Choose the CrossOver app you want NotProton to use."
    }

    private var chooseCrossOverLabel: String {
        requiredCrossOver.map { "Choose " + $0.releaseVersion + "…" } ?? "Choose…"
    }

    private var toolReady: Bool {
        guard let snapshot = status.snapshot,
              case .ready = snapshot.runner
        else { return false }
        return snapshot.payload.missing(origin: .patched).isEmpty
    }

    private var toolLabel: String {
        status.snapshot?.runner == RunnerState.none ? "Set Up" : "Repair"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("After an Update")
                        .font(.headline)
                    Text("Do these in order. Stop when you see a red message and read it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GuideStep(
                    number: 1,
                    title: "Install NotProton",
                    instruction: steamReady
                        ? "The current version is installed."
                        : installInstruction,
                    isDone: steamReady,
                    isCurrent: !steamReady,
                    button: steamReady ? nil : "Install Update",
                    isEnabled: status.canInstall
                ) { Task { await status.requestInstall() } }

                GuideStep(
                    number: 2,
                    title: toolReady ? "Keep Your Existing Tool" : "Choose Matching CrossOver",
                    instruction: crossOverInstruction,
                    isDone: crossOverReady,
                    isCurrent: steamReady && !crossOverReady,
                    button: crossOverReady ? nil : chooseCrossOverLabel,
                    isEnabled: steamReady && status.isIdle
                ) { Task { await status.addCrossOver() } }

                GuideStep(
                    number: 3,
                    title: "Set Up the Tool",
                    instruction: toolReady
                        ? "The game compatibility tool is ready."
                        : "Click below and wait until the app says Done.",
                    isDone: toolReady,
                    isCurrent: steamReady && crossOverReady && !toolReady,
                    button: toolReady ? nil : toolLabel,
                    isEnabled: steamReady && crossOverReady && status.canInstall
                ) { Task { await status.requestCompatibilityTool() } }

                GuideStep(
                    number: 4,
                    title: "Play",
                    instruction: toolReady
                        ? "Open Steam and launch your game."
                        : "Finish the steps above first.",
                    isDone: toolReady && (status.snapshot?.steamRunning ?? false),
                    isCurrent: steamReady && crossOverReady && toolReady,
                    button: toolReady ? "Open Steam" : nil,
                    isEnabled: toolReady
                ) { NSWorkspace.shared.open(SupportPaths.Steam.app) }
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
    }

    private var installInstruction: String {
        if status.failureRemedy?.settingsPane != nil {
            return "macOS blocked it. In the red message, click Open Settings. Turn on NotProton, come back, then click Install Update again."
        }
        return "Click below. If macOS blocks it, allow NotProton in System Settings, then click again."
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let instruction: String
    let isDone: Bool
    let isCurrent: Bool
    let button: String?
    let isEnabled: Bool
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(isDone ? Color.green : isCurrent ? Color.accentColor : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button, action: perform)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isEnabled)
                }
            }
        }
        .opacity(isDone || isCurrent ? 1 : 0.65)
        .accessibilityElement(children: .combine)
    }
}
