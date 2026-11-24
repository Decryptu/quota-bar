import SwiftUI
import Combine

@main
struct QuotaBar: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBar

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private let model = QuotaModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: 66)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageOnly
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuotaPanel(model: model))
        subscription = model.$reports.sink { [weak self] reports in
            self?.updateIcon(reports)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateIcon(_ reports: [Provider: Report]) {
        let renderer = ImageRenderer(content: HStack(spacing: 4) {
            ForEach(Provider.allCases, id: \.self) { provider in
                let report = reports[provider]
                QuotaRing(provider: provider, remaining: report?.remaining, stale: report?.problem != nil)
            }
        })
        renderer.scale = 3
        let image = renderer.nsImage
        image?.size = NSSize(width: 62, height: 18)
        image?.isTemplate = false
        let description = Provider.allCases.map { provider in
            let report = reports[provider]
            let value = report?.remaining.map { "\($0)% left" } ?? "unavailable"
            let freshness = report?.remaining != nil && report?.problem != nil ? ", last reading" : ""
            return "\(provider.name) \(value)\(freshness)"
        }.joined(separator: " · ")
        image?.accessibilityDescription = description
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = description
    }
}

private struct QuotaRing: View {
    let provider: Provider
    let remaining: Int?
    var stale: Bool = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(provider.tint.opacity(0.3), lineWidth: 1.8)
            if let remaining, remaining > 0 {
                Circle()
                    .inset(by: 0.9)
                    .trim(from: 0, to: Double(remaining) / 100)
                    .stroke(provider.tint.opacity(stale ? 0.55 : 1), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: provider.symbol)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(provider.tint.opacity(remaining == nil ? 0.5 : 1))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private extension Provider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case .codex: Color(red: 79 / 255, green: 133 / 255, blue: 246 / 255)
        case .antigravity: Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)
        }
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
        .frame(width: 344)
    }

    private func countdown(to reset: Date, from now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "reset due" }
        let hours = Int(seconds / 3_600)
        let minutes = Int(seconds / 60)
        if hours >= 24 { return "in \(hours / 24)d and \(hours % 24)h" }
        if hours > 0 { return "in \(hours)h and \(minutes % 60)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }

    private func providerSection(_ provider: Provider) -> some View {
        let report = model.reports[provider]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                QuotaRing(provider: provider, remaining: report?.remaining, stale: report?.problem != nil)
                Text(provider.name).font(.subheadline.weight(.semibold))
            }
            ForEach(report?.lanes ?? [], id: \.title) { lane in
                let remaining = lane.window.remaining
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lane.title).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(remaining)% left").monospacedDigit().fontWeight(.medium)
                    }
                    ProgressView(value: Double(remaining), total: 100)
                        .tint(provider.tint)
                        .accessibilityLabel("\(lane.title) quota remaining")
                    if let date = lane.window.reset {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let dateLabel = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                            Text("Resets \(dateLabel) · \(countdown(to: date, from: context.date))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
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
