//
//  MacStatsView.swift
//  MetalHUDMenu
//

import SwiftUI

struct MacStatsView: View {
    @ObservedObject var settings: HUDSettingsManager
    @ObservedObject var helper: StatsHelper
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

            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
                Text("Mac stats on macOS 26 are experimental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        }
    }
}
