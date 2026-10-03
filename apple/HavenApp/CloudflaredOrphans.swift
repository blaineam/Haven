import Foundation

/// Which running `cloudflared` processes are THIS Haven install's own — the pure half of the
/// orphan sweep in `CloudflaredTunnel`, split out so the matching rule is covered by
/// HavenLogicTests (Foundation only, no process spawning).
///
/// Why it exists: quitting the Mac app (2026-10-03, rc.3 build 629) left
/// `/Applications/Haven.app/Contents/Helpers/cloudflared --logfile …` running after the app
/// exited — nothing tore the tunnel down on termination, and the old scan matched ANY
/// `…/Contents/Helpers/cloudflared` (another app's bundled helper too) plus any cloudflared
/// pointed at 127.0.0.1:8674/8675/3340 (a user's own homebrew tunnel). The rule is now strict:
/// a process is ours only when it runs OUR helper binary AND logs into OUR logs directory —
/// every Haven spawn passes `--logfile <logs>/cloudflared-*.log`.
enum CloudflaredOrphans {
    struct Row: Equatable {
        let pid: Int32
        let command: String
    }

    /// Parse `ps -ax -ww -o pid= -o command=` output into rows. Malformed lines are skipped.
    static func parsePS(_ text: String) -> [Row] {
        var rows: [Row] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<space]), pid > 1 else { continue }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            rows.append(Row(pid: pid, command: command))
        }
        return rows
    }

    /// True when `command` (a full argv line from ps) is a cloudflared this install spawned:
    /// argv[0] is exactly `binaryPath` (Process passes the executable URL's path verbatim) and a
    /// `--logfile` argument points into `logsDir`. Paths may contain spaces ("Application
    /// Support"), so this matches on prefixes/substrings rather than splitting argv.
    static func isOwned(command: String, binaryPath: String, logsDir: String) -> Bool {
        guard !binaryPath.isEmpty, !logsDir.isEmpty else { return false }
        guard command == binaryPath || command.hasPrefix(binaryPath + " ") else { return false }
        let dir = logsDir.hasSuffix("/") ? logsDir : logsDir + "/"
        let args = command.dropFirst(binaryPath.count)
        return args.contains(" --logfile " + dir + "cloudflared-")
            || args.contains(" --logfile=" + dir + "cloudflared-")
    }

    /// The PIDs to sweep.
    ///
    /// - `psOutput`: the process listing, or nil when `ps` could not run (sandbox, spawn failure).
    ///   Then fall back to `saved` (PIDs persisted at spawn), but only those `executablePath` says
    ///   still run our binary — a saved PID can be reused by an unrelated process after a reboot.
    /// - `except`: live connectors to keep (and our own PID is never a target).
    static func sweepTargets(
        psOutput: String?,
        saved: [Int32],
        binaryPath: String,
        logsDir: String,
        except: Set<Int32>,
        selfPid: Int32,
        executablePath: (Int32) -> String?
    ) -> Set<Int32> {
        var out = Set<Int32>()
        if let psOutput {
            for row in parsePS(psOutput)
            where isOwned(command: row.command, binaryPath: binaryPath, logsDir: logsDir) {
                out.insert(row.pid)
            }
        } else {
            for pid in saved where pid > 1 && executablePath(pid) == binaryPath {
                out.insert(pid)
            }
        }
        out.subtract(except)
        out.remove(selfPid)
        return out
    }
}
