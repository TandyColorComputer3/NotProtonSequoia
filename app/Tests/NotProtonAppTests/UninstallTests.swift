import Foundation
import Testing

@testable import NotProtonApp

// Every path is passed explicitly. The defaults are /Applications/Steam.app, the real
// steam.cfg and the real caches directory, so leaning on them would uninstall this machine.
@Suite("Uninstall")
struct UninstallTests {

    // The report closure is Sendable, so what it records has to be too.
    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [UninstallPhase] = []
        func add(_ phase: UninstallPhase) { lock.lock(); seen.append(phase); lock.unlock() }
        var all: [UninstallPhase] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private struct Layout: Sendable {
        let root: URL
        let app: URL
        let innerPlist: URL
        let updateBlock: URL
        let legacyCompat: URL
        let compatTool: URL
        let support: URL
        let caches: URL

        var compatTools: [URL] {
            SupportPaths.Steam.notprotonTools(in: compatTool.deletingLastPathComponent())
        }
        var secondTool: URL { compatTool.deletingLastPathComponent().appending(path: "notproton-26.3") }
        var foreignTool: URL { compatTool.deletingLastPathComponent().appending(path: "GE-Proton9-1") }

        var outerPlist: URL { app.appending(path: "Contents/Info.plist") }
        var dylib: URL { app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)") }
    }

    private func layout(signable: Bool = false) throws -> Layout {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "np-uninstall-\(UUID().uuidString)")
        let app = root.appending(path: "Steam.app")
        let macOS = app.appending(path: "Contents/MacOS")
        let inner = root.appending(path: "inner")
        let legacyCompat = inner.appending(path: "legacycompat")
        let compatTool = root.appending(path: "compatibilitytools.d/notproton")
        let support = root.appending(path: "notproton")
        let caches = root.appending(path: "valve-packages")

        let tools = compatTool.deletingLastPathComponent()
        for dir in [macOS, inner, legacyCompat, compatTool, support, caches,
                    tools.appending(path: "notproton-26.3"), tools.appending(path: "GE-Proton9-1")] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let updateBlock = root.appending(path: "steam.cfg")
        // A client config holding a setting of Valve's beside the one NotProton adds, which is
        // the shape that shows the removal taking out only its own line.
        try Data("BootStrapperInhibitAll=enable\nBootStrapperInhibitUpdateOnLaunch=enable\n".utf8)
            .write(to: updateBlock)
        try Data("1\n".utf8).write(to: support.appending(path: "dylib.version"))
        try Data("archive\n".utf8).write(to: caches.appending(path: "steam_client_osx.zip"))
        try Data("\"run\"\n".utf8).write(to: compatTool.appending(path: "toolmanifest.vdf"))

        let result = Layout(
            root: root,
            app: app,
            innerPlist: inner.appending(path: "Info.plist"),
            updateBlock: updateBlock,
            legacyCompat: legacyCompat,
            compatTool: compatTool,
            support: support,
            caches: caches
        )

        guard signable else { return result }

        // Signed for real rather than stubbed, because the thing worth checking is that a
        // plist edit inside a sealed bundle is followed by a signature that still verifies.
        let source = root.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try Shell.check("/usr/bin/clang", [
            "-o", macOS.appending(path: "steam_osx").path(percentEncoded: false),
            source.path(percentEncoded: false),
        ])
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib",
            "-o", result.dylib.path(percentEncoded: false),
            source.path(percentEncoded: false),
        ])

        let injected: [String: Any] = [
            "CFBundleExecutable": "steam_osx",
            "CFBundleIdentifier": "com.valvesoftware.steam",
            SteamBundle.environmentKey: [
                "LC_ALL": "C",
                SteamBundle.insertKey: result.dylib.path(percentEncoded: false),
            ],
        ]
        try SteamBundle.writeInfoPlist(injected, at: result.outerPlist)
        try SteamBundle.writeInfoPlist(injected, at: result.innerPlist)
        try SteamInstaller.adHocSign(app)

        return result
    }

    @Test("Detaching leaves a Steam that loads nothing of ours")
    func takesEverythingOfOursOutOfTheBundle() throws {
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let files = FileManager.default

        let detached = try Uninstall.detach(
            from: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock]
        )

        #expect(detached)
        #expect(SteamBundle.currentInsert(at: layout.outerPlist) == nil)
        #expect(SteamBundle.currentInsert(at: layout.innerPlist) == nil)
        #expect(!files.fileExists(atPath: layout.dylib.path(percentEncoded: false)))
        #expect(unpinnedWithoutLosingTheRest(layout.updateBlock))

        // LC_ALL is stock and has to survive, or the detach has swapped one difference
        // from Valve's bundle for another.
        let environment = SteamBundle.readInfoPlist(at: layout.outerPlist)?[
            SteamBundle.environmentKey
        ] as? [String: Any]
        #expect(environment?["LC_ALL"] as? String == "C")

        let verified = try Shell.run("/usr/bin/codesign", [
            "--verify", "--deep", layout.app.path(percentEncoded: false),
        ])
        #expect(verified.succeeded)
    }

    // The client is no longer pinned and the setting that was not NotProton's is still there.
    private func unpinnedWithoutLosingTheRest(_ cfg: URL) -> Bool {
        guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return false }
        return !UpdateBlock.isPresent(at: [cfg]) && text.contains("BootStrapperInhibitAll=enable")
    }

    private func verifies(_ app: URL) throws -> Bool {
        try Shell.run("/usr/bin/codesign", [
            "--verify", "--deep", app.path(percentEncoded: false),
        ]).succeeded
    }

    // These hold no signature but used to be cleared after the bundle's own plist, so a throw
    // returned with the bundle edited and unsigned, which is a Steam only a redownload fixes.
    @Test("A removal that fails outside the bundle leaves the bundle alone")
    func failureOutsideTheBundleLeavesItSigned() throws {
        let files = FileManager.default
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        // The block is taken out by rewriting steam.cfg without that line, since the file holds
        // settings of Valve's too, so it is the file that has to refuse the write.
        try files.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: layout.updateBlock.path(percentEncoded: false))
        defer {
            try? files.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: layout.updateBlock.path(percentEncoded: false))
        }

        // Pinned to the refused write rather than to any throw at all, so the test cannot pass
        // on a failure from somewhere else in the removal.
        #expect(throws: WriteRefused.self) {
            try Uninstall.detach(
                from: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock])
        }

        #expect(SteamBundle.currentInsert(at: layout.outerPlist) != nil)
        #expect(try verifies(layout.app))
    }

    // Once the plist is cleared the executable will not validate until it is signed again, so a
    // throw between the two signs anyway. Forward, not back: the client starts carrying nothing.
    @Test("A removal that fails inside the bundle still signs it")
    func failureInsideTheBundleStillSignsIt() throws {
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let dylib = layout.dylib.path(percentEncoded: false)
        try Shell.check("/usr/bin/chflags", ["uchg", dylib])
        defer { _ = try? Shell.check("/usr/bin/chflags", ["nouchg", dylib]) }

        #expect(throws: (any Error).self) {
            try Uninstall.detach(
                from: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock])
        }

        #expect(SteamBundle.currentInsert(at: layout.outerPlist) == nil)
        #expect(try verifies(layout.app))
    }

    @Test("A restore that fails does not cancel the removal")
    func removesEverythingWhenSteamCannotBeRestored() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        struct Offline: Error {}

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            repair: { _ in throw Offline() },
            stop: { _ in false }
        )

        #expect(outcome.restoredValveSignature == false)

        let files = FileManager.default
        #expect(!files.fileExists(atPath: layout.support.path(percentEncoded: false)))
        #expect(!files.fileExists(atPath: layout.caches.path(percentEncoded: false)))
        #expect(!files.fileExists(atPath: layout.legacyCompat.path(percentEncoded: false)))
        #expect(
            !files.fileExists(atPath: layout.compatTool.path(percentEncoded: false)),
            "Steam would still list the tool in its dropdown after a removal"
        )
        #expect(!files.fileExists(atPath: layout.secondTool.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: layout.foreignTool.path(percentEncoded: false)))
        #expect(unpinnedWithoutLosingTheRest(layout.updateBlock))
    }

    @Test("The copy the restore downloads is removed with everything else")
    func removesWhatTheRestoreLeavesBehind() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let caches = layout.caches
        try FileManager.default.removeItem(at: caches)

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, caches],
            libraries: [],
            repair: { _ in
                let staged = caches.appending(path: "bundle")
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("2.6G of Steam".utf8).write(to: staged.appending(path: "Steam.app"))
            },
            stop: { _ in false }
        )

        #expect(outcome.restoredValveSignature)
        #expect(!FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)))
    }

    // Restoring forwards whatever phase repair reached. Carrying the phase rather than its
    // rendering lets this assert on the phase and keeps the wording in one place.
    @Test("A removal reports the repair's own phases while it restores")
    func reportsTheRepairPhases() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let log = PhaseLog()
        _ = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            report: { log.add($0) },
            repair: { report in
                report(.checking)
                report(.replacing)
            },
            stop: { _ in false }
        )

        let restoring = log.all.compactMap { phase -> RepairPhase? in
            if case .restoring(let inner) = phase { inner } else { nil }
        }
        #expect(restoring.count == 2)
        #expect(restoring.contains { if case .checking = $0 { true } else { false } })
        #expect(restoring.contains { if case .replacing = $0 { true } else { false } })

        // Read from the outer phase, which is what the window shows: the wording has to come
        // from RepairPhase rather than being restated here.
        let labels = log.all.map(\.label)
        #expect(labels.contains(RepairPhase.checking.label))
        #expect(labels.contains(RepairPhase.replacing.label))
    }

    @Test("Uninstall removes templates of installed builds but keeps unrelated library data")
    func removesLibraryTemplates() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = SteamLibrary(root: layout.root.appending(path: "library"))
        let build = "26.3.0.39832"
        let templates = SupportPaths.prefixTemplates(forBuild: build, in: library)
        for template in templates {
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: build, runners: layout.support.appending(path: "runners")),
            withIntermediateDirectories: true)
        let unrelated = templates[0].deletingLastPathComponent().appending(path: "notes")
        try Data("keep".utf8).write(to: unrelated)

        _ = try await Uninstall.run(
            app: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
            directories: [layout.support, layout.caches], libraries: [library],
            repair: { _ in }, stop: { _ in false })

        for template in templates { #expect(!FileManager.default.fileExists(atPath: template.path)) }
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: library.compatdata.appending(path: ".notproton-template.lock").path))
    }

    @Test("Uninstall reports template cleanup refusal rather than claiming completion")
    func reportsTemplateCleanupFailure() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = SteamLibrary(root: layout.root.appending(path: "library"))
        try FileManager.default.createDirectory(at: library.compatdata, withIntermediateDirectories: true)
        let outside = layout.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appending(path: "crossover-26.3.0.39832-x86_64-unix")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: library.compatdata.appending(path: SupportPaths.prefixTemplateFolder), withDestinationURL: outside)

        await #expect(throws: StepFailure.self) {
            _ = try await Uninstall.run(
                app: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
                legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
                directories: [layout.support, layout.caches], libraries: [library],
                repair: { _ in }, stop: { _ in false })
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    }
}
