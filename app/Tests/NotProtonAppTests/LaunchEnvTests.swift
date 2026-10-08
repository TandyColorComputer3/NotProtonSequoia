import Foundation
import Testing

@testable import NotProtonApp

@Suite("Launch environment")
struct LaunchEnvTests {

    private static func runScript() throws -> String {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
    }

    private static func line(containing needles: String...) throws -> String {
        let script = try runScript()
        return try #require(
            script.split(separator: "\n")
                .first { line in needles.allSatisfy(line.contains) }
                .map(String.init),
            "compat_run.sh no longer has a line containing \(needles.joined(separator: " and "))")
    }

    @Test("A launch option cannot unhook the steamclient overrides")
    func overridesKeepTheTrioLast() throws {
        let line = try Self.line(
            containing: "export WINEDLLOVERRIDES=", "steamclient=n;steamclient64=n;lsteamclient=b")
        let user = try #require(line.range(of: "${WINEDLLOVERRIDES:+"))
        let trio = try #require(line.range(of: "steamclient=n;steamclient64=n;lsteamclient=b"))
        #expect(
            user.lowerBound < trio.lowerBound,
            "the trio must follow the launch option, because ntdll keeps the last setting")
    }

    @Test("A launch option cannot shadow the runner's own dlls")
    func dllPathKeepsTheRunnerFirst() throws {
        let line = try Self.line(containing: "export WINEDLLPATH=", "x86_64-windows")
        let runner = try #require(line.range(of: "$CX_ROOT/lib/wine/x86_64-windows"))
        let user = try #require(line.range(of: "${WINEDLLPATH:+"))
        #expect(
            runner.lowerBound < user.lowerBound,
            "the runner must precede the launch option, because the loader takes the first match")
    }

    @Test("The prefix and loader are not taken from launch options")
    func ownedVarsAreOverwritten() throws {
        _ = try Self.line(containing: "export WINEPREFIX=", "STEAM_COMPAT_DATA_PATH")

        let script = try Self.runScript()
        for name in ["WINEPREFIX", "WINELOADER", "WINESERVER"] {
            #expect(
                !script.contains("${\(name):-"),
                "\(name) must not fall back to what it inherits, which a launch option now sets")
        }

        let path = try Self.line(containing: "export PATH=")
        let runner = try #require(path.range(of: "$CX_ROOT/bin"))
        let inherited = try #require(path.range(of: ":$PATH"))
        #expect(
            runner.lowerBound < inherited.lowerBound,
            "the runner's tools must precede an inherited PATH, which a launch option now sets")
    }
}
