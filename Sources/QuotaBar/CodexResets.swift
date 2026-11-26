import Foundation

/// Redeems a Codex rate-limit reset credit with the same request the Codex CLI sends
/// (codex-rs/backend-client: POST /wham/rate-limit-reset-credits/consume).
enum CodexResets {
    private struct Auth: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    private struct Response: Decodable {
        let code: String?
    }

    /// Called only after the user confirms; sends a single POST and never retries.
    static func redeem(creditID: String) async -> ResetOutcome {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens,
              let token = tokens.access_token,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
        else { return .declined("Sign into the Codex CLI with ChatGPT, then try again.") }

        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens.account_id {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "redeem_request_id": UUID().uuidString.lowercased(),
            "credit_id": creditID
        ])

        guard let (body, response) = try? await URLSession.shared.data(for: request) else {
            return .declined("Couldn’t reach ChatGPT. Refresh to check whether the reset was used.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            return .declined("Codex’s sign-in has expired. Open Codex, then try again.")
        }
        guard status == 200, let code = (try? JSONDecoder().decode(Response.self, from: body))?.code else {
            return .declined("ChatGPT didn’t accept the request (\(status)). Refresh to check your resets.")
        }
        switch code {
        case "reset": return .reset
        case "nothing_to_reset": return .declined("Your Codex usage doesn’t need a reset right now. Nothing was used.")
        case "no_credit": return .declined("No Codex reset is available anymore.")
        case "already_redeemed": return .declined("That reset was already used.")
        default: return .declined("Codex didn’t use the reset (\(code)).")
        }
    }
}
