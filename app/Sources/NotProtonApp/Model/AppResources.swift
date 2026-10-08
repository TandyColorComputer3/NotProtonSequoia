// Resource lookup for both a packaged macOS app and SwiftPM development builds.

import Foundation

enum AppResources {
    static func url(forResource resource: String, withExtension extension_: String) -> URL? {
        let name = "NotProtonApp_NotProtonApp.bundle"
        let file = "\(resource).\(extension_)"

        // SwiftPM 6.1's generated Bundle.module accessor looks only beside
        // Contents, which is not a valid location in a signed macOS app.
        // Packaged resources belong in Contents/Resources. SwiftPM resource
        // directories can be flat and have no Info.plist, so read their files
        // directly rather than requiring Foundation to recognize a Bundle.
        let packaged = Bundle.main.bundleURL
            .appending(path: "Contents/Resources")
            .appending(path: name)
            .appending(path: file)
        if FileManager.default.isReadableFile(atPath: packaged.path(percentEncoded: false)) {
            return packaged
        }

        // Keep compatibility with unpackaged bundles and the manual workaround
        // used by early Sequoia-fork testers.
        let adjacent = Bundle.main.bundleURL.appending(path: name).appending(path: file)
        if FileManager.default.isReadableFile(atPath: adjacent.path(percentEncoded: false)) {
            return adjacent
        }

        // SwiftPM test and command-line builds use its generated build-tree
        // location. This is evaluated only when neither app location exists.
        return Bundle.module.url(forResource: resource, withExtension: extension_)
    }
}
