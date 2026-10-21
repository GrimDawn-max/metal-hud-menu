//
//  MetalHUDMenuApp.swift
//  MetalHUDMenu
//

import SwiftUI

@main
struct MetalHUDMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {} // no default window
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    let settings = HUDSettingsManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Metal HUD")
            button.action = #selector(togglePopover)
        }

        // Setup popover.
        //
        // NSHostingController reports the SwiftUI view's own height, so the
        // popover grows and shrinks as sections are expanded. A fixed
        // contentSize clipped the content instead: with everything open the
        // Apply row fell outside the visible area, and clicking where it
        // appeared to be counted as a click outside a .transient popover,
        // which closed it.
        popover.behavior = .transient
        popover.contentViewController =
            NSHostingController(rootView: ContentView(settings: settings))

        // Auto-apply HUD settings on boot if enabled
        settings.applyOnBootIfNeeded()
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                // Without activating first, the popover can open behind the
                // frontmost application and appear not to have opened at all.
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
