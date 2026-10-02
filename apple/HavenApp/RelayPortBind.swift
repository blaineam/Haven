import Foundation

/// Where the hosted relay's HTTP interface binds: its well-known port, and it STAYS there across a
/// restart.
///
/// Members hold the relay's URL. A host restart (the health watch's "local front door dead — full
/// host restart", or the user's hosting toggle) used to try `:8674` exactly once and fall back to an
/// ephemeral port on the first refusal — and right after `stop()` the refusal is routine: the old
/// listener is torn down asynchronously (its accept task is aborted, not joined), so it still holds
/// the port for a moment. gate-8 (2026-10-01 21:09): the stub's relay came back on `:57634`, ran
/// there for half an hour, and members had to re-learn it; the next toggle then moved it BACK to
/// `:8674`. Retrying the well-known port briefly, before any fallback, keeps the door where members
/// already know it. A port genuinely held by someone else still falls back — just a few seconds later.
enum RelayPortBind {
    static let preferredPort: UInt16 = 8674
    /// Waits between attempts on the preferred port (≈ 4.5 s in all) before going ephemeral.
    static let retryDelaysMs: [UInt64] = [150, 300, 600, 1200, 2250]

    /// Bind via [serve] (given a `host:port` bind string, returns the bound port). Returns the port
    /// and whether it is the preferred one, or nil if even the ephemeral fallback failed.
    static func bind(
        host: String = "0.0.0.0",
        serve: (String) async throws -> UInt16,
        sleep: (UInt64) async -> Void = { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    ) async -> (port: UInt16, preferred: Bool)? {
        let preferred = "\(host):\(preferredPort)"
        if let p = try? await serve(preferred) { return (p, true) }
        for delay in retryDelaysMs {
            await sleep(delay)
            if let p = try? await serve(preferred) { return (p, true) }
        }
        if let p = try? await serve("\(host):0") { return (p, false) }
        return nil
    }
}
