//
//  CrossOverSupport.swift
//  MetalHUDMenu
//
//  Getting the stats rows into Windows games running under CrossOver.
//
//  Two things are needed, and neither is per game or per bottle:
//
//  1. One line in ~/Library/Application Support/CrossOver/CrossOver.conf.
//     CrossOver reads that file for every bottle, including ones created
//     later, and it sits outside the application bundle so it survives
//     CrossOver updates. (CXBottle.pm calls set_environment on three configs:
//     the one inside the bundle, this one, and the bottle's own.)
//
//  2. CrossOver's wine loader must carry allow-dyld-environment-variables.
//     Without it dyld *ignores* DYLD_INSERT_LIBRARIES in the process that
//     hosts the game. The variable is still visible in that process's
//     environment, which is why this fails in a way that inspecting the
//     environment never explains -- only whether the library is mapped tells
//     you the truth.
//
//  Step 2 re-signs one CodeWeavers binary, replacing their Developer ID with
//  an ad-hoc signature. The original is kept and `revert` restores it. There
//  is no way to avoid touching the binary: pointing CrossOver at an entitled
//  copy does not work, because bin/wine assigns WINELOADER unconditionally
//  before choosing the loader.
//
//  A CrossOver update replaces the loader and so drops the entitlement. This
//  checks on every launch and offers to re-apply, so the user is not left
//  wondering why the rows stopped.
//
//  Every installed copy is handled, not just one: CrossOver, CrossOver
//  Preview and any beta share the config file above but each has its own
//  loader. Copies are found by bundle identifier rather than by name, so a
//  renamed copy or a differently named beta is still found.

import Combine
import Foundation
import SwiftUI

@MainActor
final class CrossOverSupport: ObservableObject {

    enum State: Equatable {
        case notInstalled           // no CrossOver on this Mac
        case ready                  // config and entitlement both in place
        case needsSetup             // neither, or only part
        case entitlementLost        // was set up; a CrossOver update undid it
        case failed(String)
    }

    @Published private(set) var state: State = .needsSetup
    @Published private(set) var busy = false
    @Published private(set) var message = ""

    private let entitlement = "com.apple.security.cs.allow-dyld-environment-variables"

    // MARK: - Paths

    /// One installed copy of CrossOver.
    struct Install {
        let app: URL
        var name: String { app.deletingPathExtension().lastPathComponent }
        /// The loader that hosts Windows processes. Not bin/wineloader, and not
        /// the hosted-application loader: measured, this is the one that matters.
        var loader: URL {
            app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine")
        }
        /// Kept per copy, so a Preview and a release never share one.
        var backup: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MetalHUDmenu/crossover-wine-loader-\(name).original")
        }
    }

    /// Every copy in /Applications or ~/Applications whose bundle identifier is
    /// CodeWeavers' CrossOver one (release and Preview both use
    /// com.codeweavers.CrossOver) and which actually has the loader. Only those
    /// two folders are searched, so a mounted installer image or a copy in the
    /// Trash is never touched. The loader check excludes CrossOver's own helper
    /// apps and bottle launchers.
    static var installs: [Install] {
        let fm = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"),
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return folders.flatMap { folder -> [Install] in
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return items.filter { $0.pathExtension == "app" }.compactMap { app in
                guard let id = Bundle(url: app)?.bundleIdentifier,
                      id.hasPrefix("com.codeweavers.CrossOver") else { return nil }
                let install = Install(app: app)
                return fm.fileExists(atPath: install.loader.path) ? install : nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var config: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrossOver/CrossOver.conf")
    }
    /// Where the single backup lived before every copy got its own. It was
    /// always taken from /Applications/CrossOver.app when that existed.
    private var legacyBackup: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalHUDmenu/crossover-wine-loader.original")
    }
    private var library: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/libMHUDStats.dylib")
    }

    // MARK: - Reading the current state

    /// Whether the loader will honour DYLD_INSERT_LIBRARIES.
    private func loaderEntitled(_ loader: URL) -> Bool {
        guard let out = run("/usr/bin/codesign",
                            ["-d", "--entitlements", "-", "--xml", loader.path]) else { return false }
        return out.contains(entitlement)
    }

    private func configured() -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains(library.lastPathComponent)
    }

    func refresh() {
        let installs = Self.installs
        guard !installs.isEmpty else { state = .notInstalled; message = ""; return }
        let hasConfig = configured()
        let missing = installs.filter { !loaderEntitled($0.loader) }.map(\.name)
        switch (hasConfig, missing.isEmpty) {
        case (true, true):
            state = .ready
            message = "Ready. Games launched from \(installs.map(\.name).joined(separator: " or ")) show the stats rows."
        case (true, false) where missing.count < installs.count:
            // Some copies done, others not: an update to one of them, or a
            // copy installed since setup.
            state = .entitlementLost
            message = "\(missing.joined(separator: " and ")) was updated or installed since setup, so its games will not show the stats rows. Set up again to include it."
        case (true, false):
            // Config survives updates but the loader does not, so this pair
            // almost always means CrossOver was updated since setup.
            state = .entitlementLost
            message = "\(missing.joined(separator: " and ")) was updated and the change to its wine loader was lost. Set up again to restore it."
        default:
            state = .needsSetup
            message = "Not set up. CrossOver games will show Apple's HUD without the custom rows."
        }
    }

    // MARK: - Applying

    func setUp() {
        let installs = Self.installs
        guard !installs.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: library.path) else {
            state = .failed("The stats library is missing from this app.")
            message = state.failureText ?? ""
            return
        }
        busy = true
        message = "Setting up…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let configResult = await self.writeConfig()
            var entitleResults: [String] = []
            for install in installs {
                if let problem = await self.entitleLoader(install) {
                    entitleResults.append(installs.count > 1 ? "\(install.name): \(problem)" : problem)
                }
            }
            let entitleResult = entitleResults.isEmpty ? nil : entitleResults.joined(separator: "\n")
            await MainActor.run {
                self.busy = false
                let problem = configResult ?? entitleResult
                if let problem {
                    self.state = .failed(problem)
                    self.message = problem
                } else {
                    self.refresh()
                }
            }
        }
    }

    func revert() {
        let installs = Self.installs
        guard !installs.isEmpty else { return }
        busy = true
        message = "Reverting…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Not `?? await ...`: the right-hand side of ?? is an autoclosure,
            // which cannot carry an await. Bound to a let before crossing into
            // the main actor, or Swift 6 rejects capturing a mutable var.
            // Both awaits spelled out: ?? takes an autoclosure, which cannot
            // contain one, and a captured var cannot cross into the main actor.
            var failures: [String] = []
            for install in installs {
                if let problem = await self.restoreLoader(install) {
                    failures.append(installs.count > 1 ? "\(install.name): \(problem)" : problem)
                }
            }
            let restored = failures.isEmpty ? nil : failures.joined(separator: "\n")
            let removed = restored == nil ? await self.removeConfigLine() : nil
            let problem = restored ?? removed
            await MainActor.run {
                self.busy = false
                if let problem { self.state = .failed(problem); self.message = problem }
                else { self.refresh(); self.message = "Reverted. CrossOver is as it was." }
            }
        }
    }

    // MARK: - The two steps

    /// Adds the line without rewriting the file: it holds the user's licence
    /// token and a great deal else, so it is edited, never regenerated.
    private func writeConfig() async -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: config.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        if text.contains(library.lastPathComponent) { return nil }

        let entry = "\"DYLD_INSERT_LIBRARIES\" = \"\(library.path)\""
        if let range = text.range(of: "[EnvironmentVariables]") {
            let insertion = text.index(range.upperBound, offsetBy: 0)
            text.insert(contentsOf: "\n" + entry, at: insertion)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n[EnvironmentVariables]\n" + entry + "\n"
        }
        do { try text.write(to: config, atomically: true, encoding: .utf8) }
        catch { return "Could not write CrossOver's configuration: \(error.localizedDescription)" }
        return nil
    }

    private func removeConfigLine() async -> String? {
        guard var text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(library.lastPathComponent) }
        text = kept.joined(separator: "\n")
        do { try text.write(to: config, atomically: true, encoding: .utf8) }
        catch { return "Could not update CrossOver's configuration: \(error.localizedDescription)" }
        return nil
    }

    /// Keeps the original, adds the entitlement, re-signs.
    ///
    /// Signing happens on a copy in the temporary directory, as this app, for
    /// two reasons learned the hard way. codesign run through "do shell script
    /// with administrator privileges" fails with "internal error in Code
    /// Signing subsystem", because root there has no Security session. And the
    /// privileged copy is refused anyway: macOS App Management guards another
    /// app's bundle, and the check is on the calling process, not on being
    /// root. CrossOver's loader is normally owned by the user who installed it,
    /// so no elevation is needed at all -- only the App Management grant.
    private func entitleLoader(_ install: Install) async -> String? {
        let loader = install.loader, backup = install.backup
        if loaderEntitled(loader) { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: backup.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // A loader without the entitlement is CodeWeavers' own, so it always
        // replaces the backup. Keeping the first backup ever taken would, after
        // an update, mean Revert put the previous version's loader back.
        do {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: loader, to: backup)
        }
        catch { return "Could not keep a copy of CrossOver's original loader: \(error.localizedDescription)" }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mhud-wine-loader-\(install.name)")
        try? fm.removeItem(at: temp)
        do { try fm.copyItem(at: loader, to: temp) }
        catch { return "Could not prepare the change: \(error.localizedDescription)" }

        let plistPath = NSTemporaryDirectory() + "mhud-entitlements.plist"
        let existing = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", temp.path]) ?? ""
        let plist = existing.contains("<plist") ? existing :
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict/></plist>"
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = run("/usr/libexec/PlistBuddy", ["-c", "Add :\(entitlement) bool true", plistPath])
        _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :\(entitlement) true", plistPath])

        let identifier = (run("/usr/bin/codesign", ["-dv", temp.path]) ?? "")
            .split(separator: "\n").first { $0.hasPrefix("Identifier=") }
            .map { String($0.dropFirst("Identifier=".count)) }
            ?? "com.codeweavers.CrossOver.wineloader"

        let signed = runChecked("/usr/bin/codesign",
                                ["--force", "--sign", "-", "--identifier", identifier,
                                 "--options", "runtime", "--entitlements", plistPath, temp.path])
        try? fm.removeItem(atPath: plistPath)
        guard signed.ok,
              (run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", temp.path]) ?? "")
                .contains(entitlement) else {
            try? fm.removeItem(at: temp)
            return signed.text.isEmpty
                ? "Could not add the entitlement to a copy of the loader."
                : "Could not add the entitlement: \(signed.text)"
        }

        let problem = self.install(temp, over: loader)
        try? fm.removeItem(at: temp)
        if let problem { return problem }
        return loaderEntitled(loader) ? nil
            : "The change did not take effect. Quit CrossOver and try again."
    }

    /// Replace one file with another, as this app. Falls back to asking for a
    /// password only when the file is owned by someone else, which happens if
    /// CrossOver was installed by a different account.
    private func install(_ source: URL, over destination: URL) -> String? {
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source,
                                                      backupItemName: nil,
                                                      options: [.usingNewMetadataOnly])
            return nil
        } catch {
            let code = (error as NSError).code
            // EPERM here is App Management refusing, not ownership.
            if code == NSFileWriteNoPermissionError || code == 1 {
                if !FileManager.default.isWritableFile(atPath: destination.path) {
                    return runPrivileged("/bin/cp -p '\(source.path)' '\(destination.path)'")
                }
                return "macOS blocked the change to CrossOver. Allow MetalHUDmenu under System Settings > Privacy & Security > App Management, then quit and reopen MetalHUDmenu and try again: macOS applies the permission only after a restart."
            }
            return "Could not update CrossOver's loader: \(error.localizedDescription)"
        }
    }

    private func restoreLoader(_ install: Install) async -> String? {
        let loader = install.loader
        // Nothing to undo on a copy that was never changed.
        if !loaderEntitled(loader) { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: install.backup.path), install.name == "CrossOver",
           fm.fileExists(atPath: legacyBackup.path) {
            try? fm.moveItem(at: legacyBackup, to: install.backup)
        }
        let backup = install.backup
        guard fm.fileExists(atPath: backup.path) else {
            return "No copy of CrossOver's original loader was kept, so it cannot be restored here. Reinstalling CrossOver will restore it."
        }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mhud-wine-loader-restore-\(install.name)")
        try? FileManager.default.removeItem(at: temp)
        do { try FileManager.default.copyItem(at: backup, to: temp) }
        catch { return "Could not prepare the restore: \(error.localizedDescription)" }
        let problem = self.install(temp, over: loader)
        try? FileManager.default.removeItem(at: temp)
        return problem
    }

    // MARK: - Running things

    /// Standard output only. codesign -d --entitlements prints the plist on
    /// stdout and "Executable=..." on stderr; merging the two produced a file
    /// that was not valid XML, so the signing step failed with nothing to
    /// explain why. Kept separate deliberately.
    private func run(_ tool: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Same, but reporting failure, for steps where the reason matters.
    @discardableResult
    private func runChecked(_ tool: String, _ args: [String]) -> (ok: Bool, text: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return (false, error_text(error)) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = (String(data: o, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
        return (task.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func error_text(_ error: Error) -> String { error.localizedDescription }

    /// One password prompt, presented by macOS itself. Returns nil on success
    /// or a message to show the user.
    private func runPrivileged(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "Could not prepare the change." }
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128 is the user cancelling the password prompt, which is not a fault.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        let text = (error[NSAppleScript.errorMessage] as? String) ?? ""
        // Root is not enough to write inside another application's bundle:
        // macOS App Management guards that, and it is the *calling* process
        // that needs the grant. Without it this fails as an opaque
        // "Operation not permitted", which tells the user nothing at all.
        if text.contains("not permitted") {
            return "macOS blocked the change to CrossOver. Allow MetalHUDmenu under System Settings > Privacy & Security > App Management, then quit and reopen MetalHUDmenu and try again: macOS applies the permission only after a restart."
        }
        return text.isEmpty ? "The change could not be made." : text
    }
}

extension CrossOverSupport.State {
    var failureText: String? {
        if case .failed(let text) = self { return text }
        return nil
    }
}
