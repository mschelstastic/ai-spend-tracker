import Foundation

/// Nudges Claude Code into refreshing its OAuth token by running `echo ping | claude -p`.
///
/// The Keychain token we read lives about 8 hours, and only Claude Code refreshes it —
/// when it runs. Refreshing it ourselves would race Claude Code's refresh-token rotation
/// (see docs/auto-refresh-investigation.md), so instead we run Claude Code once and let
/// it refresh with its own locking. A one-shot `-p` prompt is the one command known to
/// refresh; it costs a sliver of plan usage, which is why this is opt-in
/// (`Settings.pingClaudeOnAuthError`).
///
/// The reply is ignored: the caller just re-reads the Keychain afterwards.
enum ClaudeCLIPing {
    /// No `claude` executable on this machine.
    struct CLINotFound: Error {}

    /// A model round-trip plus a token refresh; a wedged CLI is killed after this.
    private static let timeout: TimeInterval = 60

    static func ping() async throws {
        try await Task.detached(priority: .userInitiated) { try run() }.value
    }

    private static func run() throws {
        guard let exe = executable() else { throw CLINotFound() }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["-p"]
        // Run outside any project so no CLAUDE.md or project settings load.
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        // The CLI may need the login-shell PATH (e.g. an nvm-installed node).
        var env = ProcessInfo.processInfo.environment
        if let path = LoginShell.path() { env["PATH"] = path }
        proc.environment = env

        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        try proc.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data("ping\n".utf8))
        try stdin.fileHandleForWriting.close()

        if done.wait(timeout: .now() + timeout) == .timedOut { proc.terminate() }
    }

    /// Find the `claude` binary: the login-shell `PATH` first (so it's the same
    /// `claude` the user runs when several are installed), then the usual install
    /// locations. Not cached, so a `claude` installed after launch is picked up.
    private static func executable() -> URL? {
        if let onPath = LoginShell.which("claude") { return onPath }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
