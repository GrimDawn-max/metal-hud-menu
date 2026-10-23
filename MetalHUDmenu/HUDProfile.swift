//
//  HUDProfile.swift
//  MetalHUDmenu
//
//  Saving and loading a HUD setup as a file.
//
//  The selections live in UserDefaults, which persists on this Mac but cannot
//  be carried anywhere. A profile file makes a setup portable: move it to
//  another machine, keep several and switch between them, or share one.
//
//  JSON rather than a plist because it is readable and editable by hand, and
//  Codable handles it without ceremony. Apple's own HUD export is a separate
//  plist of its own and is untouched by this.
//

import Foundation
import UniformTypeIdentifiers
import AppKit

struct HUDProfile: Codable {
    /// Bumped only if the shape changes incompatibly; unknown future versions
    /// are refused rather than half-applied.
    static let currentVersion = 1

    var version: Int = currentVersion
    var exported: Date = Date()

    // Apple's HUD
    var hudEnabled: Bool
    var selectedElements: [String]
    var scale: Double
    var opacity: Double
    var alignment: String

    // Our metrics
    var systemStats: [String]

    init(from settings: HUDSettingsManager) {
        hudEnabled = settings.hudEnabled
        selectedElements = settings.selectedElements.sorted()
        scale = settings.scale
        opacity = settings.opacity
        alignment = settings.alignment
        systemStats = settings.systemStats.sorted()
    }

    /// Applies the profile. Anything the running build does not recognise is
    /// simply carried in the file and ignored here, so a profile written by a
    /// newer build still loads what it can.
    func apply(to settings: HUDSettingsManager) {
        settings.hudEnabled = hudEnabled
        settings.selectedElements = Set(selectedElements)
        settings.scale = scale
        settings.opacity = opacity
        settings.alignment = alignment
        // Keep only metrics this build knows, or the dylib is handed names it
        // cannot resolve and the user sees nothing with no explanation.
        let known = Set(HUDSettingsManager.systemStatCatalog.map(\.key))
        settings.systemStats = Set(systemStats).intersection(known)
    }

    var unknownStats: [String] {
        let known = Set(HUDSettingsManager.systemStatCatalog.map(\.key))
        return systemStats.filter { !known.contains($0) }.sorted()
    }
}

enum HUDProfileIO {
    static let fileType = UTType.json
    /// A starting point only — the panel is editable, and profiles are
    /// per-game, so the name matters.
    static let defaultName = "HUD profile.json"

    static func encode(_ profile: HUDProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data) throws -> HUDProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(HUDProfile.self, from: data)
        guard profile.version <= HUDProfile.currentVersion else {
            throw NSError(domain: "MetalHUDmenu", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "That profile was written by a newer version of MetalHUDmenu."
            ])
        }
        return profile
    }

    /// Returns a short message for the UI: callers show it rather than
    /// throwing dialogs around.
    @MainActor
    static func exportProfile(from settings: HUDSettingsManager) -> String {
        // LSUIElement means the app is not active when the panel opens, so the
        // name field never takes keyboard focus and the name looks fixed.
        // Activating first is what makes it editable.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = defaultName
        panel.nameFieldLabel = "Save profile as:"
        panel.title = "Export HUD profile"
        panel.message = "Name it after the game or the set of metrics — one profile per game works well."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        do {
            try encode(HUDProfile(from: settings)).write(to: url)
            return "Exported to \(url.lastPathComponent)"
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    static func importProfile(into settings: HUDSettingsManager) -> String {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType]
        panel.allowsMultipleSelection = false
        panel.title = "Import HUD profile"
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        do {
            let profile = try decode(try Data(contentsOf: url))
            profile.apply(to: settings)
            let skipped = profile.unknownStats
            return skipped.isEmpty
                ? "Imported \(url.lastPathComponent)"
                : "Imported \(url.lastPathComponent) — ignored unknown: \(skipped.joined(separator: ", "))"
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }
}
