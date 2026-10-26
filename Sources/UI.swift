// TokenMeter UI: menu bar icon, panel, and app lifecycle.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Colors and formatting

enum Meter {
    /// Green at 0%, yellow around 50%, orange near 80%, red at 100%.
    /// Muted, dark-tinted tones (sage → ochre → brick) rather than neon.
    /// `lift` brightens the same tone slightly for the menu bar, where it sits on a tinted background.
    static func nsColor(_ percent: Double, lift: CGFloat = 0) -> NSColor {
        let p = min(max(percent / 100, 0), 1)
        let hue = 120.0 * pow(1 - p, 0.8) / 360.0
        return NSColor(hue: hue, saturation: 0.5, brightness: 0.56 + lift, alpha: 1)
    }

    static func color(_ percent: Double) -> Color { Color(nsColor: nsColor(percent)) }

    /// The same tone for text: lighter in dark mode so numbers stay readable on a dark panel.
    static func label(_ percent: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(percent, lift: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.24 : -0.04)
        })
    }

    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 24 * 3600

    /// The API's reset time drifts by sub-seconds between calls; snap to the nearest minute.
    static func snapped(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, snapped(date).timeIntervalSince(now))
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// Coarse "Updated …" wording; the popover only re-renders every 30s anyway.
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 1440 { return "\(minutes / 60) hr ago" }
        return "\(minutes / 1440) d ago"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
    private static let timeFormatter = formatter("h:mm a")
    private static let dayTimeFormatter = formatter("EEE h:mm a")

    static func clock(_ date: Date, now: Date) -> String {
        let date = snapped(date)
        let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
        return (sameDay ? timeFormatter : dayTimeFormatter).string(from: date)
    }

    /// Fraction of the window already elapsed, used for the "Burning fast" hint.
    static func elapsed(_ window: UsageWindow, length: TimeInterval, now: Date) -> Double? {
        guard let resets = window.resetsAt else { return nil }
        let remaining = snapped(resets).timeIntervalSince(now)
        return min(max(1 - remaining / length, 0), 1)
    }
}

/// One plain-language status for the whole panel, driven by whichever limit is closer.
/// Phrased as a fuel gauge: the tank is your remaining quota.
struct Status {
    let title: String
    let detail: String?
    let color: Color

    init(_ snapshot: UsageSnapshot, now: Date) {
        let sessionIsTighter = snapshot.session.percent >= snapshot.weekly.percent
        let window = sessionIsTighter ? snapshot.session : snapshot.weekly
        let left = "\(max(100 - window.rounded, 0))% left this \(sessionIsTighter ? "session" : "week")"
        let refill = window.resetsAt.map { date -> String in
            let sameDay = Calendar.current.isDate(Meter.snapped(date), inSameDayAs: now)
            return "Refills \(sameDay ? "at " : "")\(Meter.clock(date, now: now))"
        }
        color = Meter.color(window.percent)

        switch window.percent {
        case ..<50:
            title = "Plenty in the tank"
            detail = nil
        case ..<80:
            title = "Past the halfway mark"
            detail = left
        case ..<95:
            title = "Tank's getting low"
            detail = left
        case ..<100:
            title = "Running on fumes"
            detail = refill ?? left
        default:
            title = "Tank's empty"
            detail = refill ?? "Refills when the window resets"
        }
    }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var showPercent: Bool = UserDefaults.standard.object(forKey: "showPercent") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showPercent, forKey: "showPercent")
            onChange?()
        }
    }
    /// "system", "light" or "dark"; applies to the popover.
    @Published var theme: String = UserDefaults.standard.string(forKey: "theme") ?? "system" {
        didSet {
            UserDefaults.standard.set(theme, forKey: "theme")
            onChange?()
        }
    }
    @Published var accountEmail: String?
    var onChange: (() -> Void)?

    // The usage endpoint allows only a handful of calls before 429s that can last an hour,
    // and its `retry-after: 0` is meaningless, so calls are rare and backoff is generous.
    private static let staleAfter: TimeInterval = 15 * 60
    private static let cacheKey = "lastSnapshot"
    private var nextAPICall = Date.distantPast
    private var backoff: TimeInterval = 0

    init() {
        // Show the last known numbers instantly on launch instead of a blank panel.
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        Task { accountEmail = await Credentials.accountEmail() }
    }

    /// Re-reads the status line file (free). Calls the API only when that data is over
    /// 15 minutes old, no call is in flight, and no backoff is pending.
    func refresh() {
        if let fromHook = StatusLineFile.read(), fromHook.fetchedAt > (snapshot?.fetchedAt ?? .distantPast) {
            apply(fromHook)
        }

        let now = Date()
        let isFresh = snapshot.map { now.timeIntervalSince($0.fetchedAt) < Self.staleAfter } ?? false
        guard !isFresh, !isLoading, now >= nextAPICall else { return }

        isLoading = true
        Task {
            do {
                apply(try await UsageAPI.fetch())
                backoff = 0
                nextAPICall = Date().addingTimeInterval(Self.staleAfter)
            } catch UsageError.rateLimited {
                backoff = min(max(backoff * 2, 15 * 60), 60 * 60) // 15 → 30 → 60 min
                nextAPICall = Date().addingTimeInterval(backoff)
                errorMessage = "Usage service busy · next check at \(Meter.clock(nextAPICall, now: Date()))"
            } catch {
                nextAPICall = Date().addingTimeInterval(5 * 60)
                errorMessage = error.localizedDescription
            }
            isLoading = false
            onChange?()
        }
    }

    /// True while waiting out an error, when a manual refresh can't reach the API anyway.
    func isBackingOff(at now: Date) -> Bool { errorMessage != nil && now < nextAPICall }

    private func apply(_ next: UsageSnapshot) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { snapshot = next }
        UserDefaults.standard.set(try? JSONEncoder().encode(next), forKey: Self.cacheKey)
        errorMessage = nil
        onChange?()
    }
}

// MARK: - Panel components

extension View {
    /// Rolling-digit animation where available (macOS 14+).
    @ViewBuilder func numericTransition() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.numericText()) } else { self }
    }
}

struct MeterBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = percent > 0 ? max(width * min(percent, 100) / 100, 6) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Meter.color(0), Meter.color(percent)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill)
            }
        }
        .frame(height: 6)
    }
}

struct LimitCard: View {
    let title: String
    let window: UsageWindow
    let length: TimeInterval
    let now: Date

    private var pace: Double? { Meter.elapsed(window, length: length, now: now) }
    private var isAheadOfPace: Bool {
        guard let pace else { return false }
        return window.percent / 100 > pace + 0.1 && (20..<100).contains(window.percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(window.rounded)")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .numericTransition()
                    Text("%").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Meter.label(window.percent))
            }

            MeterBar(percent: window.percent)

            HStack(spacing: 4) {
                if let resets = window.resetsAt {
                    Text("Resets in \(Meter.countdown(to: resets, now: now))")
                        + Text("  ·  ").foregroundColor(.secondary.opacity(0.6))
                        + Text(Meter.clock(resets, now: now))
                } else {
                    Text(window.rounded == 0 ? "Fresh tank · starts with your next message" : "Refill time not known yet")
                }
                Spacer(minLength: 4)
                if isAheadOfPace {
                    Text("Burning fast")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Meter.label(window.percent))
                        .fixedSize()
                }
            }
            .lineLimit(1)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct ErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: retry).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

struct RefreshButton: View {
    let isLoading: Bool
    let action: () -> Void
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(angle))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Refresh now")
        .onChange(of: isLoading) { loading in
            guard loading else { return }
            withAnimation(.easeInOut(duration: 0.8)) { angle += 360 }
        }
    }
}

// MARK: - Panel

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private static let placeholder = UsageSnapshot(
        session: UsageWindow(percent: 40, resetsAt: Date().addingTimeInterval(7200)),
        weekly: UsageWindow(percent: 40, resetsAt: Date().addingTimeInterval(86400)),
        fetchedAt: Date())

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                header(now: context.date)

                if let message = store.errorMessage, store.snapshot == nil {
                    ErrorCard(message: message, retry: store.refresh)
                        .disabled(store.isBackingOff(at: context.date))
                } else {
                    let snapshot = store.snapshot?.current(at: context.date) ?? Self.placeholder
                    VStack(spacing: 8) {
                        LimitCard(title: "Session · 5h",
                                  window: snapshot.session, length: Meter.sessionLength, now: context.date)
                        LimitCard(title: "Weekly",
                                  window: snapshot.weekly, length: Meter.weekLength, now: context.date)
                    }
                    .redacted(reason: store.snapshot == nil ? .placeholder : [])

                    if let message = store.errorMessage {
                        // Cached numbers are still on screen, so keep this quiet.
                        Label(message, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                footer(now: context.date)
            }
            .padding(16)
            .frame(width: 300)
        }
        // The user can change login items in System Settings while the app runs.
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    @ViewBuilder private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            let status = store.snapshot.map { Status($0.current(at: now), now: now) }
            Circle().fill(status?.color ?? .secondary).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.title ?? "Claude usage").font(.system(size: 14, weight: .semibold))
                if let detail = status.map({ $0.detail })
                    ?? (store.errorMessage == nil ? "Reading the gauge…" : "Can't read the gauge right now") {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            RefreshButton(isLoading: store.isLoading, action: store.refresh)
                .disabled(store.isBackingOff(at: now))
        }
    }

    private func footer(now: Date) -> some View {
        HStack {
            if let fetched = store.snapshot?.fetchedAt {
                Text("Updated \(Meter.ago(fetched, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Menu {
                if let email = store.accountEmail {
                    Text(email)
                    Divider()
                }
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                Toggle("Show % in menu bar", isOn: $store.showPercent)
                Picker("Appearance", selection: $store.theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Divider()
                Button("Quit TokenMeter") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Settings")
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        // macOS may want the user to approve the login item; take them there instead of failing silently.
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Menu bar icon

enum MenuBarIcon {
    /// Concentric rings: inner = session, outer = week. Tracks only when there's no data.
    static func image(session: Double?, weekly: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            for (percent, radius) in [(weekly, 7.6), (session, 4.0)] as [(Double?, CGFloat)] {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 2.4
                NSColor.labelColor.withAlphaComponent(0.2).setStroke()
                track.stroke()
                guard let percent, percent > 0 else { continue }
                // Clockwise from 12 o'clock; a small floor keeps low usage visible as a dot.
                let sweep = 360 * max(min(percent, 100) / 100, 0.1)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = 2.4
                arc.lineCapStyle = .round
                Meter.nsColor(percent, lift: 0.1).setStroke()
                arc.stroke()
            }
            return true
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeft

        let hosting = NSHostingController(rootView: UsageView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        store.onChange = { [weak self] in self?.updateButton() }
        updateButton()
        store.refresh()

        // Cheap: mostly a local file read. The store decides when the network is worth it.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.store.refresh()
                self?.updateButton() // so a window that just reset drops to 0 without new data
            }
        }
        timer?.tolerance = 5
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Wi-Fi usually isn't back the instant the Mac wakes, so give it a few seconds.
    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.store.refresh() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        popover.appearance = store.theme == "light" ? NSAppearance(named: .aqua)
            : store.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        let snapshot = store.snapshot?.current(at: Date())
        button.image = MenuBarIcon.image(session: snapshot?.session.percent, weekly: snapshot?.weekly.percent)

        var title = ""
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ]
        if store.showPercent {
            if let session = snapshot?.session {
                title = " \(session.rounded)%"
                attributes[.foregroundColor] = Meter.nsColor(session.percent, lift: 0.1)
            } else {
                title = " –"
            }
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.toolTip = snapshot.map {
            "Claude · Session \($0.session.rounded)% · Week \($0.weekly.rounded)%"
        } ?? store.errorMessage
    }
}
