import Foundation
import Compression
import CryptoKit

/// Zip one or more files (or a directory tree) into a single archive for sharing as a
/// `file_` media attachment. Pure Foundation + Compression — no third-party zip crate.
///
/// Output is a standard ZIP (local file headers + central directory + end record) using
/// DEFLATE when it actually shrinks a file, and STORE otherwise. Paths inside the archive
/// are relative to the chosen root so a folder attaches as a real tree, not a flat dump.
enum FileArchive {

    /// Hard ceiling so a "share my whole disk" mistake can't freeze the app. 512 MB of
    /// *source* bytes is already more than a circle should move; the zip may be smaller.
    static let maxSourceBytes: UInt64 = 512 * 1024 * 1024

    /// Zip `urls` (files and/or directories) into a temp `.zip`. Returns nil if nothing
    /// readable was found, the total exceeds the cap, or writing failed.
    static func zip(_ urls: [URL], preferredName: String = "attachment") -> URL? {
        var entries: [(name: String, data: Data)] = []
        var total: UInt64 = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let collected = collect(url, rootName: url.lastPathComponent, total: &total) else {
                return nil
            }
            entries.append(contentsOf: collected)
        }
        guard !entries.isEmpty else { return nil }

        let safe = preferredName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "attachment" : safe
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).zip")
        do {
            try writeZip(entries, to: out)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }

    // MARK: - Walk

    private static func collect(_ url: URL, rootName: String, total: inout UInt64)
        -> [(name: String, data: Data)]?
    {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }
        if isDir.boolValue {
            var out: [(name: String, data: Data)] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            for case let fileURL as URL in walker {
                let vals = try? fileURL.resourceValues(forKeys: Set(keys))
                guard vals?.isRegularFile == true else { continue }
                let size = UInt64(vals?.fileSize ?? 0)
                total += size
                if total > maxSourceBytes { return nil }
                guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                    continue
                }
                // Relative path under the folder's display name.
                let rel = fileURL.path.replacingOccurrences(of: url.path, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let name = rootName + (rel.isEmpty ? "" : "/\(rel)")
                out.append((name: name, data: data))
            }
            // Empty folder → still emit a directory marker so the tree shape survives.
            if out.isEmpty {
                out.append((name: rootName.hasSuffix("/") ? rootName : rootName + "/", data: Data()))
            }
            return out
        } else {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            total += size
            if total > maxSourceBytes { return nil }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
            return [(name: rootName, data: data)]
        }
    }

    // MARK: - ZIP writer (STORE / DEFLATE)

    private static func writeZip(_ entries: [(name: String, data: Data)], to url: URL) throws {
        var local: Data = Data()
        var central: Data = Data()
        var offsets: [UInt32] = []

        for e in entries {
            let nameData = Data(e.name.utf8)
            let method: UInt16
            let payload: Data
            let crc = crc32(e.data)
            if let deflated = deflate(e.data), deflated.count < e.data.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = e.data
            }
            offsets.append(UInt32(local.count))

            // Local file header
            local.append(u32(0x04034b50))
            local.append(u16(20))             // version needed
            local.append(u16(0))              // flags
            local.append(u16(method))
            local.append(u16(0))              // mod time
            local.append(u16(0))              // mod date
            local.append(u32(crc))
            local.append(u32(UInt32(payload.count)))
            local.append(u32(UInt32(e.data.count)))
            local.append(u16(UInt16(nameData.count)))
            local.append(u16(0))              // extra len
            local.append(nameData)
            local.append(payload)

            // Central directory header
            central.append(u32(0x02014b50))
            central.append(u16(20))           // version made by
            central.append(u16(20))           // version needed
            central.append(u16(0))
            central.append(u16(method))
            central.append(u16(0))
            central.append(u16(0))
            central.append(u32(crc))
            central.append(u32(UInt32(payload.count)))
            central.append(u32(UInt32(e.data.count)))
            central.append(u16(UInt16(nameData.count)))
            central.append(u16(0))            // extra
            central.append(u16(0))            // comment
            central.append(u16(0))            // disk start
            central.append(u16(0))            // int attrs
            central.append(u32(0))            // ext attrs
            central.append(u32(offsets.last!))
            central.append(nameData)
        }

        let centralOffset = UInt32(local.count)
        var out = local
        out.append(central)
        // End of central directory
        out.append(u32(0x06054b50))
        out.append(u16(0))
        out.append(u16(0))
        out.append(u16(UInt16(entries.count)))
        out.append(u16(UInt16(entries.count)))
        out.append(u32(UInt32(central.count)))
        out.append(u32(centralOffset))
        out.append(u16(0))
        try out.write(to: url, options: .atomic)
    }

    // MARK: - DEFLATE (raw, zlib wrapper stripped — ZIP wants raw deflate)

    private static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let dstSize = input.count + input.count / 10 + 64
        var dst = Data(count: dstSize)
        let written: Int = input.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let s = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let d = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_encode_buffer(d, dstSize, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        // compression_encode_buffer with COMPRESSION_ZLIB writes a zlib wrapper (2-byte CMF/FLG
        // + 4-byte Adler). ZIP DEFLATE wants the raw stream. Strip the wrapper when present.
        guard written > 6 else { return nil }
        // zlib header is 2 bytes; trailer is 4-byte Adler-32.
        return dst.subdata(in: 2..<(written - 4))
    }

    // MARK: - CRC-32 (ISO 3309 / ZIP)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    /// Iterating a `Data` element-by-element goes through its `Collection` conformance — a retain,
    /// a bounds check and a slice-offset add PER BYTE. That is tolerable for the few-MB attachments
    /// this was written for and ruinous for an archive import, which CRCs every entry it reads: on a
    /// 1.24 GB Instagram export that is 1.24 BILLION of those, and it dominated the import.
    ///
    /// Same algorithm, same table — the bytes are just walked through one unsafe pointer instead.
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count {
                c = crcTable[Int((c ^ UInt32(base[i])) & 0xff)] ^ (c >> 8)
            }
        }
        return c ^ 0xffffffff
    }

    // MARK: - LE helpers

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
}

// Silence the unused-import warning when CryptoKit isn't needed by the archive itself —
// kept available for call sites that fingerprint the zip before minting a file_ ref.
extension FileArchive {
    /// sha-256 hex of a file on disk (streamed), used by MediaStore when minting `file_` refs.
    static func sha256Hex(fileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            guard let block = (try? fh.read(upToCount: 1024 * 1024)) ?? nil, !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
