import Foundation

enum QuotaWake {
    static func send(_ provider: Provider) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                return try sendPrompt(provider)
            } catch {
                return "Couldn’t start the five-hour window."
            }
        }.value
    }

    private struct ClaudeAuth: Decodable {
        let loggedIn: Bool
        let authMethod: String
    }

    private static func sendPrompt(_ provider: Provider) throws -> String? {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let home = files.homeDirectoryForCurrentUser
        let binPaths = [home.appendingPathComponent(".local/bin").path,
                        home.appendingPathComponent(".bun/bin").path,
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let command = provider == .antigravity ? "agy" : provider.rawValue
        guard let executable = binPaths.map({ "\($0)/\(command)" }).first(where: files.isExecutableFile)
        else { return "Install the \(command) CLI to enable warm-up." }

        var environment = [
            "HOME": home.path,
            "PATH": ([directory.path] + binPaths).joined(separator: ":"),
            "BROWSER": directory.appendingPathComponent("open").path,
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true"
        ]
        let browserBlock = directory.appendingPathComponent("open")
        try "#!/bin/sh\nexit 1\n".write(to: browserBlock, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserBlock.path)
        let isolated = directory.appendingPathComponent("antigravity", isDirectory: true)
        let prompt = "1+1? Reply with only the digit."
        let arguments: [String]
        switch provider {
        case .claude:
            let auth = try run(executable, ["auth", "status", "--json"], directory, environment)
            guard auth.success, let status = try? JSONDecoder().decode(ClaudeAuth.self, from: auth.output),
                  status.loggedIn, status.authMethod == "claude.ai" else {
                return "Run claude auth login to enable warm-up."
            }
            arguments = ["-p", "--model", "haiku", "--max-turns", "1", "--no-session-persistence",
                         "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                         "--disable-slash-commands", prompt]
        case .codex:
            let auth = try run(executable, ["login", "status"], directory, environment)
            guard auth.success, String(decoding: auth.output, as: UTF8.self).contains("Logged in using ChatGPT")
            else { return "Sign into the Codex CLI with ChatGPT to enable warm-up." }
            arguments = ["-a", "never", "exec", "--ignore-user-config", "--ephemeral",
                         "--sandbox", "read-only", "--skip-git-repo-check", "--model", "gpt-6-luna",
                         "-c", "model_reasoning_effort=\"low\"", prompt]
        case .antigravity:
            try files.createDirectory(at: isolated, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            environment["GEMINI_CLI_HOME"] = isolated.path
            let models = try run(executable, ["models"], directory, environment)
            let model = "gemini-3.8-flash-low"
            guard models.success, String(decoding: models.output, as: UTF8.self)
                .split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix(model + "\t") })
            else { return "Gemini Flash unavailable for warm-up. Check agy sign-in." }
            let settings = #"{"useG1Credits":"off","toolPermission":"strict","permissions":{"deny":["read_file(*)","write_file(*)","read_url(*)","execute_url(*)","command(*)","mcp(*)"]}}"#
            arguments = ["--sandbox", "--disable-slash-commands", "--settings", settings,
                         "--model", model, "--print-timeout", "30", "-p", prompt]
        }
        let result = try run(executable, arguments, directory, environment)
        return result.success && String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "2" })
            ? nil : "Warm-up couldn’t be confirmed."
    }

    private static func run(_ executable: String, _ arguments: [String], _ directory: URL,
                            _ environment: [String: String]) throws -> (success: Bool, output: Data) {
        let output = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            return (false, Data())
        }
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let killTimeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 42, execute: killTimeout)
        process.waitUntilExit()
        timeout.cancel()
        killTimeout.cancel()
        try handle.seek(toOffset: 0)
        let bytes = try handle.read(upToCount: 64 * 1024) ?? Data()
        return (process.terminationStatus == 0, bytes)
    }
}
