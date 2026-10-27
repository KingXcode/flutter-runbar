#if LIVE_LOG_VALIDATION
import AppKit

/// QA-only main-queue latency probe. Reports a bounded recent window to the
/// isolated fixture HOME; never compiled into the shipped application.
@MainActor
final class LogResponsivenessProbe {
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var last = DispatchTime.now().uptimeNanoseconds
    private var samples: [Double] = []
    private var ticks = 0
    init() {
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = max(0, Double(now - last) / 1_000_000 - 50)
        last = now; ticks += 1; samples.append(delay)
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
        guard ticks % 20 == 0 else { return }
        let sorted = samples.sorted()
        let report: [String: Any] = [
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "showInDock": UserDefaults.standard.bool(forKey: "showInDock"),
            "shortcutInvocations": AppModel.shared.shortcutInvocationCount,
            "shortcutRegistrationError": AppModel.shared.globalShortcutError ?? "",
            "appActive": NSApp.isActive,
            "samples": samples.count, "ticks": ticks,
            "p95DelayMs": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "maxDelayMs": sorted.last ?? 0,
            "meanDelayMs": samples.reduce(0, +) / Double(samples.count)
        ]
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("runbar-ui-latency.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    deinit { timer.cancel() }
}
#endif
