// Resource lookup for both a packaged macOS app and SwiftPM development builds.

import Foundation

enum AppResources {
    static let bundle: Bundle = {
        let name = "NotProtonApp_NotProtonApp.bundle"

        // SwiftPM 6.1's generated Bundle.module accessor looks only beside
        // Contents, which is not a valid location in a signed macOS app.
        // Packaged resources belong in Contents/Resources.
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent(name)) {
            return packaged
        }

        // Keep compatibility with unpackaged bundles and the manual workaround
        // used by early Sequoia-fork testers.
        if let adjacent = Bundle(
            url: Bundle.main.bundleURL.appendingPathComponent(name)
        ) {
            return adjacent
        }

        // SwiftPM test and command-line builds use its generated build-tree
        // location. This is evaluated only when neither app location exists.
        return Bundle.module
    }()
}
