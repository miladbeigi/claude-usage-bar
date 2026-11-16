import Foundation

/// Keeps Claude Code's login alive without touching the token ourselves.
///
/// When the access token is about to expire, it runs one tiny headless `claude -p` request. Claude Code
/// refreshes its own token before sending it (rotating the refresh token) and saves it to the Keychain,
/// exactly as during normal use. The app then re-reads the new token. Each run costs a few thousand
/// Haiku tokens of quota, roughly once per token lifetime (about every 8 hours).
enum LoginKeeper {
    /// Claude Code refreshes a token within 5 minutes of expiry; ask from a little inside that window.
    static let refreshWindow: TimeInterval = 4 * 60
    static let timeout: TimeInterval = 90

    /// No tools, MCP servers, user settings (hooks, plugins), slash commands or saved session.
    static let arguments = [
        "-p", "Reply with just OK.",
        "--model", "haiku",
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "project,local",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "text",
    ]

    static func needsRefresh(_ credentials: Credentials, now: Date = Date()) -> Bool {
        guard let expiresAt = credentials.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < refreshWindow
    }

    /// Runs the request off the main thread and throws if it fails.
    static func run() async throws {
        try await Task.detached(priority: .utility) { try runBlocking() }.value
    }

    private static func runBlocking() throws {
        guard let claude = findClaude() else { throw UsageError.claudeNotFound }

        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        // An empty folder, so no project CLAUDE.md or settings are picked up.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = nil // make sure the Claude account login is what gets used
        // GUI apps get a bare PATH; npm installs of claude also need node.
        let extra = [claude.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            throw UsageError.loginRefreshFailed(detail?.isEmpty == false ? detail! :
                process.terminationReason == .uncaughtSignal ? "timed out" : "exit \(process.terminationStatus)")
        }
    }

    /// Where the Claude Code installers put `claude`, then whatever the login shell finds.
    static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        guard let path = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
