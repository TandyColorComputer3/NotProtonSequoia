import AppKit

@MainActor
enum SteamLauncher {

    static func open() {
        let workspace = NSWorkspace.shared
        let steam = SupportPaths.Steam.app.standardizedFileURL

        if let running = workspace.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == steam
        }) {
            running.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.appleEvent = nil
        workspace.openApplication(at: steam, configuration: configuration, completionHandler: nil)
    }
}
