import Foundation

#if DEBUG && HAVEN_QA_STUB
/// QA stub only: say HOW the process ended. HavenStub died mid-e2e with no crash report and
/// RunningBoard exit context "unknown" (2026-10-06/07) — a clean quit, an `exit()`, or a signal look
/// identical from outside. This prints the path and a call stack to stdout (the e2e run dir's
/// stub-stdout.log) for every way out it can see. Never compiled into shipping builds.
enum QaExitTrace {
    static func install() {
        atexit {
            QaExitTrace.note("atexit: process exiting")
        }
        // SIGPIPE is deliberately absent: the app ignores it (HavenApp.init) and must keep doing so.
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT] {
            signal(sig) { s in
                // Async-signal-safe: a fixed message straight to stdout, then the default action.
                let msg = "[QaExitTrace] signal \(s) received\n"
                _ = msg.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        note("installed (pid \(getpid()))")
    }

    static func note(_ what: String) {
        var out = "[QaExitTrace] \(what)\n"
        for line in Thread.callStackSymbols.prefix(24) { out += "[QaExitTrace]   \(line)\n" }
        FileHandle.standardOutput.write(out.data(using: .utf8) ?? Data())
    }
}
#endif
