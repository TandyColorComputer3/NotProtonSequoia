import Foundation
import Testing

@testable import NotProtonApp

@Suite("Mach-O build identity")
struct MachOBuildTests {

    private func dylib(_ body: String, in work: URL, named name: String) throws -> URL {
        let source = work.appending(path: "\(name).c")
        try Data(body.utf8).write(to: source)
        let built = work.appending(path: "\(name).dylib")
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib", "-o", built.path(percentEncoded: false),
            source.path(percentEncoded: false),
        ])
        return built
    }

    @Test("Signing a binary does not change which build it is")
    func signingPreservesIdentity() throws {
        let work = try scratchDirectory("macho")
        defer { try? FileManager.default.removeItem(at: work) }

        let built = try dylib("int np_probe(void) { return 1; }\n", in: work, named: "probe")
        let before = try #require(MachOBuild.identity(of: built))

        let copy = work.appending(path: "copy.dylib")
        try FileManager.default.copyItem(at: built, to: copy)
        try SteamInstaller.adHocSign(copy)

        #expect(try Data(contentsOf: copy) != Data(contentsOf: built))
        #expect(MachOBuild.identity(of: copy) == before)
    }

    @Test("Two different builds are told apart")
    func differentBuildsDiffer() throws {
        let work = try scratchDirectory("macho")
        defer { try? FileManager.default.removeItem(at: work) }

        let one = try dylib("int np_probe(void) { return 1; }\n", in: work, named: "one")
        let two = try dylib("int np_probe(void) { return 2; }\n", in: work, named: "two")

        #expect(MachOBuild.identity(of: one) != MachOBuild.identity(of: two))
    }

    @Test("A universal binary is identified by every slice it carries")
    func universalBinaryReportsBothSlices() throws {
        let work = try scratchDirectory("macho")
        defer { try? FileManager.default.removeItem(at: work) }

        let source = work.appending(path: "fat.c")
        try Data("int np_probe(void) { return 1; }\n".utf8).write(to: source)
        let built = work.appending(path: "fat.dylib")
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib", "-arch", "arm64", "-arch", "x86_64",
            "-o", built.path(percentEncoded: false), source.path(percentEncoded: false),
        ])

        let identity = try #require(MachOBuild.identity(of: built))
        #expect(identity.count == 2)
        #expect(identity == identity.sorted())

        let thin = work.appending(path: "thin.dylib")
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib", "-arch", "arm64",
            "-o", thin.path(percentEncoded: false), source.path(percentEncoded: false),
        ])
        #expect(MachOBuild.identity(of: thin) != identity)
    }

    @Test("Something that is not a binary has no build identity")
    func rubbishHasNoIdentity() throws {
        let work = try scratchDirectory("macho")
        defer { try? FileManager.default.removeItem(at: work) }

        let text = work.appending(path: "notes.txt")
        try Data("not a binary".utf8).write(to: text)

        #expect(MachOBuild.identity(of: text) == nil)
        #expect(MachOBuild.identity(of: work.appending(path: "absent.dylib")) == nil)
    }
}
