import AppKit

@MainActor
final class AppUpdater {

    func check() {
        // Fork releases are manual until we have our own signed update feed.
        if let url = URL(string: "https://github.com/TandyColorComputer3/NotProtonSequoia/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
