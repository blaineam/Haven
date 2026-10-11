import Foundation

/// A byte field of the core's persisted engine state, as `JSONSerialization` hands it over.
///
/// Since 2.0.1 the core writes every byte field as a standard base64 string (`persist_bytes` in
/// core/haven-ffi). State files written by 2.0.0 and earlier carry the same field as an array of
/// decimal byte values, and those files are still on disk until their next save — so anything in
/// Swift that reads the state JSON directly must accept both forms.
enum PersistedStateBytes {
    static func bytes(_ v: Any) -> [UInt8]? {
        if let s = v as? String { return Data(base64Encoded: s).map(Array.init) }
        if let nums = v as? [NSNumber] { return nums.map(\.uint8Value) }
        return nil
    }

    /// Lowercase hex of the first 32 bytes (a member bundle's identity key), or "" if too short.
    static func keyHex(_ v: Any) -> String {
        guard let b = bytes(v), b.count >= 32 else { return "" }
        return b.prefix(32).map { String(format: "%02x", $0) }.joined()
    }
}
