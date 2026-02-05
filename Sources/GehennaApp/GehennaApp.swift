import AppKit
import GehennaCore
import SwiftUI

enum AppSettingKey {
  static let startMinimized = "gehenna.startMinimized"
  static let autoStartDaemon = "gehenna.autoStartDaemon"
  static let closeToTray = "gehenna.closeToTray"
}

@MainActor
final class DaemonController: ObservableObject {
  static let shared = DaemonController()

  @Published var status = "Idle"
  @Published var isRunning = false
  @Published var logText = "Log output will appear here."

  @Published var startMinimized: Bool {
    didSet { UserDefaults.standard.set(startMinimized, forKey: AppSettingKey.startMinimized) }
  }
  @Published var autoStartDaemon: Bool {
    didSet { UserDefaults.standard.set(autoStartDaemon, forKey: AppSettingKey.autoStartDaemon) }
  }
  @Published var closeToTray: Bool {
    didSet { UserDefaults.standard.set(closeToTray, forKey: AppSettingKey.closeToTray) }
  }

  private var timer: Timer?

  private init() {
    startMinimized = UserDefaults.standard.bool(forKey: AppSettingKey.startMinimized)
    autoStartDaemon = UserDefaults.standard.bool(forKey: AppSettingKey.autoStartDaemon)
    closeToTray = UserDefaults.standard.bool(forKey: AppSettingKey.closeToTray)
  }

  func startAutoRefresh() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshStatus()
        self?.refreshLog()
      }
    }
  }

  func runSeizedDaemon() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-seize.sh")
    let process = Process()
    process.executableURL = scriptURL
    status = "Launching daemon..."
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self?.refreshStatus()
          self?.refreshLog()
        }
      } catch {
        DispatchQueue.main.async {
          self?.status = "Failed to start daemon: \(error.localizedDescription)"
        }
      }
    }
  }

  func stopDaemon() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-stop.sh")
    let process = Process()
    process.executableURL = scriptURL
    do {
      try process.run()
      status = "Stop signal sent."
      refreshStatus()
    } catch {
      status = "Failed to stop daemon: \(error.localizedDescription)"
    }
  }

  func refreshStatus() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "GehennaDaemon"]
    let output = Pipe()
    process.standardOutput = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let text = String(data: data, encoding: .utf8) ?? ""
      isRunning = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      status = isRunning ? "Running" : "Stopped"
    } catch {
      isRunning = false
      status = "Stopped"
    }
  }

  func refreshLog() {
    let logURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Gehenna/daemon.log")
    guard let data = try? Data(contentsOf: logURL),
          let text = String(data: data, encoding: .utf8) else {
      logText = "No log found yet."
      return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = lines.suffix(200).joined(separator: "\n")
    logText = tail
  }
}

struct ContentView: View {
  @ObservedObject private var controller = DaemonController.shared

  var body: some View {
    TabView {
      StatusView()
        .tabItem { Label("Status", systemImage: "waveform.path") }
      KeymapView()
        .tabItem { Label("Keymap", systemImage: "keyboard") }
      MacrosView()
        .tabItem { Label("Macros", systemImage: "bolt.horizontal") }
    }
    .frame(minWidth: 760, minHeight: 520)
    .onAppear {
      controller.startAutoRefresh()
    }
  }
}

struct StatusView: View {
  @ObservedObject private var controller = DaemonController.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      controls
      statusRow
      preferences
      logViewer
      Spacer()
    }
    .padding(24)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Gehenna")
        .font(.largeTitle)
        .bold()
      Text("Razer Tartarus Pro controller for macOS.")
        .foregroundStyle(.secondary)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Daemon Control")
        .font(.title2)
        .bold()
      HStack(spacing: 12) {
        Button("Start Seized Daemon") {
          controller.runSeizedDaemon()
        }
        Button("Stop Daemon") {
          controller.stopDaemon()
        }
        Button("Refresh Status") {
          controller.refreshStatus()
          controller.refreshLog()
        }
      }
    }
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(controller.isRunning ? Color.green : Color.red)
        .frame(width: 10, height: 10)
      Text("Status: \(controller.status)")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var preferences: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preferences")
        .font(.headline)
      Toggle("Start minimized", isOn: $controller.startMinimized)
      Toggle("Auto-start daemon on launch", isOn: $controller.autoStartDaemon)
      Toggle("Close button sends to tray", isOn: $controller.closeToTray)
    }
  }

  private var logViewer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Daemon Log")
        .font(.headline)
      ScrollView {
        Text(controller.logText)
          .font(.system(.footnote, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(Color(.textBackgroundColor))
          .cornerRadius(8)
      }
    }
  }
}

struct KeymapView: View {
  @State private var layoutRows: [[String]] = []
  @State private var labels: [String: String] = [:]
  @State private var status = "Not loaded"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Keymap")
        .font(.largeTitle)
        .bold()
      Text("Windows-style layout for the Tartarus Pro.")
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button("Load Default Layout") {
          loadMapping()
        }
        Text(status)
          .foregroundStyle(.secondary)
      }
      if layoutRows.isEmpty {
        Text("No layout loaded yet.")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(layoutRows.indices, id: \.self) { rowIndex in
            HStack(spacing: 8) {
              ForEach(layoutRows[rowIndex], id: \.self) { key in
                Text(labels[key] ?? key)
                  .frame(width: 90, height: 44)
                  .background(Color(.controlBackgroundColor))
                  .cornerRadius(8)
              }
            }
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear(perform: loadMapping)
  }

  private func loadMapping() {
    let loader = MappingLoader()
    let url = repoRoot().appendingPathComponent("configs/tartarus-pro.windows-default.json")
    do {
      let mapping = try loader.load(from: url)
      layoutRows = mapping.layout.rows
      labels = mapping.layout.labels
      status = "Loaded \(mapping.layout.name)"
    } catch {
      status = "Failed: \(error.localizedDescription)"
    }
  }
}

struct MacrosView: View {
  @State private var macros: [Macro] = []
  @State private var status = "Not loaded"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Macros")
        .font(.largeTitle)
        .bold()
      Text("Manage macro recordings and delays.")
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button("Reload Macros") {
          loadMacros()
        }
        Text(status)
          .foregroundStyle(.secondary)
      }
      if macros.isEmpty {
        Text("No macros defined yet.")
          .foregroundStyle(.secondary)
      } else {
        List(macros, id: \.id) { macro in
          VStack(alignment: .leading, spacing: 4) {
            Text(macro.name)
              .font(.headline)
            Text("\(macro.steps.count) steps")
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear(perform: loadMacros)
  }

  private func loadMacros() {
    let loader = MacroLibraryLoader()
    let url = repoRoot().appendingPathComponent("configs/macros.json")
    do {
      let library = try loader.load(from: url)
      macros = library.macros
      status = "Loaded \(library.macros.count) macros"
    } catch {
      status = "Failed: \(error.localizedDescription)"
    }
  }
}

private func repoRoot() -> URL {
  URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private let controller = DaemonController.shared

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.applyWindowBehavior()
    }
    if controller.autoStartDaemon {
      controller.runSeizedDaemon()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !controller.closeToTray
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if controller.closeToTray {
      sender.orderOut(nil)
      return false
    }
    return true
  }

  private func applyWindowBehavior() {
    guard let window = NSApplication.shared.windows.first else { return }
    window.delegate = self
    if controller.startMinimized {
      window.orderOut(nil)
    }
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Gehenna")
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Show Gehenna", action: #selector(showApp), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Start Daemon", action: #selector(startDaemon), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(stopDaemon), keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit Gehenna", action: #selector(quitApp), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }
    item.menu = menu
    statusItem = item
  }

  @objc private func showApp() {
    NSApp.activate(ignoringOtherApps: true)
    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
  }

  @objc private func startDaemon() {
    controller.runSeizedDaemon()
  }

  @objc private func stopDaemon() {
    controller.stopDaemon()
  }

  @objc private func quitApp() {
    controller.stopDaemon()
    NSApplication.shared.terminate(nil)
  }
}

@main
struct GehennaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
