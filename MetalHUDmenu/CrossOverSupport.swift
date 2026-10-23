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

    static var app: URL? {
        let candidates = ["/Applications/CrossOver.app", "/Applications/CrossOver Preview.app"]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
    private var sharedSupport: URL? {
        Self.app?.appendingPathComponent("Contents/SharedSupport/CrossOver")
    }
    /// The loader that hosts Windows processes. Not bin/wineloader, and not
    /// the hosted-application loader: measured, this is the one that matters.
    private var loader: URL? {
        sharedSupport?.appendingPathComponent("lib/wine/x86_64-unix/wine")
    }
    private var config: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrossOver/CrossOver.conf")
    }
    private var backup: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalHUDmenu/crossover-wine-loader.original")
    }
    private var library: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/libMHUDStats.dylib")
    }

    // MARK: - Reading the current state

    /// Whether the loader will honour DYLD_INSERT_LIBRARIES.
    private func loaderEntitled() -> Bool {
        guard let loader else { return false }
        guard let out = run("/usr/bin/codesign",
                            ["-d", "--entitlements", "-", "--xml", loader.path]) else { return false }
        return out.contains(entitlement)
    }

    private func configured() -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains(library.lastPathComponent)
    }

    func refresh() {
        guard Self.app != nil, loader != nil else { state = .notInstalled; message = ""; return }
        let hasConfig = configured(), hasEntitlement = loaderEntitled()
        switch (hasConfig, hasEntitlement) {
        case (true, true):
            state = .ready
            message = "Ready. Games launched from CrossOver show the stats rows."
        case (true, false):
            // Config survives updates but the loader does not, so this pair
            // almost always means CrossOver was updated since setup.
            state = .entitlementLost
            message = "CrossOver was updated and the change to its wine loader was lost. Set up again to restore it."
        default:
            state = .needsSetup
            message = "Not set up. CrossOver games will show Apple's HUD without the custom rows."
        }
    }

    // MARK: - Applying

    func setUp() {
        guard let loader else { return }
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
            let entitleResult = await self.entitleLoader(loader)
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
        guard let loader else { return }
        busy = true
        message = "Reverting…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Not `?? await ...`: the right-hand side of ?? is an autoclosure,
            // which cannot carry an await. Bound to a let before crossing into
            // the main actor, or Swift 6 rejects capturing a mutable var.
            // Both awaits spelled out: ?? takes an autoclosure, which cannot
            // contain one, and a captured var cannot cross into the main actor.
            let restored = await self.restoreLoader(loader)
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

    /// Keeps the original, adds the entitlement, re-signs. Everything that
    /// needs root happens in one privileged shell command so the user is asked
    /// for their password once rather than per step.
    private func entitleLoader(_ loader: URL) async -> String? {
        if loaderEntitled() { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: backup.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let entitlements = NSTemporaryDirectory() + "mhud-entitlements.plist"
        let existing = run("/usr/bin/codesign",
                           ["-d", "--entitlements", "-", "--xml", loader.path]) ?? ""
        let plist = existing.contains("<plist") ? existing :
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict/></plist>"
        try? plist.write(toFile: entitlements, atomically: true, encoding: .utf8)
        _ = run("/usr/libexec/PlistBuddy", ["-c", "Add :\(entitlement) bool true", entitlements])
        _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :\(entitlement) true", entitlements])

        let identifier = (run("/usr/bin/codesign", ["-dv", loader.path]) ?? "")
            .split(separator: "\n")
            .first { $0.hasPrefix("Identifier=") }
            .map { String($0.dropFirst("Identifier=".count)) }
            ?? "com.codeweavers.CrossOver.wineloader"

        let script = """
        /bin/cp -p '\(loader.path)' '\(backup.path)' && \
        /usr/bin/codesign --force --sign - --identifier '\(identifier)' \
          --options runtime --entitlements '\(entitlements)' '\(loader.path)'
        """
        if let problem = runPrivileged(script) { return problem }
        try? fm.removeItem(atPath: entitlements)
        return loaderEntitled() ? nil
            : "The change did not take effect. CrossOver may have been running; quit it and try again."
    }

    private func restoreLoader(_ loader: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: backup.path) else {
            return "No copy of CrossOver's original loader was kept, so it cannot be restored here. Reinstalling CrossOver will restore it."
        }
        return runPrivileged("/bin/cp -p '\(backup.path)' '\(loader.path)'")
    }

    // MARK: - Running things

    private func run(_ tool: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

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
        return (error[NSAppleScript.errorMessage] as? String) ?? "The change could not be made."
    }
}

extension CrossOverSupport.State {
    var failureText: String? {
        if case .failed(let text) = self { return text }
        return nil
    }
}
