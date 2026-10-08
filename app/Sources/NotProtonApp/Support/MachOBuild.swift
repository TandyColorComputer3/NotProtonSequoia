// Which build is this binary? Signing rewrites the bytes, LC_UUID survives it

import Foundation

enum MachOBuild {
    private static let fat32: UInt32 = 0xcafe_babe
    private static let fat64: UInt32 = 0xcafe_babf
    private static let thin64: UInt32 = 0xfeed_facf
    private static let thin32: UInt32 = 0xfeed_face
    private static let swapped64: UInt32 = 0xcffa_edfe
    private static let swapped32: UInt32 = 0xcefa_edfe
    private static let uuidCommand: UInt32 = 0x1b

    static func identity(of url: URL) -> [String]? {
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var found: Set<String> = []
        collect(bytes, at: 0, into: &found)
        return found.isEmpty ? nil : found.sorted()
    }

    static func matchesIgnoringSignature(_ source: URL, _ destination: URL) throws -> Bool {
        guard let id = identity(of: source), id == identity(of: destination) else { return false }
        guard try Shell.run("/usr/bin/codesign", ["--verify", "--strict", destination.path(percentEncoded: false)]).succeeded else { return false }
        guard let expected = try hashesIgnoringSignature(of: source),
            let actual = try hashesIgnoringSignature(of: destination) else { return false }
        return expected == actual
    }

    static func hashesIgnoringSignature(of file: URL) throws -> [String]? {
        guard identity(of: file) != nil else { return nil }
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appending(path: "np-signature-compare-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let copy = scratch.appending(path: "unsigned")
        try files.copyItem(at: file, to: copy)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path(percentEncoded: false))
        guard try Shell.run("/usr/bin/codesign", ["--remove-signature", copy.path(percentEncoded: false)]).succeeded,
            let slices = unsignedSlices(try Data(contentsOf: copy)) else { return nil }
        return slices.map { Digest.sha256(of: $0) }.sorted()
    }

    static func unsignedSlices(_ bytes: Data) -> [Data]? {
        guard let magic = read(bytes, at: 0, bigEndian: false) else { return nil }
        var ranges = [0..<bytes.count]
        if magic.byteSwapped == fat32 || magic.byteSwapped == fat64 {
            let wide = magic.byteSwapped == fat64
            let stride = wide ? 32 : 20
            guard let count = read(bytes, at: 4, bigEndian: true),
                count > 0, Int(count) <= (bytes.count - 8) / stride else { return nil }
            ranges = []
            for index in 0..<Int(count) {
                let entry = 8 + index * stride
                if wide && (read(bytes, at: entry + 8, bigEndian: true) != 0
                            || read(bytes, at: entry + 16, bigEndian: true) != 0) { return nil }
                guard let offset = read(bytes, at: entry + (wide ? 12 : 8), bigEndian: true),
                    let size = read(bytes, at: entry + (wide ? 20 : 12), bigEndian: true), size > 0,
                    Int(offset) >= 8 + Int(count) * stride,
                    Int(offset) + Int(size) <= bytes.count else { return nil }
                let range = Int(offset)..<(Int(offset) + Int(size))
                guard !ranges.contains(where: { $0.overlaps(range) }) else { return nil }
                let sliceMagic = read(bytes, at: range.lowerBound, bigEndian: false)
                let flipped = sliceMagic == swapped64 || sliceMagic == swapped32
                guard read(bytes, at: entry, bigEndian: true) == read(bytes, at: range.lowerBound + 4, bigEndian: flipped),
                    read(bytes, at: entry + 4, bigEndian: true) == read(bytes, at: range.lowerBound + 8, bigEndian: flipped)
                else { return nil }
                ranges.append(range)
            }
        }
        var result: [Data] = []
        for range in ranges {
            var slice = bytes.subdata(in: range)
            guard let magic = read(slice, at: 0, bigEndian: false),
                [thin64, thin32, swapped64, swapped32].contains(magic),
                let count = read(slice, at: 16, bigEndian: magic == swapped64 || magic == swapped32)
            else { return nil }
            let flipped = magic == swapped64 || magic == swapped32
            var cursor = magic == thin64 || magic == swapped64 ? 32 : 28
            guard let length = read(slice, at: 20, bigEndian: flipped),
                cursor + Int(length) <= slice.count, count <= length / 8 else { return nil }
            let end = cursor + Int(length)
            for _ in 0..<Int(count) {
                guard let command = read(slice, at: cursor, bigEndian: flipped),
                    let size = read(slice, at: cursor + 4, bigEndian: flipped),
                    size >= 8, cursor + Int(size) <= end else { return nil }
                if command == 0x19 || command == 0x1 {
                    guard size >= (command == 0x19 ? 72 : 56) else { return nil }
                    let name = String(decoding: slice[(cursor + 8)..<(cursor + 24)].prefix { $0 != 0 }, as: UTF8.self)
                    if name == "__LINKEDIT" {
                        // Signing can change __LINKEDIT's size, so it is ignored when comparing.
                        let start = cursor + (command == 0x19 ? 32 : 28)
                        let width = command == 0x19 ? 8 : 4
                        slice.replaceSubrange(start..<(start + width), with: repeatElement(UInt8(0), count: width))
                    }
                }
                cursor += Int(size)
            }
            result.append(slice)
        }
        return result
    }

    private static func collect(_ bytes: Data, at offset: Int, into found: inout Set<String>) {
        guard let magic = read(bytes, at: offset, bigEndian: false) else { return }
        let fat = magic.byteSwapped

        if fat == fat32 || fat == fat64 {
            guard let count = read(bytes, at: offset + 4, bigEndian: true) else { return }
            let wide = fat == fat64
            for index in 0..<Int(count) {
                let entry = offset + 8 + index * (wide ? 32 : 20)
                guard let slice = read(bytes, at: entry + (wide ? 12 : 8), bigEndian: true) else {
                    return
                }
                readCommands(bytes, at: Int(slice), into: &found)
            }
            return
        }

        readCommands(bytes, at: offset, into: &found)
    }

    private static func readCommands(_ bytes: Data, at offset: Int, into found: inout Set<String>) {
        guard let magic = read(bytes, at: offset, bigEndian: false) else { return }
        guard [thin64, thin32, swapped64, swapped32].contains(magic) else { return }

        let flipped = magic == swapped64 || magic == swapped32
        let wide = magic == thin64 || magic == swapped64
        guard let count = read(bytes, at: offset + 16, bigEndian: flipped) else { return }

        var cursor = offset + (wide ? 32 : 28)
        for _ in 0..<Int(count) {
            guard let command = read(bytes, at: cursor, bigEndian: flipped),
                let size = read(bytes, at: cursor + 4, bigEndian: flipped), size >= 8
            else { return }

            if command == uuidCommand, let value = readUUID(bytes, at: cursor + 8) {
                found.insert(value)
            }
            cursor += Int(size)
        }
    }

    private static func read(_ bytes: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let value = bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    private static func readUUID(_ bytes: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 16 <= bytes.count else { return nil }
        let raw = bytes.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: uuid_t.self)
        }
        return UUID(uuid: raw).uuidString
    }
}
