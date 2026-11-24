import Foundation

enum Provider: String, CaseIterable, Sendable {
    case claude, codex, antigravity

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "sparkle"
        }
    }
}

struct Window: Decodable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: String?
    let resetDescription: String?

    var remaining: Int { Int((100 - min(max(usedPercent, 0), 100)).rounded()) }

    var reset: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: resetsAt)
    }
}

struct Lane: Sendable {
    let title: String
    let window: Window
}

struct Report: Sendable {
    var lanes: [Lane] = []
    var problem: String?
    var updatedAt: Date?
    var remaining: Int? { lanes.map(\.window.remaining).min() }
}

private struct Payload: Decodable {
    struct Usage: Decodable {
        struct Extra: Decodable {
            let id: String
            let window: Window?
            let usageKnown: Bool?
        }

        let primary: Window?
        let secondary: Window?
        let extraRateWindows: [Extra]?
    }

    let provider: String
    let usage: Usage?
}

enum QuotaReader {
    static func decode(_ data: Data, provider: Provider) throws -> Report {
        let decoder = JSONDecoder()
        let payloads = (try? decoder.decode([Payload].self, from: data))
            ?? (try? decoder.decode(Payload.self, from: data)).map { [$0] }
        guard let usage = payloads?.first(where: { $0.provider == provider.rawValue })?.usage else {
            return Report(problem: "Couldn’t fetch quota. Check sign-in and connection.")
        }
        let lanes: [Lane]
        if provider == .antigravity {
            let gemini = usage.extraRateWindows?.first {
                $0.id == "antigravity-quota-summary-gemini-weekly"
                    && $0.usageKnown != false
                    && $0.window?.windowMinutes == 10_080
            }
            lanes = gemini?.window.map { [Lane(title: "Gemini", window: $0)] } ?? []
        } else {
            let windows = [usage.secondary, usage.primary].compactMap { $0 }
            let weekly = windows.first { $0.windowMinutes == 10_080 }
                ?? (provider == .claude && usage.secondary?.windowMinutes == nil ? usage.secondary : nil)
            lanes = weekly.map { [Lane(title: "All models", window: $0)] } ?? []
        }
        return Report(
            lanes: lanes,
            problem: lanes.isEmpty ? "Weekly quota unavailable." : nil,
            updatedAt: lanes.isEmpty ? nil : Date()
        )
    }

    static func fetch(_ provider: Provider) async -> Report {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let candidates = [
                "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
                "/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"
            ]
            guard let executable = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
                return Report(problem: "Install the CodexBar helper to fetch quota.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["usage", "--provider", provider.rawValue, "--format", "json", "--json-only"]
            var environment = ProcessInfo.processInfo.environment
            let localBin = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin").path
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(localBin):" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            do {
                try process.run()
                let timeout = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 100, execute: timeout)
                defer { timeout.cancel() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return try decode(data, provider: provider)
            } catch {
                return Report(problem: "Couldn’t run the quota helper.")
            }
        }.value
    }
}
