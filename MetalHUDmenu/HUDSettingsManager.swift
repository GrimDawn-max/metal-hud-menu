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

    // MARK: - Mac stats (read live by libMHUDStats inside games)

    /// Stat tokens and labels. Keep in sync with the names in NativeHUD/mhud_stats.mm.
    /// A metric the stats dylib can publish. `help` is shown on hover, since
    /// the HUD itself is drawn into the Metal layer and cannot show a tooltip.
    struct SystemStat {
        let key: String
        let label: String
        let group: String
        let help: String
    }

    /// Order here is the order the groups appear in the settings UI; the HUD
    /// orders its own rows separately.
    static let systemStatCatalog: [SystemStat] = [
        .init(key: "cpuusage", label: "CPU usage", group: "CPU",
              help: "Share of total CPU capacity in use across all cores, whole machine — not this game's share."),
        .init(key: "cputemp", label: "CPU temperature", group: "CPU",
              help: "Hottest CPU sensor, in °C."),
        .init(key: "cpupower", label: "CPU power (est.)", group: "CPU",
              help: "Package CPU power draw, in watts."),
        .init(key: "ecorepower", label: "E-core power", group: "CPU",
              help: "Power used by the efficiency-core cluster. Low while P-core power is high means the work is on the performance cores."),
        .init(key: "pcorepower", label: "P-core power", group: "CPU",
              help: "Power used by the performance-core clusters, summed. E-core plus P-core equals the package figure."),

        .init(key: "gpuusage", label: "GPU usage", group: "GPU",
              help: "Share of GPU capacity in use. Sustained 100% usually means the GPU is the limit."),
        .init(key: "gputemp", label: "GPU temperature", group: "GPU",
              help: "Hottest GPU sensor, in °C."),
        .init(key: "gpupower", label: "GPU power", group: "GPU",
              help: "GPU power draw, in watts."),

        .init(key: "fans", label: "Fan speed", group: "System",
              help: "Measured fan speed in RPM, one row per fan. Zero means stopped, which is normal when cool. Fanless Macs show nothing."),
        .init(key: "systempower", label: "System power", group: "System",
              help: "Whole-machine power draw. Larger than CPU plus GPU because it includes display, memory and storage."),
        .init(key: "thermal", label: "Thermal pressure", group: "System",
              help: "macOS's own assessment: Nominal, Fair, Serious or Critical. Past Nominal means the system is throttling."),

        .init(key: "free", label: "Free RAM", group: "Memory",
              help: "Memory not in use. Low free RAM is not itself a problem on macOS."),
        .init(key: "inactive", label: "Free + inactive RAM", group: "Memory",
              help: "Free memory plus cached data that can be reclaimed. Usually the more meaningful 'available' figure."),
        .init(key: "swap", label: "Swap used", group: "Memory",
              help: "Memory paged to disk. Anything above zero while gaming is worth noticing; growing swap usually means stutter."),

        .init(key: "diskread", label: "Disk read", group: "Disk",
              help: "Internal storage read throughput, averaged over a few seconds because disk I/O is bursty."),
        .init(key: "diskwrite", label: "Disk write", group: "Disk",
              help: "Internal storage write throughput. Shown on one row with read if both are enabled."),
        .init(key: "extdiskread", label: "External disk read", group: "Disk",
              help: "External storage read throughput. Worth watching if games are installed on an external drive."),
        .init(key: "extdiskwrite", label: "External disk write", group: "Disk",
              help: "External storage write throughput."),

        .init(key: "netdown", label: "Network down", group: "Network",
              help: "Combined Wi-Fi and Ethernet download. VPN tunnels are excluded, since that traffic also crosses the physical link."),
        .init(key: "netup", label: "Network up", group: "Network",
              help: "Combined Wi-Fi and Ethernet upload."),
        .init(key: "wifidown", label: "Wi-Fi down", group: "Network",
              help: "Wi-Fi download only. Reads zero if the machine is routing over Ethernet."),
        .init(key: "wifiup", label: "Wi-Fi up", group: "Network",
              help: "Wi-Fi upload only."),
        .init(key: "ethdown", label: "Ethernet down", group: "Network",
              help: "Wired download only, including USB and Thunderbolt adapters."),
        .init(key: "ethup", label: "Ethernet up", group: "Network",
              help: "Wired upload only."),
    ]

    /// Shown on first run. Deliberately small: the "is the machine coping?"
    /// set, which is what most people want and fits without crowding the HUD.
    /// Everything else is opt-in — all 24 at once is a wall of text.
    static let defaultSystemStats: Set<String> = [
        "cpuusage", "cputemp", "gpuusage", "gputemp", "fans", "thermal"
    ]

    /// Catalog grouped for display, preserving the order above.
    static var systemStatGroups: [(name: String, stats: [SystemStat])] {
        var order: [String] = []
        var byGroup: [String: [SystemStat]] = [:]
        for stat in systemStatCatalog {
            if byGroup[stat.group] == nil { order.append(stat.group) }
            byGroup[stat.group, default: []].append(stat)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    @Published var systemStats: Set<String> {
        didSet { UserDefaults.standard.set(systemStats.sorted(), forKey: "systemStats") }
    }

    @Published var steamConnected: Bool {
        didSet { UserDefaults.standard.set(steamConnected, forKey: "steamConnected") }
    }

    @Published var steamNeverAsk: Bool {
        didSet { UserDefaults.standard.set(steamNeverAsk, forKey: "steamNeverAsk") }
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
        self.openAtLogin = SMAppService.mainApp.status == .enabled
        // Distinguish "never chosen" from "deliberately cleared": a saved
        // empty array must stay empty, so only fall back on a missing key.
        if let saved = defaults.stringArray(forKey: "systemStats") {
            self.systemStats = Set(saved)
        } else {
            self.systemStats = HUDSettingsManager.defaultSystemStats
        }
        self.steamConnected = defaults.bool(forKey: "steamConnected")
        self.steamNeverAsk = defaults.bool(forKey: "steamNeverAsk")

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
            statusMessage = "✅ Applied Metal HUD settings."
        } else {
            disableHUD()
        }
    }

    func disableHUD() {
        runLaunchctl(["unsetenv", "MTL_HUD_ENABLED"])
        statusMessage = "🚫 Disabled Metal HUD."
    }

    func applyOnBootIfNeeded() {
        if enableHUDOnBoot && hudEnabled {
            applySettings()
        }
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
