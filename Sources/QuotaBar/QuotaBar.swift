import SwiftUI
import Combine
import ServiceManagement

@main
enum QuotaBar {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = StatusBarController()
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = QuotaModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var displayedRings: [RingReading]?
    private var coloredIcon: NSImage?
    private var selectedIcon: NSImage?

    private struct RingReading: Equatable {
        let provider: Provider
        let remaining: Int?
        let stale: Bool
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: 66)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageOnly
        popover.delegate = self
        popover.behavior = .transient
        // A status item can be clicked again before AppKit's close animation finishes.
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: QuotaPanel(model: model))
        subscription = model.$reports.sink { [weak self] reports in
            self?.updateIcon(reports)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            model.reloadLoginItemStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        statusItem?.button?.image = selectedIcon
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.image = coloredIcon
    }

    private func updateIcon(_ reports: [Provider: Report]) {
        let readings = Provider.allCases.map { provider in
            let report = reports[provider]
            return RingReading(
                provider: provider,
                remaining: report?.remaining,
                stale: report?.remaining != nil && report?.problem != nil
            )
        }
        guard displayedRings != readings else { return }
        displayedRings = readings

        let renderer = ImageRenderer(content: HStack(spacing: 4) {
            ForEach(readings, id: \.provider) { reading in
                QuotaRing(provider: reading.provider, remaining: reading.remaining, stale: reading.stale)
            }
        })
        renderer.scale = 3
        let image = renderer.nsImage
        image?.size = NSSize(width: 62, height: 18)
        image?.isTemplate = false
        let description = readings.map { reading in
            let value = reading.remaining.map { "\($0)% left" } ?? "unavailable"
            let freshness = reading.stale ? ", last reading" : ""
            return "\(reading.provider.name) \(value)\(freshness)"
        }.joined(separator: " · ")
        image?.accessibilityDescription = description
        coloredIcon = image
        selectedIcon = image?.copy() as? NSImage
        selectedIcon?.isTemplate = true
        statusItem?.button?.image = popover.isShown ? selectedIcon : coloredIcon
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
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
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status
    @Published private(set) var loginItemError: String?
    @Published private(set) var autoWake = UserDefaults.standard.bool(forKey: "autoWake")
    @Published private(set) var wakeMessages: [Provider: String] = [:]
    private var timer: Timer?

    func setAutoWake(_ enabled: Bool) {
        autoWake = enabled
        UserDefaults.standard.set(enabled, forKey: "autoWake")
        if enabled { refresh() }
    }

    var opensAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    func reloadLoginItemStatus() {
        let status = SMAppService.mainApp.status
        if loginItemStatus != status { loginItemStatus = status }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        loginItemError = nil
        defer { reloadLoginItemStatus() }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = enabled
                ? "Couldn’t turn on Open at Login."
                : "Couldn’t turn off Open at Login."
        }
    }

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
                    if autoWake, result.idleSession,
                       let checked = result.updatedAt, Date().timeIntervalSince(checked) < 30 {
                        await wakeIfDue(provider)
                    }
                }
            }
            refreshing = false
        }
    }
    private func wakeIfDue(_ provider: Provider) async {
        let key = "lastWakeAttempt.\(provider.rawValue)"
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           now.timeIntervalSince(last) < 5 * 3_600 { return }

        UserDefaults.standard.set(now, forKey: key)
        wakeMessages[provider] = "Starting five-hour window…"
        if let problem = await QuotaWake.send(provider) {
            wakeMessages[provider] = problem
            return
        }

        let refreshed = await QuotaReader.fetch(provider)
        if refreshed.problem == nil { reports[provider] = refreshed }
        wakeMessages[provider] = refreshed.problem == nil && refreshed.activeSession
            ? "Five-hour window started."
            : "Warm-up sent. Waiting for a confirmed reset time."
    }

}

private struct QuotaPanel: View {
    @ObservedObject var model: QuotaModel

    var body: some View {
        TimelineView(.everyMinute) { context in
            panel(now: max(context.date, .now))
        }
    }

    private func panel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quota Bar").font(.headline)
                    Text(model.refreshing ? "Refreshing quotas…" : "7-day quotas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("r")
                .disabled(model.refreshing)
                .help("Refresh quota readings")
            }

            ForEach(Provider.allCases, id: \.self) { provider in
                Divider()
                providerSection(provider, now: now)
            }

            Divider()
            VStack(alignment: .leading) {
                Toggle("Quota Warm-up", isOn: Binding(
                    get: { model.autoWake },
                    set: { model.setAutoWake($0) }
                ))
                .help("Sends one tiny prompt when a provider reports an idle five-hour window. Uses plan quota.")

                HStack {
                    Toggle("Open at Login", isOn: Binding(
                        get: { model.opensAtLogin },
                        set: { model.setOpensAtLogin($0) }
                    ))
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("q")
                }

                if model.autoWake {
                    Text("Sends one tiny prompt per idle five-hour window using plan quota.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if model.loginItemStatus == .requiresApproval {
                    Button("Approve in System Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
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

    private func timeBar(reset: Date, now: Date) -> some View {
        let daysLeft = min(max(reset.timeIntervalSince(now) / 86_400, 0), 7)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Time left")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<7) { day in
                    let fill = min(max(daysLeft - Double(day), 0), 1)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.15))
                            if fill > 0 {
                                Rectangle()
                                    .fill(.secondary.opacity(0.65))
                                    .frame(width: geometry.size.width * fill)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                    }
                }
            }
            .frame(height: 4)
        }
        .transaction { $0.disablesAnimations = true }
        .accessibilityHidden(true)
    }

    private func providerSection(_ provider: Provider, now: Date) -> some View {
        let report = model.reports[provider]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                QuotaRing(provider: provider, remaining: report?.remaining, stale: report?.problem != nil)
                Text(provider.name).font(.subheadline.weight(.semibold))
            }
            ForEach(report?.lanes ?? [], id: \.title) { lane in
                let remaining = lane.window.remaining
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(lane.title).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(remaining)% quota left").monospacedDigit().fontWeight(.semibold)
                    }
                    .accessibilityElement(children: .combine)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(provider.tint.opacity(0.16))
                            if remaining > 0 {
                                Capsule()
                                    .fill(provider.tint)
                                    .frame(width: geometry.size.width * CGFloat(remaining) / 100)
                            }
                        }
                    }
                    .frame(height: 5)
                    .transaction { $0.animation = nil }
                    .accessibilityHidden(true)
                    if let date = lane.window.reset {
                        timeBar(reset: date, now: now)
                            .padding(.top, 2)
                        let dateLabel = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        Text("Resets \(dateLabel) · \(countdown(to: date, from: now))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let description = lane.window.resetDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            if model.autoWake, let message = model.wakeMessages[provider] {
                Text(message).font(.caption).foregroundStyle(.secondary)
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
