//
//  SikarugirSupport.swift
//  MetalHUDMenu
//
//  Getting the stats rows into Windows games running in Sikarugir wrappers.
//
//  Sikarugir needs no entitlement and no re-signing: its wine is not built
//  with the hardened runtime, so dyld honours DYLD_INSERT_LIBRARIES. The only
//  problem is getting the variable to wine.
//
//  Setting it on the wrapper (LSEnvironment) does not work. The launcher
//  starts wine through /bin/sh -c "export ...; wine ...", and with SIP on,
//  macOS strips every DYLD_* variable when /bin/sh starts. Measured: the
//  library loaded in the launcher and nowhere after it.
//
//  What does work is the wrapper's own "Unix Commands" field (Configure.app >
//  Configuration), stored as CLI Custom Commands in its Info.plist. The
//  launcher pastes that text verbatim into the same shell command, after its
//  own exports and before it starts wine, so an export there is set *inside*
//  the shell and survives. Each wrapper carries its own settings, so this is
//  per wrapper -- but it survives Sikarugir updates and engine changes.
//
//  The wrapper's own METAL_HUD switch must be on as well. The launcher sets
//  MTL_HUD_ENABLED from it, overriding the value MetalHUDmenu sets for
//  everything else, so with it off the library loads but there is no HUD to
//  add rows to. Measured on a wrapper made by Sikarugir 1.0.

import Combine
import Foundation
import SwiftUI

@MainActor
final class SikarugirSupport: ObservableObject {

    enum State: Equatable {
        case notInstalled           // no Sikarugir wrappers on this Mac
        case ready                  // every wrapper has the line
        case needsSetup             // none have it
        case partlySetUp            // some do; usually a wrapper made since
        case failed(String)
    }

    @Published private(set) var state: State = .needsSetup
    @Published private(set) var message = ""

    /// One Sikarugir wrapper.
    struct Wrapper {
        let app: URL
        var name: String { app.deletingPathExtension().lastPathComponent }
        var plist: URL { app.appendingPathComponent("Contents/Info.plist") }
    }

    private static let commandsKey = "CLI Custom Commands"
    private static let hudKey = "METAL_HUD"
    /// The wrapper's METAL_HUD before setup turned it on, so Revert can put
    /// it back. Kept in the wrapper itself; Sikarugir ignores unknown keys.
    private static let savedHudKey = "MetalHUDmenu previous METAL_HUD"

    private var library: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/libMHUDStats.dylib")
    }

    /// Appends to any value the user's own commands set earlier in the field,
    /// rather than replacing it. Quoted because the field is run as shell.
    private var line: String {
        "export DYLD_INSERT_LIBRARIES=\"${DYLD_INSERT_LIBRARIES:+$DYLD_INSERT_LIBRARIES:}\(library.path)\""
    }

    // MARK: - Finding wrappers

    /// Wrappers are found by identity, not name: Sikarugir gives each one a
    /// bundle identifier of com.sikarugir.<Name><digits>, and each carries its
    /// own Configure.app. ~/Applications/Sikarugir is where Creator puts them;
    /// the other two folders catch wrappers the user has moved.
    static var wrappers: [Wrapper] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folders = [home.appendingPathComponent("Applications/Sikarugir"),
                       home.appendingPathComponent("Applications"),
                       URL(fileURLWithPath: "/Applications")]
        var seen = Set<String>()
        return folders.flatMap { folder -> [Wrapper] in
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return items.filter { $0.pathExtension == "app" }.compactMap { app in
                guard let id = Bundle(url: app)?.bundleIdentifier,
                      id.hasPrefix("com.sikarugir."),
                      fm.fileExists(atPath: app.appendingPathComponent("Contents/Configure.app").path),
                      seen.insert(app.standardizedFileURL.path).inserted else { return nil }
                return Wrapper(app: app)
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Reading the current state

    private func settings(_ wrapper: Wrapper) -> [String: Any]? {
        guard let data = try? Data(contentsOf: wrapper.plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func hasLine(_ dict: [String: Any]) -> Bool {
        (dict[Self.commandsKey] as? String ?? "").contains(library.lastPathComponent)
    }

    private func hudOn(_ dict: [String: Any]) -> Bool {
        (dict[Self.hudKey] as? NSNumber)?.intValue == 1 || (dict[Self.hudKey] as? String) == "1"
    }

    private func configured(_ wrapper: Wrapper) -> Bool {
        guard let dict = settings(wrapper) else { return false }
        return hasLine(dict) && hudOn(dict)
    }

    private func touched(_ wrapper: Wrapper) -> Bool {
        guard let dict = settings(wrapper) else { return false }
        return hasLine(dict) || dict[Self.savedHudKey] != nil
    }

    func refresh() {
        let wrappers = Self.wrappers
        guard !wrappers.isEmpty else { state = .notInstalled; message = ""; return }
        let missing = wrappers.filter { !configured($0) }.map(\.name)
        if missing.isEmpty {
            state = .ready
            message = "Ready. \(wrappers.count == 1 ? "The wrapper" : "All \(wrappers.count) wrappers") will show the stats rows from their next launch."
        } else if missing.count < wrappers.count {
            state = .partlySetUp
            message = "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not set up yet, so \(missing.count == 1 ? "its" : "their") games will not show the stats rows. Set up to include \(missing.count == 1 ? "it" : "them")."
        } else {
            state = .needsSetup
            message = "Not set up. Games in Sikarugir wrappers will not show the custom rows."
        }
    }

    // MARK: - Applying

    func setUp() {
        guard FileManager.default.fileExists(atPath: library.path) else {
            state = .failed("The stats library is missing from this app.")
            message = state.failureText ?? ""
            return
        }
        let failures = Self.wrappers.filter { !configured($0) }.compactMap { wrapper -> String? in
            update(wrapper) { dict in
                if !self.hasLine(dict) {
                    let existing = dict[Self.commandsKey] as? String ?? ""
                    dict[Self.commandsKey] = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? self.line : existing + "\n" + self.line
                }
                if !self.hudOn(dict) {
                    if dict[Self.savedHudKey] == nil { dict[Self.savedHudKey] = dict[Self.hudKey] ?? 0 }
                    dict[Self.hudKey] = 1
                }
            }.map { "\(wrapper.name): \($0)" }
        }
        finish(failures)
    }

    func revert() {
        let failures = Self.wrappers.filter(touched).compactMap { wrapper -> String? in
            update(wrapper) { dict in
                dict[Self.commandsKey] = (dict[Self.commandsKey] as? String ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.contains(self.library.lastPathComponent) }
                    .joined(separator: "\n")
                if let previous = dict.removeValue(forKey: Self.savedHudKey) {
                    dict[Self.hudKey] = previous
                }
            }.map { "\(wrapper.name): \($0)" }
        }
        finish(failures)
        if failures.isEmpty, state != .notInstalled {
            message = "Reverted. Each wrapper's Unix Commands and Metal HUD setting are as they were."
        }
    }

    private func finish(_ failures: [String]) {
        if failures.isEmpty { refresh() }
        else { state = .failed(failures.joined(separator: "\n")); message = state.failureText ?? "" }
    }

    /// Changes only the keys `change` touches and keeps the file's format.
    /// Configure.app writes this same file, so editing it is ordinary.
    private func update(_ wrapper: Wrapper, _ change: (inout [String: Any]) -> Void) -> String? {
        do {
            let data = try Data(contentsOf: wrapper.plist)
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard var dict = try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format) as? [String: Any]
            else { return "Its settings could not be read." }
            change(&dict)
            let out = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
            try out.write(to: wrapper.plist, options: .atomic)
            return nil
        } catch {
            // EPERM here is App Management refusing, as with CrossOver.
            if (error as NSError).code == NSFileWriteNoPermissionError {
                return "macOS blocked the change. Allow MetalHUDmenu under System Settings > Privacy & Security > App Management, then quit and reopen MetalHUDmenu and try again: macOS applies the permission only after a restart."
            }
            return error.localizedDescription
        }
    }
}

extension SikarugirSupport.State {
    var failureText: String? {
        if case .failed(let text) = self { return text }
        return nil
    }
}
