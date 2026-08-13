import Foundation
import Compression

/// Random-access reader for a ZIP archive. The counterpart to `FileArchive`'s writer, and pure
/// Foundation + Compression for the same reason — no third-party zip crate.
///
/// Built for the archive IMPORTERS (Instagram et al), where the file is far too big to hold: a real
/// Instagram export is 1.28 GB across ~1400 entries. So nothing here reads the whole archive. The
/// central directory is parsed once to learn where every entry lives, and each entry is then read
/// by seeking to its own offset and inflating only its bytes. Peak memory is one entry, not one
/// archive.
///
/// Handles both storage methods a real export uses: JSON arrives DEFLATE-compressed, while the
/// photos and videos are already-compressed formats the zipper leaves STORE'd.
struct ZipReader {

    struct Entry {
        let name: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let method: UInt16          // 0 = STORE, 8 = DEFLATE
        let crc32: UInt32
        let localHeaderOffset: UInt64
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Refuse to inflate a single entry larger than this into memory. Media in a photo export is
    /// megabytes, not gigabytes; anything past this is a zip bomb or the wrong file.
    static let maxEntryBytes: UInt64 = 512 * 1024 * 1024

    let url: URL
    private(set) var entries: [Entry] = []
    private let handle: FileHandle

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        self.url = url
        self.handle = h
        guard let eocd = Self.findEOCD(h) else { try? h.close(); return nil }
        guard let parsed = Self.readCentralDirectory(h, at: eocd.offset, count: eocd.count) else {
            try? h.close(); return nil
        }
        self.entries = parsed
    }

    func close() { try? handle.close() }

    /// First entry whose name matches exactly.
    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Inflate one entry into memory. Returns nil if the entry is absent, oversized, or corrupt.
    ///
    /// The CRC is verified against the stored value — a truncated download of a multi-gigabyte
    /// export is a real failure mode, and silently importing half a photo is worse than refusing it.
    func data(for entry: Entry) -> Data? {
        guard !entry.isDirectory, entry.uncompressedSize <= Self.maxEntryBytes else { return nil }
        // The local header repeats the name/extra lengths, and they are NOT always the same as the
        // central directory's (zippers routinely write different extra fields in each). The payload
        // offset can only be computed from the LOCAL header, or the read lands mid-file.
        guard let head = read(at: entry.localHeaderOffset, count: 30), head.count == 30,
              u32(head, 0) == 0x04034b50 else { return nil }
        let nameLen = UInt64(u16(head, 26))
        let extraLen = UInt64(u16(head, 28))
        let start = entry.localHeaderOffset + 30 + nameLen + extraLen
        guard let raw = read(at: start, count: Int(entry.compressedSize)) else { return nil }

        let out: Data?
        switch entry.method {
        case 0:  out = raw
        case 8:  out = Self.inflate(raw, expected: Int(entry.uncompressedSize))
        default: out = nil          // we never write anything else, and nothing else appears in practice
        }
        guard let result = out, UInt64(result.count) == entry.uncompressedSize else { return nil }
        guard FileArchive.crc32(result) == entry.crc32 else { return nil }
        return result
    }

    func data(named name: String) -> Data? { entry(named: name).flatMap { data(for: $0) } }

    /// Write one entry straight to `dst`. Same work as `data(for:)` but the caller keeps no copy,
    /// which is what an import wants when it is staging a thousand files in a row.
    @discardableResult
    func extract(_ entry: Entry, to dst: URL) -> Bool {
        guard let bytes = data(for: entry) else { return false }
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: dst, options: .atomic)
            return true
        } catch { return false }
    }

    // MARK: - Reading

    private func read(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch { return nil }
    }

    // MARK: - Central directory

    /// Find the end-of-central-directory record. It sits at the very end unless the archive carries
    /// a trailing comment, so scan back over the largest comment ZIP allows (64 KB).
    private static func findEOCD(_ h: FileHandle) -> (offset: UInt64, count: Int)? {
        guard let total = try? h.seekToEnd(), total >= 22 else { return nil }
        let window = UInt64(min(total, 64 * 1024 + 22))
        let from = total - window
        guard (try? h.seek(toOffset: from)) != nil,
              let tail = try? h.read(upToCount: Int(window)), tail.count >= 22 else { return nil }

        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x06054b50 {
                var count = Int(u16(tail, i + 10))
                var offset = UInt64(u32(tail, i + 16))
                // ZIP64: the 32-bit fields saturate and the real values live in a ZIP64 record that
                // the locator (20 bytes ahead of this one) points at.
                if offset == 0xFFFF_FFFF || count == 0xFFFF {
                    if let z = zip64(h, locatorGuess: from + UInt64(i)) { offset = z.offset; count = z.count }
                }
                return (offset, count)
            }
            i -= 1
        }
        return nil
    }

    private static func zip64(_ h: FileHandle, locatorGuess eocdAt: UInt64) -> (offset: UInt64, count: Int)? {
        guard eocdAt >= 20,
              (try? h.seek(toOffset: eocdAt - 20)) != nil,
              let loc = try? h.read(upToCount: 20), loc.count == 20,
              u32(loc, 0) == 0x07064b50 else { return nil }
        let z64At = u64(loc, 8)
        guard (try? h.seek(toOffset: z64At)) != nil,
              let rec = try? h.read(upToCount: 56), rec.count == 56,
              u32(rec, 0) == 0x06064b50 else { return nil }
        return (u64(rec, 48), Int(u64(rec, 32)))
    }

    private static func readCentralDirectory(_ h: FileHandle, at offset: UInt64, count: Int) -> [Entry]? {
        guard (try? h.seek(toOffset: offset)) != nil, let cd = try? h.readToEnd() else { return nil }
        var out: [Entry] = []
        out.reserveCapacity(max(0, count))
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x02014b50 {
            let nameLen = Int(u16(cd, p + 28))
            let extraLen = Int(u16(cd, p + 30))
            let commentLen = Int(u16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            var comp = UInt64(u32(cd, p + 20))
            var uncomp = UInt64(u32(cd, p + 24))
            var local = UInt64(u32(cd, p + 42))
            // ZIP64 extra field (0x0001): whichever of the three saturated is stored here, in order.
            if comp == 0xFFFF_FFFF || uncomp == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                var e = p + 46 + nameLen
                let end = e + extraLen
                while e + 4 <= end, e + 4 <= cd.count {
                    let tag = u16(cd, e), size = Int(u16(cd, e + 2))
                    if tag == 0x0001 {
                        var f = e + 4
                        if uncomp == 0xFFFF_FFFF, f + 8 <= cd.count { uncomp = u64(cd, f); f += 8 }
                        if comp == 0xFFFF_FFFF, f + 8 <= cd.count { comp = u64(cd, f); f += 8 }
                        if local == 0xFFFF_FFFF, f + 8 <= cd.count { local = u64(cd, f) }
                        break
                    }
                    e += 4 + size
                }
            }
            out.append(Entry(name: name, compressedSize: comp, uncompressedSize: uncomp,
                             method: u16(cd, p + 10), crc32: u32(cd, p + 16),
                             localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    // MARK: - INFLATE (raw deflate — ZIP stores no zlib wrapper)

    private static func inflate(_ input: Data, expected: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        guard expected > 0 else { return Data() }
        var dst = Data(count: expected)
        let written: Int = input.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let s = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let d = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(d, expected, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { return nil }
        return dst
    }

    // MARK: - Little-endian scalar reads

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        guard i + 2 <= d.count else { return 0 }
        let b = d.startIndex
        return UInt16(d[b + i]) | (UInt16(d[b + i + 1]) << 8)
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        guard i + 4 <= d.count else { return 0 }
        let b = d.startIndex
        return UInt32(d[b + i]) | (UInt32(d[b + i + 1]) << 8)
            | (UInt32(d[b + i + 2]) << 16) | (UInt32(d[b + i + 3]) << 24)
    }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 {
        guard i + 8 <= d.count else { return 0 }
        return UInt64(u32(d, i)) | (UInt64(u32(d, i + 4)) << 32)
    }
    private func u16(_ d: Data, _ i: Int) -> UInt16 { Self.u16(d, i) }
    private func u32(_ d: Data, _ i: Int) -> UInt32 { Self.u32(d, i) }
}
