import Foundation

/// Reads Claude's banked limit resets ("Full reset") from the same usage endpoint Claude Code uses.
/// This is a read-only GET: Quota Bar never redeems a reset itself.
enum ClaudeResets {
    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    private struct Usage: Decodable {
        struct Status: Decodable {
            struct Grant: Decodable {
                let id: String
                let label: String?
                let usable_now: Bool?
                let type: String?
                let resets_left: Int
                let ends_at: String?
                let paused: Bool?
            }
            let eligible: Bool?
            let grants: [Grant]?
            let next_grant_id: String?
        }
        let cedar_ember: Status?
    }

    static func fetch() async -> ResetCredits? {
        let (token, version) = await Task.detached(priority: .utility) {
            (accessToken(), cliVersion())
        }.value
        guard let token, let version,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Resets are only reported to Claude Code surfaces.
        request.setValue("claude-cli/\(version) (external, cli)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(Usage.self, from: data).cedar_ember,
              status.eligible == true else { return nil }

        let grants = (status.grants ?? []).filter { $0.resets_left > 0 && $0.paused != true }
        let count = grants.reduce(0) { $0 + $1.resets_left }
        guard count > 0 else { return nil }
        let expiries = grants.compactMap { grant in
            parseISODate(grant.ends_at).map { (date: $0, grant: grant) }
        }
        let soonest = expiries.min { $0.date < $1.date }
        // Claude only accepts its next grant, so offer exactly that one.
        let next = grants.first { $0.id == status.next_grant_id }
        let first = next ?? soonest?.grant ?? grants.first
        return ResetCredits(
            available: count,
            expiresAt: soonest?.date,
            title: first?.type == "full" ? "Full reset (Weekly + 5 hr)" : first?.label,
            redeemID: next?.id,
            usableNow: next?.usable_now ?? false
        )
    }

    /// Redeems one grant. Called only after the user confirms; sends a single POST and never retries.
    static func redeem(grantID: String) async -> ResetOutcome {
        let (token, version, organization) = await Task.detached(priority: .userInitiated) {
            (accessToken(), cliVersion(), organizationID())
        }.value
        guard let token else { return .declined("Claude Code’s sign-in has expired. Open Claude Code, then try again.") }
        guard let version, let organization,
              let url = URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")
        else { return .declined("Couldn’t find your Claude Code account.") }

        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/\(version) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember",
            "grant_id": grantID,
            "request_id": UUID().uuidString.lowercased()
        ])

        struct Response: Decodable {
            let result: String?
            let reason: String?
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .declined("Couldn’t reach Claude. Refresh to check whether the reset was used.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            return .declined("Claude Code’s sign-in has expired. Open Claude Code, then try again.")
        }
        guard status == 200, let body = try? JSONDecoder().decode(Response.self, from: data) else {
            return .declined("Claude didn’t accept the request (\(status)). Refresh to check your resets.")
        }
        switch body.result {
        case "reset": return .reset
        case "not_limited": return .declined("Your Claude usage doesn’t need a reset right now. Nothing was used.")
        case "already_used": return .declined("That reset was already used.")
        case "cooldown": return .declined("Claude resets are cooling down. Try again later.")
        default:
            return .declined("Claude didn’t use the reset (\(body.reason ?? body.result ?? "unknown")).")
        }
    }

    private static func organizationID() -> String? {
        struct Config: Decodable {
            struct Account: Decodable { let organizationUuid: String? }
            let oauthAccount: Account?
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Config.self, from: data))?.oauthAccount?.organizationUuid
    }

    /// Reads Claude Code's OAuth token through `security`, which Claude Code itself uses,
    /// so no keychain prompt appears. An expired token is skipped rather than refreshed,
    /// to avoid rotating Claude Code's credentials.
    private static func accessToken() -> String? {
        guard let output = run("/usr/bin/security",
                               ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: output) else { return nil }
        let oauth = credentials.claudeAiOauth
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1_000) < Date() {
            return nil
        }
        return oauth.accessToken
    }

    private static func cliVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.bun/bin/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        // Several installs can coexist; the server rejects old CLI versions, so report the newest.
        let versions = candidates.filter(FileManager.default.isExecutableFile).compactMap { executable -> String? in
            guard let output = run(executable, ["--version"]),
                  let version = String(decoding: output, as: UTF8.self)
                      .split(whereSeparator: \.isWhitespace).first.map(String.init),
                  version.first?.isNumber == true else { return nil }
            return version
        }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
