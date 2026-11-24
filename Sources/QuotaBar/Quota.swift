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

enum QuotaPeriod: String, CaseIterable {
    case week = "7d"
    case session = "5h"

    var segmentCount: Int { self == .week ? 7 : 5 }
    var segmentSeconds: Double { self == .week ? 86_400 : 3_600 }
    var unavailable: String {
        self == .week ? "Weekly quota unavailable." : "Five-hour quota unavailable."
    }
}

struct Lane: Sendable {
    let title: String
    let window: Window
}

struct Report: Sendable {
    var lanes: [Lane] = []
    var sessionLane: Lane?
    var problem: String?
    var updatedAt: Date?
    var idleSession = false
    var activeSession = false
    var remaining: Int? { lanes.map(\.window.remaining).min() }

    func lanes(for period: QuotaPeriod) -> [Lane] {
        switch period {
        case .week: lanes
        case .session: sessionLane.map { [$0] } ?? []
        }
    }
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
    let source: String?
}

enum QuotaReader {
    static func decode(_ data: Data, provider: Provider) throws -> Report {
        let decoder = JSONDecoder()
        let payloads = (try? decoder.decode([Payload].self, from: data))
            ?? (try? decoder.decode(Payload.self, from: data)).map { [$0] }
        guard let payload = payloads?.first(where: { $0.provider == provider.rawValue }),
              let usage = payload.usage else {
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
        let session: Window?
        if provider == .antigravity {
            session = usage.extraRateWindows?.first {
                $0.id == "antigravity-quota-summary-gemini-5h"
                    && $0.usageKnown != false
                    && $0.window?.windowMinutes == 300
            }?.window
        } else {
            session = [usage.primary, usage.secondary].compactMap { $0 }
                .first { $0.windowMinutes == 300 }
        }

        // Warm-up still requires a source that can reliably identify an idle session.
        let wakeSession: Window?
        switch (provider, payload.source) {
        case (.claude, "oauth"), (.claude, "claude"), (.codex, "oauth"):
            wakeSession = usage.primary
        case (.antigravity, "cli"):
            wakeSession = session
        default:
            wakeSession = nil
        }
        let idleSession = wakeSession?.windowMinutes == 300
            && wakeSession?.usedPercent == 0
            && wakeSession?.resetsAt == nil
            && wakeSession?.resetDescription?.isEmpty != false
        return Report(
            lanes: lanes,
            sessionLane: session.map { Lane(title: provider == .antigravity ? "Gemini" : "All models", window: $0) },
            updatedAt: lanes.isEmpty && session == nil ? nil : Date(),
            idleSession: idleSession && !lanes.isEmpty && (lanes.first?.window.usedPercent ?? 100) < 100,
            activeSession: wakeSession?.reset.map { $0 > Date() } ?? false
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
                var report = try decode(data, provider: provider)
                if process.terminationStatus != 0 { report.idleSession = false }
                return report
            } catch {
                return Report(problem: "Couldn’t run the quota helper.")
            }
        }.value
    }
}
