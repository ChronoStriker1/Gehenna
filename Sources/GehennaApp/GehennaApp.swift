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
  @Published var currentLayer = 1
  @Published var deviceConnected = false
  @Published var lastEvent: String? = nil
  @Published var profileName: String? = nil

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

  func restartDaemon() {
    stopDaemon()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.runSeizedDaemon()
    }
  }

  func reloadConfigs() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-reload.sh")
    let process = Process()
    process.executableURL = scriptURL
    do {
      try process.run()
      status = "Reload signal sent."
    } catch {
      status = "Failed to reload: \(error.localizedDescription)"
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

    let statusURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Gehenna/status.json")
    if let data = try? Data(contentsOf: statusURL),
       let decoded = try? JSONDecoder().decode(DaemonStatus.self, from: data) {
      currentLayer = decoded.layer
      deviceConnected = decoded.connected
      lastEvent = decoded.lastEvent
      profileName = decoded.profileName
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

  func clearLog() {
    let logURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Gehenna/daemon.log")
    do {
      try Data().write(to: logURL, options: .atomic)
      logText = ""
      status = "Log cleared."
    } catch {
      status = "Failed to clear log: \(error.localizedDescription)"
    }
  }
}

struct DaemonStatus: Codable {
  let pid: Int
  let deviceName: String
  let connected: Bool
  let layer: Int
  let layerModifier: Bool
  let profileName: String?
  let lastEvent: String?
  let updatedAt: String
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
      deviceRow
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
        Button("Reload Configs") {
          controller.reloadConfigs()
        }
        Button("Clear Log") {
          controller.clearLog()
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

  private var deviceRow: some View {
    HStack(spacing: 12) {
      Text("Device: \(controller.deviceConnected ? "Connected" : "Disconnected")")
      Text("Layer: \(controller.currentLayer)")
      if let profile = controller.profileName {
        Text("Profile: \(profile)")
      }
      if let lastEvent = controller.lastEvent {
        Text("Last: \(lastEvent)")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private var preferences: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preferences")
        .font(.headline)
      Toggle("Start in system tray", isOn: $controller.startMinimized)
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
  @State private var mappingStatus = "Not loaded"
  @State private var profilesStatus = "Not loaded"
  @State private var profilesConfig: ProfilesConfig?
  @State private var selectedProfileId: UUID?
  @State private var selectedLayer = "1"
  @State private var editingKeyId: String?
  @State private var editingAction: Action?
  @State private var showEditor = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Keymap")
        .font(.largeTitle)
        .bold()
      Text("Windows-style layout for the Tartarus Pro.")
        .foregroundStyle(.secondary)
      controls
      if layoutRows.isEmpty {
        Text("No layout loaded yet.")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(layoutRows.indices, id: \.self) { rowIndex in
            HStack(spacing: 8) {
              ForEach(layoutRows[rowIndex], id: \.self) { key in
                let actionLabel = actionDescription(for: key)
                Button {
                  beginEdit(keyId: key)
                } label: {
                  VStack(spacing: 4) {
                    Text(labels[key] ?? key)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Text(actionLabel)
                      .font(.callout)
                      .lineLimit(1)
                  }
                  .frame(width: 110, height: 54)
                  .background(Color(.controlBackgroundColor))
                  .cornerRadius(8)
                }
              }
            }
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear {
      loadMapping()
      loadProfiles()
    }
    .sheet(isPresented: $showEditor) {
      if let keyId = editingKeyId {
        KeyActionEditor(
          keyId: keyId,
          action: editingAction,
          onSave: { newAction in
            applyAction(newAction, for: keyId)
          },
          onCancel: {
            showEditor = false
          }
        )
      }
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button("Load Default Layout") {
          loadMapping()
        }
        Button("Reload Profiles") {
          loadProfiles()
        }
        Text(mappingStatus)
          .foregroundStyle(.secondary)
        Text(profilesStatus)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        Picker("Profile", selection: $selectedProfileId) {
          ForEach(profilesConfig?.profiles ?? [], id: \.id) { profile in
            Text(profile.name).tag(Optional(profile.id))
          }
        }
        .frame(width: 220)
        Picker("Layer", selection: $selectedLayer) {
          Text("1").tag("1")
          Text("2").tag("2")
          Text("3").tag("3")
        }
        .frame(width: 120)
        Button("Set Active") {
          setActiveProfile()
        }
      }
      let count = profilesConfig?.profiles.count ?? 0
      Text("Profiles: \(count)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func loadMapping() {
    let loader = MappingLoader()
    let url = repoRoot().appendingPathComponent("configs/tartarus-pro.windows-default.json")
    do {
      let mapping = try loader.load(from: url)
      layoutRows = mapping.layout.rows
      labels = mapping.layout.labels
      mappingStatus = "Mapping: \(mapping.layout.name)"
    } catch {
      mappingStatus = "Mapping error: \(error.localizedDescription)"
    }
  }

  private func loadProfiles() {
    let loader = ProfilesLoader()
    let url = profilesURL()
    let resolved = ensureProfilesFile(at: url)
    do {
      let config = try loader.load(from: resolved)
      profilesConfig = config
      if selectedProfileId == nil {
        selectedProfileId = config.activeProfileId ?? config.profiles.first?.id
      }
      profilesStatus = "Profiles: loaded"
    } catch {
      profilesStatus = "Profiles error: \(error.localizedDescription)"
    }
  }

  private func profilesURL() -> URL {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
        .appendingPathComponent("profiles.json")
      return path
    }
    return repoRoot().appendingPathComponent("configs/profiles.json")
  }

  private func ensureProfilesFile(at url: URL) -> URL {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      return url
    }
    let fallback = repoRoot().appendingPathComponent("configs/profiles.json")
    if fm.fileExists(atPath: fallback.path) {
      if url.path != fallback.path {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
          try? fm.copyItem(at: fallback, to: url)
        }
        if fm.fileExists(atPath: url.path) {
          return url
        }
      }
      return fallback
    }
    return url
  }

  private func writeProfiles(_ config: ProfilesConfig) {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let base = appSupport?.appendingPathComponent("Gehenna", isDirectory: true)
    if let base {
      try? fm.createDirectory(at: base, withIntermediateDirectories: true)
      let url = base.appendingPathComponent("profiles.json")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
      if let data = try? encoder.encode(config) {
        try? data.write(to: url, options: .atomic)
    profilesStatus = "Profiles: saved"
        return
      }
    }
    let fallback = repoRoot().appendingPathComponent("configs/profiles.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? encoder.encode(config) {
      try? data.write(to: fallback, options: .atomic)
      profilesStatus = "Profiles: saved (fallback)"
    }
  }

  private func currentProfile() -> LayeredProfile? {
    guard let config = profilesConfig else { return nil }
    if let id = selectedProfileId {
      return config.profiles.first { $0.id == id }
    }
    return config.profiles.first
  }

  private func actionDescription(for keyId: String) -> String {
    guard let profile = currentProfile(),
          let layer = profile.layers[selectedLayer],
          let action = layer[keyId] else {
      return "Unassigned"
    }
    switch action.type {
    case .disabled:
      return "Disabled"
    case .key:
      let mods = action.modifiers?.map { $0.rawValue }.joined(separator: "+") ?? ""
      let code = action.keyCode ?? 0
      if mods.isEmpty {
        return "Key \(code)"
      }
      return "\(mods)+\(code)"
    case .macro:
      return "Macro"
    }
  }

  private func beginEdit(keyId: String) {
    editingKeyId = keyId
    if let profile = currentProfile(),
       let layer = profile.layers[selectedLayer],
       let action = layer[keyId] {
      editingAction = action
    } else {
      editingAction = Action(type: .disabled)
    }
    showEditor = true
  }

  private func applyAction(_ action: Action, for keyId: String) {
    guard var config = profilesConfig,
          let profileIndex = config.profiles.firstIndex(where: { $0.id == selectedProfileId }) else {
      return
    }
    var profile = config.profiles[profileIndex]
    var layer = profile.layers[selectedLayer] ?? [:]
    layer[keyId] = action
    var layers = profile.layers
    layers[selectedLayer] = layer
    profile = LayeredProfile(
      id: profile.id,
      name: profile.name,
      perAppBundleId: profile.perAppBundleId,
      layers: layers
    )
    var profiles = config.profiles
    profiles[profileIndex] = profile
    config = ProfilesConfig(version: config.version, activeProfileId: config.activeProfileId, profiles: profiles)
    profilesConfig = config
    writeProfiles(config)
    DaemonController.shared.reloadConfigs()
    showEditor = false
  }

  private func setActiveProfile() {
    guard var config = profilesConfig, let selectedProfileId else { return }
    config = ProfilesConfig(version: config.version, activeProfileId: selectedProfileId, profiles: config.profiles)
    profilesConfig = config
    writeProfiles(config)
    DaemonController.shared.reloadConfigs()
    profilesStatus = "Profiles: active updated"
  }
}

struct KeyActionEditor: View {
  let keyId: String
  @State private var actionType: ActionType
  @State private var keyCodeText: String
  @State private var modifiers: Set<HIDModifier>
  let onSave: (Action) -> Void
  let onCancel: () -> Void

  init(
    keyId: String,
    action: Action?,
    onSave: @escaping (Action) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.keyId = keyId
    _actionType = State(initialValue: action?.type ?? .disabled)
    _keyCodeText = State(initialValue: action?.keyCode.map(String.init) ?? "")
    _modifiers = State(initialValue: Set(action?.modifiers ?? []))
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Edit \(keyId)")
        .font(.title2)
        .bold()
      Picker("Action", selection: $actionType) {
        Text("Key").tag(ActionType.key)
        Text("Disabled").tag(ActionType.disabled)
      }
      .pickerStyle(.segmented)

      if actionType == .key {
        TextField("Key code (HID usage)", text: $keyCodeText)
          .textFieldStyle(.roundedBorder)
        Text("Modifiers")
          .font(.headline)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(HIDModifier.allCases, id: \.self) { modifier in
            Toggle(modifier.rawValue, isOn: Binding(
              get: { modifiers.contains(modifier) },
              set: { isOn in
                if isOn {
                  modifiers.insert(modifier)
                } else {
                  modifiers.remove(modifier)
                }
              }
            ))
          }
        }
      }

      HStack(spacing: 12) {
        Button("Save") {
          let action: Action
          switch actionType {
          case .disabled:
            action = Action(type: .disabled)
          case .key:
            let code = Int(keyCodeText) ?? 0
            action = Action(type: .key, keyCode: code, modifiers: Array(modifiers))
          case .macro:
            action = Action(type: .macro)
          }
          onSave(action)
        }
        Button("Cancel") {
          onCancel()
        }
      }
      Spacer()
    }
    .padding(24)
    .frame(minWidth: 420, minHeight: 360)
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
  private var statusMenuItem: NSMenuItem?
  private var profileMenuItem: NSMenuItem?
  private let controller = DaemonController.shared
  private var menuTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.applyWindowBehavior()
    }
    if controller.autoStartDaemon {
      controller.runSeizedDaemon()
    }
    menuTimer?.invalidate()
    menuTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshMenuStatus()
      }
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
    if let image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Gehenna") {
      image.isTemplate = true
      item.button?.image = image
    } else {
      item.button?.title = "G"
    }
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Show Gehenna", action: #selector(showApp), keyEquivalent: ""))
    let statusMenu = NSMenuItem(title: "Status: Unknown", action: nil, keyEquivalent: "")
    statusMenu.isEnabled = false
    let profileItem = NSMenuItem(title: "Profile: Unknown", action: nil, keyEquivalent: "")
    profileItem.isEnabled = false
    menu.addItem(statusMenu)
    menu.addItem(profileItem)
    menu.addItem(NSMenuItem(title: "Start Daemon", action: #selector(startDaemon), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(stopDaemon), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Reload Configs", action: #selector(reloadConfigs), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Restart Daemon", action: #selector(restartDaemon), keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit Gehenna", action: #selector(quitApp), keyEquivalent: "q"))
    menu.items.forEach { $0.target = self }
    item.menu = menu
    statusItem = item
    statusMenuItem = statusMenu
    profileMenuItem = profileItem
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

  @objc private func restartDaemon() {
    controller.restartDaemon()
  }

  @objc private func reloadConfigs() {
    controller.reloadConfigs()
  }

  @objc private func quitApp() {
    controller.stopDaemon()
    NSApplication.shared.terminate(nil)
  }

  private func refreshMenuStatus() {
    controller.refreshStatus()
    let statusText = controller.isRunning ? "Running" : "Stopped"
    statusMenuItem?.title = "Status: \(statusText) • Layer \(controller.currentLayer)"
    if let profile = controller.profileName {
      profileMenuItem?.title = "Profile: \(profile)"
    } else {
      profileMenuItem?.title = "Profile: (none)"
    }
    updateStatusIcon(isRunning: controller.isRunning)
  }

  private func updateStatusIcon(isRunning: Bool) {
    let symbolName = isRunning ? "square.grid.3x3.fill" : "square.grid.3x3"
    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Gehenna") {
      image.isTemplate = true
      statusItem?.button?.image = image
      statusItem?.button?.title = ""
    } else {
      statusItem?.button?.title = "G"
    }
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
