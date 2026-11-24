import SwiftUI

@main
struct QuotaBar: App {
    @StateObject private var model = QuotaModel()

    var body: some Scene {
        MenuBarExtra {
            QuotaPanel(model: model)
        } label: {
            Text(model.menuTitle)
                .monospacedDigit()
                .accessibilityLabel(model.accessibleTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class QuotaModel: ObservableObject {
    @Published private(set) var reports: [Provider: Report] = [:]
    @Published private(set) var refreshing = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var menuTitle: String {
        Provider.allCases.map {
            let tag = $0 == .claude ? "Cl" : $0 == .codex ? "Cx" : "Ag"
            return "\(tag) \(percent($0))"
        }.joined(separator: "  ")
    }

    var accessibleTitle: String {
        Provider.allCases.map { "\($0.name) \(percent($0))" }.joined(separator: ", ")
    }

    private func percent(_ provider: Provider) -> String {
        guard let report = reports[provider], let remaining = report.remaining else { return "–" }
        return "\(remaining)%\(report.problem == nil ? "" : "*")"
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await withTaskGroup(of: (Provider, Report).self) { group in
                for provider in Provider.allCases {
                    group.addTask { (provider, await QuotaReader.fetch(provider)) }
                }
                for await (provider, result) in group {
                    var report = result
                    if let previous = reports[provider], result.problem != nil {
                        report.lanes = previous.lanes
                        report.updatedAt = previous.updatedAt
                    }
                    reports[provider] = report
                }
            }
            refreshing = false
        }
    }
}

private struct QuotaPanel: View {
    @ObservedObject var model: QuotaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quota Bar").font(.headline)
                    Text("7-day quota remaining").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.refreshing)
                .help("Refresh quota")
                .accessibilityLabel("Refresh quota")
            }

            ForEach(Provider.allCases, id: \.self) { provider in
                Divider()
                providerSection(provider)
            }

            Divider()
            HStack {
                Text(model.refreshing ? "Refreshing…" : "Refreshes every 5 minutes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func providerSection(_ provider: Provider) -> some View {
        let report = model.reports[provider]
        return VStack(alignment: .leading, spacing: 8) {
            Label(provider.name, systemImage: provider.symbol).font(.subheadline.weight(.semibold))
            ForEach(report?.lanes ?? [], id: \.title) { lane in
                let remaining = lane.window.remaining
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lane.title).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(remaining)% left").monospacedDigit().fontWeight(.medium)
                    }
                    ProgressView(value: Double(remaining), total: 100)
                        .tint(remaining <= 10 ? .red : remaining <= 25 ? .orange : .blue)
                        .accessibilityLabel("\(lane.title) quota remaining")
                    if let date = lane.window.reset {
                        Text("Resets \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let description = lane.window.resetDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            if let problem = report?.problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
                if let date = report?.updatedAt {
                    Text("Last reading \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if report == nil {
                Text("Checking quota…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
