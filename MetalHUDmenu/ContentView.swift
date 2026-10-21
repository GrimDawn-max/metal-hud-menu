//
//  ContentView.swift
//  MetalHUDMenu
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var settings: HUDSettingsManager

    @State private var selectedPreset: String? = nil

    // MARK: - All known HUD elements
    struct HUDElement: Identifiable {
        let id = UUID()
        let key: String
        let label: String
    }

    private let allElements: [HUDElement] = [
        .init(key: "device", label: "Device"),
        .init(key: "rosetta", label: "Rosetta Info"),
        .init(key: "layersize", label: "Layer Size & Composition"),
        .init(key: "memory", label: "Memory"),
        .init(key: "fps", label: "FPS"),
        .init(key: "frameinterval", label: "Frame Interval"),
        .init(key: "frameintervalhistogram", label: "Frame Interval Histogram"),
        .init(key: "metalcpu", label: "Metal CPU"),
        .init(key: "gputimeline", label: "GPU Timeline"),
        .init(key: "shaders", label: "Shader Compilation"),
        .init(key: "framenumber", label: "Frame Number"),
        .init(key: "disk", label: "Disk Usage"),
        .init(key: "frameintervalgraph", label: "Frame Interval Graph"),
        .init(key: "presentdelay", label: "Present Delay"),
        .init(key: "gputime", label: "GPU Time"),
        .init(key: "thermal", label: "Thermal State"),
        .init(key: "fpsgraph", label: "FPS Graph"),
        .init(key: "toplabeledcommandbuffers", label: "Top Labeled Command Buffers"),
        .init(key: "toplabeledencoders", label: "Top Labeled Encoders"),
        .init(key: "layerscale", label: "Layer Scale"),
        .init(key: "refreshrate", label: "Refresh Rate"),
        .init(key: "gamemode", label: "Game Mode"),
        .init(key: "client", label: "Client Process")
    ]

    // MARK: - Alignment options
    struct HUDAlignment: Identifiable {
        let id = UUID()
        let name: String
        let key: String
        let value: String
    }

    private let alignments: [HUDAlignment] = [
        .init(name: "Top Left", key: "topLeft", value: "10"),
        .init(name: "Top Center", key: "topCenter", value: "14"),
        .init(name: "Top Right", key: "topRight", value: "12"),
        .init(name: "Center", key: "center", value: "30"),
        .init(name: "Left Center", key: "leftCenter", value: "26"),
        .init(name: "Center Right", key: "centerRight", value: "28"),
        .init(name: "Bottom Right", key: "bottomRight", value: "20"),
        .init(name: "Bottom Center", key: "bottomCenter", value: "22"),
        .init(name: "Bottom Left", key: "bottomLeft", value: "18")
    ]

    // MARK: - Which sections are open
    //
    // Remembered per user: the window is long enough that whichever sections
    // somebody actually uses should still be open next time.

    @AppStorage("expandPresets")    private var expandPresets = false
    @AppStorage("expandElements")   private var expandElements = true
    @AppStorage("expandAppearance") private var expandAppearance = false
    @AppStorage("expandLogging")    private var expandLogging = false
    @AppStorage("expandDisplay")    private var expandDisplay = false
    @AppStorage("expandLaunch")     private var expandLaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Always visible: the switch everything else qualifies.
            Toggle("Enable Metal HUD", isOn: $settings.hudEnabled)
                .toggleStyle(.switch)

            Divider()

            sectionScroll {
                VStack(alignment: .leading, spacing: 6) {

                    section("Presets", isExpanded: $expandPresets) {
                        VStack(alignment: .leading, spacing: 6) {
                            presetButton("FPS Only", elements: ["fps"])
                            presetButton("Full", elements: allElements.map { $0.key })
                            presetButton("Rich", elements: ["fps", "gputime", "memory", "thermal", "shaders"])
                            // Exactly what Apple's panel exports for its Default preset.
                            presetButton("Default", elements: [
                                "device", "rosetta", "layersize", "memory", "fps",
                                "frameinterval", "frameintervalgraph", "gputime",
                                "gamemode", "client"
                            ])
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    section("Elements", isExpanded: $expandElements) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(allElements) { element in
                                Toggle(element.label, isOn: Binding(
                                    get: { settings.selectedElements.contains(element.key) },
                                    set: { on in
                                        if on { settings.selectedElements.insert(element.key) }
                                        else { settings.selectedElements.remove(element.key) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    section("Appearance", isExpanded: $expandAppearance) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Scale: \(String(format: "%.2f", settings.scale))")
                                Slider(value: $settings.scale, in: 0.05...1.0, step: 0.01)
                            }
                            HStack {
                                Text("Opacity: \(Int(settings.opacity * 100))%")
                                Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.01)
                            }
                            Picker("Location", selection: $settings.alignment) {
                                ForEach(alignments) { a in Text(a.name).tag(a.key) }
                            }
                            .pickerStyle(.menu)
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    section("Logging", isExpanded: $expandLogging) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Log HUD data", isOn: $settings.logEnabled)
                                .toggleStyle(.checkbox)
                            Toggle("Log shader compilation", isOn: $settings.logShaderEnabled)
                                .toggleStyle(.checkbox)
                            Text("Writes to the unified log. Read with:\nlog stream --predicate 'eventMessage CONTAINS \"metal-HUD\"'")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    section("Display", isExpanded: $expandDisplay) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Performance Insights", isOn: $settings.insightsEnabled)
                                .toggleStyle(.checkbox)
                            Toggle("Show metrics value range", isOn: $settings.showMetricsRange)
                                .toggleStyle(.checkbox)
                            Toggle("Show metrics with 0 value", isOn: $settings.showZeroMetrics)
                                .toggleStyle(.checkbox)
                            Toggle("Encoder GPU time tracking", isOn: $settings.encoderTimingEnabled)
                                .toggleStyle(.checkbox)
                            Text("Encoder timing instruments every command encoder. Apple warns it raises CPU cost; on translated games it can affect stability. Leave off unless you are measuring.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    section("Launch", isExpanded: $expandLaunch) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Open at Login", isOn: $settings.openAtLogin)
                                .toggleStyle(.switch)
                            Toggle("Enable HUD on Boot", isOn: $settings.enableHUDOnBoot)
                                .toggleStyle(.switch)
                                .disabled(!settings.openAtLogin)
                                .foregroundStyle(settings.openAtLogin ? .primary : .secondary)
                            Button("Import Apple HUD Config…") { importConfig() }
                        }
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Apply") { settings.applySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Disable HUD") { settings.disableHUD() }
                Spacer()
                Button("Quit App") { NSApplication.shared.terminate(nil) }
            }

            // The single most common reason this looks broken: the variables
            // are read when a process starts, so a running game keeps the old
            // settings however many times you press Apply.
            Text("Settings reach apps launched afterwards — restart the game to see changes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.costlyOptionsEnabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instrumentation is on and adds work to the render path.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Turn instrumentation off") { settings.useSafeOptions() }
                            .font(.caption)
                    }
                }
            }

            if !settings.statusMessage.isEmpty {
                Text(settings.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, height: 560)
    }

    /// A collapsible section whose whole header row is the click target.
    ///
    /// DisclosureGroup only accepts clicks on its chevron, which is a very small
    /// thing to hit. This spans the full width, uses contentShape so the empty
    /// space counts too, and gives the row a background so it reads as something
    /// you can press.
    @ViewBuilder
    private func section<C: View>(_ title: String,
                                  isExpanded: Binding<Bool>,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .center)
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// The author's scroll view on macOS, a plain one elsewhere.
    @ViewBuilder
    private func sectionScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        #if os(macOS)
        AlwaysVisibleScrollView { content() }
        #else
        ScrollView { content() }
        #endif
    }

    // MARK: - Import

    /// Load a plist exported by Apple's HUD panel (Shift-Fn-F12 -> Export).
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a plist exported from Apple's Metal HUD panel."
        if panel.runModal() == .OK, let url = panel.url {
            settings.importConfiguration(from: url)
        }
    }

    // MARK: - Preset Buttons
    private func presetButton(_ name: String, elements: [String]) -> some View {
        Button(name) {
            selectedPreset = name
            settings.selectedElements = Set(elements)
        }
        .buttonStyle(.borderless)
    }
}

#if os(macOS)
import AppKit

struct AlwaysVisibleScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hosting = nsView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }
}
#endif
