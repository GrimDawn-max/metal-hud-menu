//
//  HUDSettingsManager.swift
//  MetalHUDMenu
//

import Combine
import Foundation
import ServiceManagement

class HUDSettingsManager: ObservableObject {
    static let shared = HUDSettingsManager()

    // MARK: - Persisted HUD settings

    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: "hudEnabled") }
    }

    @Published var selectedElements: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedElements), forKey: "selectedElements") }
    }

    @Published var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: "scale") }
    }

    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }

    @Published var alignment: String {
        didSet { UserDefaults.standard.set(alignment, forKey: "alignment") }
    }

    @Published var enableHUDOnBoot: Bool {
        didSet { UserDefaults.standard.set(enableHUDOnBoot, forKey: "enableHUDOnBoot") }
    }

    /// MTL_HUD_LOG_ENABLED - writes per-frame HUD data to the unified log,
    /// readable with: log stream --predicate 'eventMessage CONTAINS "metal-HUD"'
    @Published var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "logEnabled") }
    }

    /// MTL_HUD_LOG_SHADER_ENABLED - logs shader compilation alongside it.
    @Published var logShaderEnabled: Bool {
        didSet { UserDefaults.standard.set(logShaderEnabled, forKey: "logShaderEnabled") }
    }

    /// MTL_HUD_ENCODER_TIMING_ENABLED - per-encoder GPU timings. Apple warns
    /// this raises the HUD's own CPU cost, so it is off by default.
    @Published var encoderTimingEnabled: Bool {
        didSet { UserDefaults.standard.set(encoderTimingEnabled, forKey: "encoderTimingEnabled") }
    }

    /// MTL_HUD_INSIGHTS_ENABLED - the HUD's Insights panel.
    @Published var insightsEnabled: Bool {
        didSet { UserDefaults.standard.set(insightsEnabled, forKey: "insightsEnabled") }
    }

    /// MTL_HUD_SHOW_METRICS_RANGE - show each metric's min/max as well as now.
    @Published var showMetricsRange: Bool {
        didSet { UserDefaults.standard.set(showMetricsRange, forKey: "showMetricsRange") }
    }

    /// MTL_HUD_SHOW_ZERO_METRICS - keep metrics on screen while they read zero
    /// instead of hiding them.
    @Published var showZeroMetrics: Bool {
        didSet { UserDefaults.standard.set(showZeroMetrics, forKey: "showZeroMetrics") }
    }

    // MARK: - Open at Login

    @Published var openAtLogin: Bool {
        didSet {
            if openAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
                enableHUDOnBoot = false
            }
        }
    }

    /// Options that add work to the render path rather than just drawing more
    /// on screen. Encoder timing instruments every command encoder, which Apple
    /// warns about in its own panel; on a translated D3D12 title it is enough to
    /// change timing noticeably.
    var costlyOptionsEnabled: Bool {
        encoderTimingEnabled || logShaderEnabled
    }

    /// Turn off everything that instruments the game, leaving the HUD showing.
    func useSafeOptions() {
        encoderTimingEnabled = false
        logShaderEnabled = false
        insightsEnabled = false
        statusMessage = "Instrumentation off. Press Apply, then restart the game."
    }

    // MARK: - Status message (not persisted)

    @Published var statusMessage: String = ""

    // MARK: - Alignment lookup table

    private let alignmentMap: [String: String] = [
        "topLeft": "10",
        "topCenter": "14",
        "topRight": "12",
        "center": "30",
        "leftCenter": "26",
        "centerRight": "28",
        "bottomRight": "20",
        "bottomCenter": "22",
        "bottomLeft": "18"
    ]

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        self.hudEnabled = defaults.object(forKey: "hudEnabled") as? Bool ?? false
        self.scale = defaults.object(forKey: "scale") as? Double ?? 0.20
        self.opacity = defaults.object(forKey: "opacity") as? Double ?? 1.00
        self.alignment = defaults.string(forKey: "alignment") ?? "topRight"
        self.enableHUDOnBoot = defaults.object(forKey: "enableHUDOnBoot") as? Bool ?? false
        self.logEnabled = defaults.object(forKey: "logEnabled") as? Bool ?? false
        self.logShaderEnabled = defaults.object(forKey: "logShaderEnabled") as? Bool ?? false
        self.encoderTimingEnabled = defaults.object(forKey: "encoderTimingEnabled") as? Bool ?? false
        self.insightsEnabled = defaults.object(forKey: "insightsEnabled") as? Bool ?? false
        self.showMetricsRange = defaults.object(forKey: "showMetricsRange") as? Bool ?? false
        self.showZeroMetrics = defaults.object(forKey: "showZeroMetrics") as? Bool ?? false
        self.openAtLogin = SMAppService.mainApp.status == .enabled

        if let saved = defaults.stringArray(forKey: "selectedElements") {
            self.selectedElements = Set(saved)
        } else {
            self.selectedElements = []
        }
    }

    // MARK: - Apply / Disable

    func applySettings() {
        if hudEnabled {
            runLaunchctl(["setenv", "MTL_HUD_ENABLED", "1"])
            runLaunchctl(["setenv", "MTL_HUD_ELEMENTS", selectedElements.joined(separator: ",")])
            runLaunchctl(["setenv", "MTL_HUD_OPACITY", String(format: "%.3f", opacity)])
            runLaunchctl(["setenv", "MTL_HUD_SCALE", String(format: "%.3f", scale)])
            runLaunchctl(["setenv", "MTL_HUD_ALIGNMENT", alignmentValue(for: alignment)])

            // Unset rather than set to 0: the HUD treats any value as enabled.
            if logEnabled {
                runLaunchctl(["setenv", "MTL_HUD_LOG_ENABLED", "1"])
            } else {
                runLaunchctl(["unsetenv", "MTL_HUD_LOG_ENABLED"])
            }
            if logShaderEnabled {
                runLaunchctl(["setenv", "MTL_HUD_LOG_SHADER_ENABLED", "1"])
            } else {
                runLaunchctl(["unsetenv", "MTL_HUD_LOG_SHADER_ENABLED"])
            }

            setFlag("MTL_HUD_ENCODER_TIMING_ENABLED", encoderTimingEnabled)
            setFlag("MTL_HUD_INSIGHTS_ENABLED", insightsEnabled)
            setFlag("MTL_HUD_SHOW_METRICS_RANGE", showMetricsRange)
            setFlag("MTL_HUD_SHOW_ZERO_METRICS", showZeroMetrics)

            statusMessage = costlyOptionsEnabled
                ? "⚠️ Applied with instrumentation on — this adds work to the render path."
                : "✅ Applied. Affects apps launched from now on."
        } else {
            disableHUD()
        }
    }

    func disableHUD() {
        // Clear every variable, not just the enable flag: leaving the others
        // set means a later enable silently inherits stale values.
        for key in Self.allKeys {
            runLaunchctl(["unsetenv", key])
        }
        statusMessage = "🚫 Disabled. Running apps keep the HUD until restarted."
    }

    func applyOnBootIfNeeded() {
        if enableHUDOnBoot && hudEnabled {
            applySettings()
        }
    }

    /// Every variable the HUD reads, as reported by "Export HUD Configuration"
    /// in Apple's own panel with all options enabled.
    static let allKeys = [
        "MTL_HUD_ENABLED", "MTL_HUD_ELEMENTS", "MTL_HUD_OPACITY", "MTL_HUD_SCALE",
        "MTL_HUD_ALIGNMENT", "MTL_HUD_LOG_ENABLED", "MTL_HUD_LOG_SHADER_ENABLED",
        "MTL_HUD_ENCODER_TIMING_ENABLED", "MTL_HUD_INSIGHTS_ENABLED",
        "MTL_HUD_SHOW_METRICS_RANGE", "MTL_HUD_SHOW_ZERO_METRICS"
    ]

    /// The HUD treats any value as enabled, so a flag is set or removed.
    private func setFlag(_ key: String, _ on: Bool) {
        runLaunchctl([on ? "setenv" : "unsetenv", key] + (on ? ["1"] : []))
    }

    // MARK: - Import from Apple's HUD panel

    /// Load the plist written by "Export HUD Configuration" in Apple's own HUD
    /// panel (Shift-Fn-F12 over any Metal app). That export is the authoritative
    /// list of what the HUD understands, so importing it keeps this app in step
    /// with whatever macOS supports rather than a hard-coded guess.
    ///
    /// Returns false if the file is not a HUD export.
    @discardableResult
    func importConfiguration(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
              plist["MTL_HUD_ENABLED"] != nil
        else {
            statusMessage = "⚠️ Not a HUD configuration file."
            return false
        }

        if let v = plist["MTL_HUD_ENABLED"] as? Bool { hudEnabled = v }
        if let v = plist["MTL_HUD_LOG_ENABLED"] as? Bool { logEnabled = v }
        if let v = plist["MTL_HUD_LOG_SHADER_ENABLED"] as? Bool { logShaderEnabled = v }
        if let v = plist["MTL_HUD_ENCODER_TIMING_ENABLED"] as? Bool { encoderTimingEnabled = v }
        if let v = plist["MTL_HUD_INSIGHTS_ENABLED"] as? Bool { insightsEnabled = v }
        if let v = plist["MTL_HUD_SHOW_METRICS_RANGE"] as? Bool { showMetricsRange = v }
        if let v = plist["MTL_HUD_SHOW_ZERO_METRICS"] as? Bool { showZeroMetrics = v }
        if let v = plist["MTL_HUD_SCALE"] as? Double { scale = v }
        if let v = plist["MTL_HUD_OPACITY"] as? Double { opacity = v }

        if let csv = plist["MTL_HUD_ELEMENTS"] as? String {
            selectedElements = Set(csv.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
        }

        // The export stores alignment as the numeric bitmask; map it back.
        if let raw = plist["MTL_HUD_ALIGNMENT"] {
            let number = String(describing: raw)
            if let key = alignmentMap.first(where: { $0.value == number })?.key {
                alignment = key
            }
        }

        if costlyOptionsEnabled {
            statusMessage = "📥 Imported \(url.lastPathComponent) — note it enables "
                          + "instrumentation that can affect game performance. Press Apply."
        } else {
            statusMessage = "📥 Imported \(url.lastPathComponent). Press Apply."
        }
        return true
    }

    // MARK: - Helpers

    func alignmentValue(for key: String) -> String {
        alignmentMap[key] ?? "4"
    }

    private func runLaunchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", "\(getuid())", "/bin/launchctl"] + args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Error running launchctl: \(error)")
        }
    }
}
