import SwiftUI

@MainActor final class UsageTelemetry {
    static let shared = UsageTelemetry()
    private let sessionID = UUID().uuidString
    private var sequence = 0
    private var active = false
    private var base = "diary"
    private var screens: [(UUID, String)] = []
    private var clock = UsageScreenClock()
    private var heartbeat: Task<Void, Never>?
    private var current: String { screens.last?.1 ?? base }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        sequence += 1
        var record = fields
        record["event"] = name
        record["eventID"] = UUID().uuidString
        record["sessionID"] = sessionID
        record["sequence"] = String(sequence)
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["uptime"] = String(ProcessInfo.processInfo.systemUptime)
        record["timezone"] = TimeZone.current.identifier
        record["utcOffsetSeconds"] = String(TimeZone.current.secondsFromGMT())
        record["screen"] = current
        record["active"] = String(active)
        record["schema"] = "usage-v1"
        record["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test"
        UsageJournal.shared.append(record)
    }
    func action(_ id: String) { event("actionInvoked", ["controlID": id]) }
    private func account() {
        if let elapsed = clock.checkpoint(now: ProcessInfo.processInfo.systemUptime) {
            event("screenTime", ["measuredScreen": clock.screen, "seconds": String(elapsed)])
        }
    }
    private func transition(_ change: () -> Void) {
        account()
        let old = current
        change()
        _ = clock.set(screen: current, active: active, now: ProcessInfo.processInfo.systemUptime)
        if old != current { event("screenChanged", ["from": old, "to": current]) }
    }
    func tab(_ name: String) { transition { base = name }; event("tabSelected", ["tab": name]) }
    func open(_ name: String, token: UUID) {
        guard !screens.contains(where: { $0.0 == token }) else { return }
        transition { screens.append((token, name)) }
        event("screenOpened", ["name": name, "visitID": token.uuidString])
    }
    func close(token: UUID) {
        guard let screen = screens.first(where: { $0.0 == token }) else { return }
        event("screenClosed", ["name": screen.1, "visitID": token.uuidString])
        transition { screens.removeAll { $0.0 == token } }
    }
    func phase(_ phase: ScenePhase) {
        account()
        active = phase == .active
        _ = clock.set(screen: current, active: active, now: ProcessInfo.processInfo.systemUptime)
        event("appPhase", ["phase": String(describing: phase)])
        heartbeat?.cancel()
        if active {
            heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    account()
                }
            }
        } else {
            let task = UIApplication.shared.beginBackgroundTask(withName: "usage-flush", expirationHandler: nil)
            Task {
                _ = await UsageJournal.shared.flush()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }
}

struct UsageScreen<Content: View>: View {
    let name: String
    @ViewBuilder let content: () -> Content
    @State private var token = UUID()
    init(_ name: String, @ViewBuilder content: @escaping () -> Content) {
        self.name = name; self.content = content
    }
    var body: some View {
        content()
            .onAppear { UsageTelemetry.shared.open(name, token: token) }
            .onDisappear { UsageTelemetry.shared.close(token: token) }
    }
}

@MainActor func usageAction(_ id: String, _ action: @escaping () -> Void) -> () -> Void {
    { UsageTelemetry.shared.action(id); action() }
}

private struct UsagePresentation: ViewModifier {
    let name: String
    let visible: Bool
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.onChange(of: visible, initial: true) { _, value in
            if value { UsageTelemetry.shared.open(name, token: token) }
            else { UsageTelemetry.shared.close(token: token) }
        }.onDisappear { UsageTelemetry.shared.close(token: token) }
    }
}
extension View {
    func usagePresentation(_ name: String, visible: Bool) -> some View {
        modifier(UsagePresentation(name: name, visible: visible))
    }
    func usageScroll(_ id: String) -> some View {
        onScrollPhaseChange { old, new in
            UsageTelemetry.shared.event("scrollPhase", ["controlID": id,
                "from": String(describing: old), "to": String(describing: new)])
        }
    }
}

struct UsageInputEvents: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                guard let field = notification.object as? UITextField else { return }
                UsageTelemetry.shared.event("fieldEditingBegan", ["fieldID": field.accessibilityIdentifier ?? "nativeTextField", "secure": String(field.isSecureTextEntry)])
            }
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { notification in
                guard let field = notification.object as? UITextField else { return }
                UsageTelemetry.shared.event("fieldEditingEnded", ["fieldID": field.accessibilityIdentifier ?? "nativeTextField", "secure": String(field.isSecureTextEntry)])
            }
            .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { notification in
                guard let field = notification.object as? UITextView else { return }
                UsageTelemetry.shared.event("textEditingBegan", ["fieldID": field.accessibilityIdentifier ?? "nativeTextView"])
            }
            .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { notification in
                guard let field = notification.object as? UITextView else { return }
                UsageTelemetry.shared.event("textEditingEnded", ["fieldID": field.accessibilityIdentifier ?? "nativeTextView"])
            }
    }
}
