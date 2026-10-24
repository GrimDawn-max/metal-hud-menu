//
//  MacStatsView.swift
//  MetalHUDMenu
//

import SwiftUI

struct MacStatsView: View {
    @ObservedObject var settings: HUDSettingsManager
    @ObservedObject var helper: StatsHelper
    @StateObject private var crossover = CrossOverSupport()
    @StateObject private var sikarugir = SikarugirSupport()
    @State private var profileMessage = ""
    /// What to describe in the strip below the list. Hovering previews a
    /// metric; clicking one keeps its description up afterwards, since system
    /// tooltips are unreliable inside a menu bar popover.
    @State private var hoveredHelp: String?
    @State private var stickyHelp: String?

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    private func allOn(_ stats: [HUDSettingsManager.SystemStat]) -> Bool {
        !stats.isEmpty && stats.allSatisfy { settings.systemStats.contains($0.key) }
    }

    private func toggleGroup(_ stats: [HUDSettingsManager.SystemStat]) {
        if allOn(stats) { stats.forEach { settings.systemStats.remove($0.key) } }
        else { stats.forEach { settings.systemStats.insert($0.key) } }
    }

    var body: some View {
        content.onAppear { crossover.refresh(); sikarugir.refresh() }
    }

    private var content: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac stats in Apple's HUD")
                .font(.headline)
            Text("Pick once. Games that are already running update within a second.")
                // Explicit size: .caption is 10pt on macOS, too small to read
                // comfortably as the instruction for the whole tab.
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            // Grouped by subsystem: a flat list of 24 checkboxes is hard to
            // scan, and the grouping matches the order the rows appear in the
            // HUD. Each control carries a one-line explanation on hover, since
            // the HUD itself is drawn into the Metal layer and cannot show one.
            ForEach(HUDSettingsManager.systemStatGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(allOn(group.stats) ? "None" : "All") {
                            toggleGroup(group.stats)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(allOn(group.stats)
                              ? "Turn off every \(group.name) metric"
                              : "Turn on every \(group.name) metric")
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(group.stats, id: \.key) { stat in
                            Toggle(stat.label, isOn: Binding(
                                get: { settings.systemStats.contains(stat.key) },
                                set: { on in
                                    if on { settings.systemStats.insert(stat.key) }
                                    else { settings.systemStats.remove(stat.key) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .help(stat.help)
                            .onHover { inside in
                                hoveredHelp = inside ? stat.help : nil
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                stickyHelp = stat.help
                            })
                        }
                    }
                }
                .padding(.bottom, 2)
            }

            // Description strip: follows the pointer, and holds the last
            // clicked metric when the pointer leaves the list.
            Text(hoveredHelp ?? stickyHelp ?? "Hover or click a metric to see what it measures.")
                .font(.callout)
                .foregroundStyle(hoveredHelp == nil && stickyHelp == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                .animation(.easeOut(duration: 0.12), value: hoveredHelp)

            HStack {
                Button("Select none") { settings.systemStats.removeAll() }
                    .help("Turn off every metric")
                Button("Defaults") { settings.systemStats = HUDSettingsManager.defaultSystemStats }
                    .help("Back to the starting set: CPU and GPU usage and temperature, fans, thermal pressure")
                Spacer()
                Text("\(settings.systemStats.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Profiles: the selections live in UserDefaults, which stays on
            // this Mac. A file makes a setup portable and lets several be kept.
            HStack {
                Button("Export profile…") { profileMessage = HUDProfileIO.exportProfile(from: settings) }
                    .help("Save the HUD settings and selected metrics to a file")
                Button("Import profile…") { profileMessage = HUDProfileIO.importProfile(into: settings) }
                    .help("Load HUD settings and selected metrics from a file")
                Spacer()
            }
            if !profileMessage.isEmpty {
                Text(profileMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settings.hudEnabled {
                // This is the one message that stops the whole pane doing
                // anything, so it is sized to be read rather than skimmed past.
                Label("Stats appear inside the HUD. Turn it on in the HUD tab.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }

            Divider().padding(.vertical, 4)

            // MARK: - Steam
            HStack {
                Text("Steam").font(.headline)
                Spacer()
                Button(settings.steamConnected ? "Disconnect" : "Connect") {
                    helper.setSteamConnected(!settings.steamConnected)
                }
                .disabled(helper.busy)
            }
            Text(helper.steamStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ask when Steam opens", isOn: Binding(
                get: { !settings.steamNeverAsk },
                set: { settings.steamNeverAsk = !$0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(settings.steamConnected)
            Text("Connecting adds MetalHUDmenu to each game's launch options and keeps your own. If Steam is open, it restarts once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !CrossOverSupport.installs.isEmpty {
                Divider().padding(.vertical, 4)

                // MARK: - CrossOver
                HStack {
                    Text("CrossOver").font(.system(size: 20, weight: .bold))
                    Spacer()
                    switch crossover.state {
                    case .ready:
                        Button("Revert") { crossover.revert() }.disabled(crossover.busy)
                    case .entitlementLost:
                        Button("Set up again") { crossover.setUp() }.disabled(crossover.busy)
                    default:
                        Button("Set up") { crossover.setUp() }.disabled(crossover.busy)
                    }
                }
                SetupStatus(message: crossover.message, kind: {
                    if crossover.busy { return .working }
                    switch crossover.state {
                    case .ready: return .ready
                    case .needsSetup: return .off
                    case .entitlementLost, .failed: return .problem
                    case .notInstalled: return .working
                    }
                }())
                Text("MetalHUDmenu must be allowed under Privacy & Security \u{203A} App Management \u{2014} macOS guards other apps' bundles even from an administrator. A password is asked for only if CrossOver was installed by another account.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Setting up adds one line to CrossOver's own configuration, which covers every bottle including ones made later, and adds an entitlement to CrossOver's wine loader so macOS lets the stats library load. The loader is re-signed, replacing CodeWeavers' signature; the original is kept and Revert restores it. A CrossOver update undoes the loader change, and this will say so.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !SikarugirSupport.wrappers.isEmpty {
                Divider().padding(.vertical, 4)

                // MARK: - Sikarugir
                HStack {
                    Text("Sikarugir").font(.system(size: 20, weight: .bold))
                    Spacer()
                    if sikarugir.state == .ready {
                        Button("Revert") { sikarugir.revert() }
                    } else {
                        Button("Set up") { sikarugir.setUp() }
                    }
                }
                SetupStatus(message: sikarugir.message, kind: {
                    switch sikarugir.state {
                    case .ready: return .ready
                    case .needsSetup: return .off
                    case .partlySetUp, .failed: return .problem
                    case .notInstalled: return .working
                    }
                }())
                Text("Setting up adds one line to each wrapper's Unix Commands (Configure \u{203A} Configuration), keeping anything already there. Nothing is re-signed. It survives Sikarugir updates and engine changes; wrappers made later need Set up once. It also turns on each wrapper's own Metal HUD switch, which Revert puts back. Close any open Configure windows first: Configure saves all its settings when it closes and would undo the change. Needs the same App Management permission as CrossOver.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The macOS 26 path is no longer experimental: reportLegacy and
            // addLabel:after: were verified on 26.4.1, with every selected row
            // appearing in four Windows games under CrossOver and in a native
            // Metal window on both architectures. What that path needs is the
            // MTL_HUD_ELEMENTS fix in the constructor, not a caveat here.

            Spacer()
        }
        }
    }
}

/// The one-line state of a setup section, coloured so "off" is as visible as
/// "broken": a grey caption read as part of the explanation below it.
private struct SetupStatus: View {
    enum Kind { case ready, off, problem, working }
    let message: String
    let kind: Kind

    var body: some View {
        switch kind {
        case .working:
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            label("checkmark.circle.fill", Self.ready)
        case .off:
            label("minus.circle.fill", Self.off)
        case .problem:
            label("exclamationmark.triangle.fill", Self.problem)
        }
    }

    /// Darker than the system colours, which are hard to read as text on a
    /// light window. Dark mode keeps lighter shades so they still stand out.
    private static let ready = shade(light: (0.05, 0.50, 0.20), dark: (0.35, 0.80, 0.45))
    private static let off = shade(light: (0.42, 0.18, 0.62), dark: (0.75, 0.58, 0.95))
    private static let problem = shade(light: (0.72, 0.10, 0.10), dark: (1.00, 0.45, 0.42))

    private static func shade(light: (CGFloat, CGFloat, CGFloat),
                              dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    private func label(_ symbol: String, _ color: Color) -> some View {
        Label(message, systemImage: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
