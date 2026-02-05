import AppKit
import GehennaCore
import SwiftUI
import Darwin

enum AppSettingKey {
  static let startMinimized = "gehenna.startMinimized"
  static let autoStartDaemon = "gehenna.autoStartDaemon"
  static let closeToTray = "gehenna.closeToTray"
  static let logInputEvents = "gehenna.logInputEvents"
}

enum AppInfo {
  static let version = "0.5.0"
}

struct ActiveAppMessage: Codable {
  let bundleId: String
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
  @Published var activeBundleId: String? = nil
  @Published var activeAppStatus: String? = nil
  @Published var showKeymapPopup = false

  private var lastExternalBundleId: String? = nil
  private var workspaceObserver: NSObjectProtocol? = nil
  private var statusReader: DispatchSourceRead? = nil
  private var statusSocketFd: Int32? = nil
  private var lastKeymapPopupToken = 0

  @Published var startMinimized: Bool {
    didSet { UserDefaults.standard.set(startMinimized, forKey: AppSettingKey.startMinimized) }
  }
  @Published var autoStartDaemon: Bool {
    didSet { UserDefaults.standard.set(autoStartDaemon, forKey: AppSettingKey.autoStartDaemon) }
  }
  @Published var closeToTray: Bool {
    didSet { UserDefaults.standard.set(closeToTray, forKey: AppSettingKey.closeToTray) }
  }
  @Published var logInputEvents: Bool {
    didSet { UserDefaults.standard.set(logInputEvents, forKey: AppSettingKey.logInputEvents) }
  }

  private var timer: Timer?

  private init() {
    startMinimized = UserDefaults.standard.bool(forKey: AppSettingKey.startMinimized)
    autoStartDaemon = UserDefaults.standard.bool(forKey: AppSettingKey.autoStartDaemon)
    closeToTray = UserDefaults.standard.bool(forKey: AppSettingKey.closeToTray)
    logInputEvents = UserDefaults.standard.bool(forKey: AppSettingKey.logInputEvents)
  }

  func startAutoRefresh() {
    if workspaceObserver == nil {
      let center = NSWorkspace.shared.notificationCenter
      workspaceObserver = center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
          return
        }
        if bundleId != Bundle.main.bundleIdentifier {
          Task { @MainActor in
            self?.lastExternalBundleId = bundleId
            self?.writeActiveBundleId(bundleId)
          }
        }
      }
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshLog()
        self?.updateActiveBundleId()
      }
    }
    startStatusSocket()
  }

  func runSeizedDaemon() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-seize.sh")
    let process = Process()
    process.executableURL = scriptURL
    var env = ProcessInfo.processInfo.environment
    env["GEHENNA_LOG_INPUT"] = logInputEvents ? "1" : "0"
    process.environment = env
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

    // status fields update via socket
    if isRunning {
      startStatusSocket()
    } else {
      resetStatusSocket()
    }
  }

  private func statusSocketPath() -> String {
    "/var/tmp/gehenna-status-\(getuid()).sock"
  }

  private func startStatusSocket() {
    guard statusReader == nil else { return }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    statusSocketFd = fd

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = statusSocketPath()
    let pathBytes = Array(path.utf8CString)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let copyLen = min(pathBytes.count, maxLen)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: copyLen) { buf in
        pathBytes.withUnsafeBytes { bytes in
          memcpy(buf, bytes.baseAddress, copyLen)
        }
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      close(fd)
      statusSocketFd = nil
      return
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.main)
    var buffer = Data()
    source.setEventHandler { [weak self] in
      var temp = [UInt8](repeating: 0, count: 4096)
      let count = read(fd, &temp, temp.count)
      if count <= 0 {
        self?.resetStatusSocket()
        return
      }
      buffer.append(contentsOf: temp.prefix(count))
      while buffer.count >= 4 {
        let lengthData = buffer.prefix(4)
        let length = lengthData.withUnsafeBytes { ptr -> UInt32 in
          let value = ptr.load(as: UInt32.self)
          return UInt32(bigEndian: value)
        }
        let total = 4 + Int(length)
        if buffer.count < total {
          break
        }
        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        if let decoded = try? JSONDecoder().decode(DaemonStatus.self, from: payload) {
          self?.applyStatus(decoded)
        }
      }
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    statusReader = source
  }

  @MainActor
  private func applyStatus(_ decoded: DaemonStatus) {
    currentLayer = decoded.layer
    deviceConnected = decoded.connected
    lastEvent = decoded.lastEvent
    profileName = decoded.profileName
    showKeymapPopup = decoded.keymapPopupVisible
    if let token = decoded.keymapPopupToken, token > lastKeymapPopupToken {
      lastKeymapPopupToken = token
    }
  }

  @MainActor
  private func resetStatusSocket() {
    statusReader?.cancel()
    statusReader = nil
    if let fd = statusSocketFd {
      close(fd)
    }
    statusSocketFd = nil
  }

  func updateActiveBundleId() {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      activeAppStatus = "Active app unavailable."
      return
    }
    var bundleId = app.bundleIdentifier
    if bundleId == nil, let url = app.bundleURL, let bundle = Bundle(url: url) {
      bundleId = bundle.bundleIdentifier
    }
    let ownBundleId = Bundle.main.bundleIdentifier
    var resolvedId = bundleId
    if resolvedId == ownBundleId {
      if let lastExternalBundleId {
        resolvedId = lastExternalBundleId
      } else {
        activeAppStatus = "Active app is Gehenna. Waiting for external app."
        return
      }
    }
    guard let resolvedId else {
      activeAppStatus = "Active app has no bundle id."
      return
    }
    writeActiveBundleId(resolvedId)
  }

  private func writeActiveBundleId(_ bundleId: String) {
    sendActiveBundleId(bundleId)
  }

  private func activeAppSocketPath() -> String {
    "/var/tmp/gehenna-active-app-\(getuid()).sock"
  }

  private func sendActiveBundleId(_ bundleId: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      activeAppStatus = "Active app socket failed."
      return
    }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = activeAppSocketPath()
    let pathBytes = Array(path.utf8CString)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let copyLen = min(pathBytes.count, maxLen)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: copyLen) { buf in
        pathBytes.withUnsafeBytes { bytes in
          memcpy(buf, bytes.baseAddress, copyLen)
        }
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      close(fd)
      activeAppStatus = "Daemon not running."
      return
    }

    let message = ActiveAppMessage(bundleId: bundleId)
    guard let data = try? JSONEncoder().encode(message) else {
      close(fd)
      activeAppStatus = "Failed to encode bundle id."
      return
    }
    _ = data.withUnsafeBytes { ptr in
      write(fd, ptr.baseAddress, data.count)
    }
    close(fd)
    activeBundleId = bundleId
    activeAppStatus = "Active app sent."
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
  let bundleId: String?
  let lastEvent: String?
  let keymapPopupToken: Int?
  let keymapPopupVisible: Bool
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
    .frame(minWidth: 980, minHeight: 680)
    .onAppear {
      controller.startAutoRefresh()
    }
    .onChange(of: controller.showKeymapPopup) { visible in
      if visible {
        KeymapPopupWindowController.shared.show()
      } else {
        KeymapPopupWindowController.shared.hide()
      }
    }
  }
}

@MainActor
final class KeymapPopupWindowController {
  static let shared = KeymapPopupWindowController()

  private var panel: NSPanel?
  private var hostingView: NSHostingView<KeymapPopupView>?

  private init() {}

  func show() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let maxWidth = min(920, screen.visibleFrame.width - 80)
    let maxHeight = min(620, screen.visibleFrame.height - 80)
    let contentRect = NSRect(x: 0, y: 0, width: maxWidth, height: maxHeight)

    if panel == nil {
      let panel = NSPanel(
        contentRect: contentRect,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = true
      panel.hidesOnDeactivate = false
      panel.ignoresMouseEvents = true

      let host = NSHostingView(rootView: KeymapPopupView(maxWidth: maxWidth, maxHeight: maxHeight))
      let fitting = host.fittingSize
      let width = min(fitting.width, maxWidth)
      let height = min(fitting.height, maxHeight)
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      panel.contentView = host
      self.panel = panel
      self.hostingView = host
    } else {
      hostingView?.rootView = KeymapPopupView(maxWidth: maxWidth, maxHeight: maxHeight)
      if let host = hostingView {
        let fitting = host.fittingSize
        let width = min(fitting.width, maxWidth)
        let height = min(fitting.height, maxHeight)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel?.setContentSize(NSSize(width: width, height: height))
      } else {
        panel?.setContentSize(NSSize(width: maxWidth, height: maxHeight))
      }
    }

    if let panel = panel {
      panel.center()
      panel.orderFrontRegardless()
    }
  }

  func hide() {
    panel?.orderOut(nil)
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
      Text("Version \(AppInfo.version)")
        .font(.footnote)
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
      VStack(alignment: .leading, spacing: 4) {
        Text("Device: \(controller.deviceConnected ? "Connected" : "Disconnected")")
        Text("Layer: \(controller.currentLayer)")
        if let profile = controller.profileName {
          Text("Profile: \(profile)")
        }
        if let lastEvent = controller.lastEvent {
          Text("Last: \(lastEvent)")
        }
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text("Active App")
        if let bundleId = controller.activeBundleId {
          Text(bundleId)
        } else {
          Text("Unknown")
        }
        if let status = controller.activeAppStatus {
          Text(status)
        }
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
      Toggle("Log input events in console", isOn: $controller.logInputEvents)
    }
  }

  private var logViewer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Daemon Log")
          .font(.headline)
        Spacer()
        Button("Copy") {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(controller.logText, forType: .string)
          controller.status = "Log copied to clipboard."
        }
      }
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
  @ObservedObject private var controller = DaemonController.shared
  @State private var layoutRows: [[String]] = []
  @State private var labels: [String: String] = [:]
  @State private var mappingStatus = "Not loaded"
  @State private var profilesStatus = "Not loaded"
  @State private var profilesConfig: ProfilesConfig?
  @State private var macrosLookup: [UUID: Macro] = [:]
  @State private var selectedProfileId: UUID?
  @State private var selectedLayer = "1"
  @State private var editingKeyId: String?
  @State private var editingAction: Action?
  @State private var showEditor = false
  @State private var perAppBundleId = ""
  @State private var perAppStatus: String? = nil
  @State private var showCreateProfile = false
  @State private var newProfileName = ""
  @State private var newProfileBundleId = ""
  @State private var newProfileCloneSelected = true
  @State private var selectedDpadMode: DPadMode = .fourWay

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
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(layoutRows.indices, id: \.self) { rowIndex in
              HStack(spacing: 8) {
                ForEach(layoutRows[rowIndex], id: \.self) { key in
                  keyButton(keyId: key, width: 110, height: 54)
                }
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("D-Pad")
              .font(.headline)
            dpadGrid()
            Text("Wheel")
              .font(.headline)
            extraInputButton(keyId: "wheel.scroll")
            extraInputButton(keyId: "wheel.up")
            extraInputButton(keyId: "wheel.down")
            extraInputButton(keyId: "wheel.click")
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear {
      loadMapping()
      loadProfiles()
      loadMacros()
      syncPerAppBundleId()
      syncDpadMode()
    }
    .onChange(of: selectedProfileId) { _ in
      syncPerAppBundleId()
      syncDpadMode()
    }
    .sheet(isPresented: $showEditor) {
      if let keyId = editingKeyId {
        KeyActionEditor(
          keyId: keyId,
          action: editingAction,
          macros: Array(macrosLookup.values).sorted { $0.name < $1.name },
          onSave: { newAction in
            applyAction(newAction, for: keyId)
          },
          onCancel: {
            showEditor = false
          }
        )
      }
    }
    .sheet(isPresented: $showCreateProfile) {
      VStack(alignment: .leading, spacing: 12) {
        Text("New Profile")
          .font(.headline)
        TextField("Profile name", text: $newProfileName)
          .textFieldStyle(.roundedBorder)
        TextField("Per-app bundle id (optional)", text: $newProfileBundleId)
          .textFieldStyle(.roundedBorder)
        HStack(spacing: 12) {
          Toggle("Clone from selected profile", isOn: $newProfileCloneSelected)
        }
        HStack(spacing: 12) {
          Button("Use Active App") {
            if let bundleId = controller.activeBundleId {
              newProfileBundleId = bundleId
            }
          }
          Spacer()
          Button("Cancel") {
            showCreateProfile = false
          }
          Button("Create") {
            createProfile()
            showCreateProfile = false
          }
          .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(20)
      .frame(width: 420)
    }
  }

  private func keyButton(keyId: String, width: CGFloat, height: CGFloat) -> some View {
    let actionLabel = actionDescription(for: keyId)
    return Button {
      beginEdit(keyId: keyId)
    } label: {
      VStack(spacing: 4) {
        Text(labels[keyId] ?? keyId)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(actionLabel)
          .font(.callout)
          .lineLimit(1)
      }
      .frame(width: width, height: height)
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
    }
  }

  private func extraInputButton(keyId: String) -> some View {
    let actionLabel = actionDescription(for: keyId)
    return Button {
      beginEdit(keyId: keyId)
    } label: {
      HStack {
        Text(extraInputLabel(keyId))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(actionLabel)
          .font(.callout)
          .lineLimit(1)
      }
      .frame(minWidth: 200, minHeight: 40, alignment: .leading)
      .padding(.horizontal, 10)
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
    }
  }

  private func dpadGrid() -> some View {
    let showDiagonals = selectedDpadMode == .eightWay
    let rows: [[String?]] = [
      [showDiagonals ? "dpad.up_left" : nil, "dpad.up", showDiagonals ? "dpad.up_right" : nil],
      ["dpad.left", nil, "dpad.right"],
      [showDiagonals ? "dpad.down_left" : nil, "dpad.down", showDiagonals ? "dpad.down_right" : nil]
    ]
    return VStack(spacing: 8) {
      ForEach(0..<rows.count, id: \.self) { row in
        HStack(spacing: 8) {
          ForEach(0..<rows[row].count, id: \.self) { col in
            if let keyId = rows[row][col] {
              keyButton(keyId: keyId, width: 86, height: 50)
            } else {
              Color.clear.frame(width: 86, height: 50)
            }
          }
        }
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
        Button("Reload Macros") {
          loadMacros()
        }
        Button("New Profile") {
          newProfileName = ""
          newProfileBundleId = ""
          newProfileCloneSelected = true
          showCreateProfile = true
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
      HStack(spacing: 12) {
        Text("D-Pad")
        Picker("D-Pad", selection: $selectedDpadMode) {
          Text("4-way").tag(DPadMode.fourWay)
          Text("8-way").tag(DPadMode.eightWay)
        }
        .frame(width: 140)
        Button("Save D-Pad") {
          updateDpadMode()
        }
      }
      HStack(spacing: 12) {
        Text("Per-App Bundle ID")
        TextField("com.adobe.Photoshop", text: $perAppBundleId)
          .textFieldStyle(.roundedBorder)
          .frame(width: 260)
        Button("Use Active App") {
          if let bundleId = controller.activeBundleId {
            perAppBundleId = bundleId
            perAppStatus = "Using active app."
          } else {
            perAppStatus = "No active app detected."
          }
        }
        Button("Clear") {
          perAppBundleId = ""
          perAppStatus = "Cleared."
        }
        Button("Save App Link") {
          updatePerAppBundleId()
        }
      }
      if let status = perAppStatus {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
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
      syncPerAppBundleId()
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

  private func syncPerAppBundleId() {
    guard let profile = currentProfile() else {
      perAppBundleId = ""
      return
    }
    perAppBundleId = profile.perAppBundleId ?? ""
  }

  private func syncDpadMode() {
    guard let profile = currentProfile() else {
      selectedDpadMode = .fourWay
      return
    }
    selectedDpadMode = profile.dpadMode ?? .fourWay
  }

  private func updatePerAppBundleId() {
    guard var config = profilesConfig,
          let selected = selectedProfileId else {
      return
    }
    let trimmed = perAppBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    let newValue = trimmed.isEmpty ? nil : trimmed
    let updated = config.profiles.map { profile -> LayeredProfile in
      guard profile.id == selected else { return profile }
      return LayeredProfile(
        id: profile.id,
        name: profile.name,
        perAppBundleId: newValue,
        dpadMode: profile.dpadMode,
        layers: profile.layers
      )
    }
    config = ProfilesConfig(
      version: config.version,
      activeProfileId: config.activeProfileId,
      profiles: updated
    )
    profilesConfig = config
    writeProfiles(config)
    profilesStatus = "Profiles: app link saved"
    perAppStatus = "Saved per-app bundle id."
    controller.reloadConfigs()
  }

  private func updateDpadMode() {
    guard var config = profilesConfig,
          let selected = selectedProfileId else {
      return
    }
    let updated = config.profiles.map { profile -> LayeredProfile in
      guard profile.id == selected else { return profile }
      return LayeredProfile(
        id: profile.id,
        name: profile.name,
        perAppBundleId: profile.perAppBundleId,
        dpadMode: selectedDpadMode,
        layers: profile.layers
      )
    }
    config = ProfilesConfig(
      version: config.version,
      activeProfileId: config.activeProfileId,
      profiles: updated
    )
    profilesConfig = config
    writeProfiles(config)
    profilesStatus = "Profiles: D-Pad saved"
    controller.reloadConfigs()
  }

  private func createProfile() {
    guard var config = profilesConfig else { return }
    let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let bundleTrimmed = newProfileBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
    let bundle = bundleTrimmed.isEmpty ? nil : bundleTrimmed

    let sourceProfile: LayeredProfile? = {
      if newProfileCloneSelected, let selected = selectedProfileId {
        return config.profiles.first { $0.id == selected }
      }
      return config.profiles.first { $0.name == "Default" } ?? config.profiles.first
    }()

    guard let source = sourceProfile else { return }
    let newProfile = LayeredProfile(
      id: UUID(),
      name: name,
      perAppBundleId: bundle,
      dpadMode: selectedDpadMode,
      layers: source.layers
    )
    config = ProfilesConfig(
      version: config.version,
      activeProfileId: config.activeProfileId,
      profiles: config.profiles + [newProfile]
    )
    profilesConfig = config
    writeProfiles(config)
    selectedProfileId = newProfile.id
    profilesStatus = "Profiles: created"
    controller.reloadConfigs()
  }

  private func loadMacros() {
    let loader = MacroLibraryLoader()
    let url = macrosURL()
    do {
      let library = try loader.load(from: url)
      macrosLookup = Dictionary(uniqueKeysWithValues: library.macros.map { ($0.id, $0) })
    } catch {
      // leave lookup empty if missing
    }
  }

  private func macrosURL() -> URL {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
        .appendingPathComponent("macros.json")
      if fm.fileExists(atPath: path.path) {
        return path
      }
    }
    return repoRoot().appendingPathComponent("configs/macros.json")
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
      if let macroId = action.macroId, let macro = macrosLookup[macroId] {
        return "Macro: \(macro.name)"
      }
      return "Macro"
    case .scroll:
      let mult = action.scrollMultiplier ?? 1
      return "Scroll x\(mult)"
    }
  }

  private var extraInputs: [String] {
    let diagonals: [String] = {
      if selectedDpadMode == .eightWay {
        return ["dpad.up_left", "dpad.up_right", "dpad.down_left", "dpad.down_right"]
      }
      return []
    }()
    return [
      "dpad.up",
      "dpad.down",
      "dpad.left",
      "dpad.right",
    ] + diagonals + [
      "wheel.scroll",
      "wheel.up",
      "wheel.down",
      "wheel.click",
    ]
  }

  private func extraInputLabel(_ keyId: String) -> String {
    switch keyId {
    case "dpad.up": return "D-Pad Up"
    case "dpad.down": return "D-Pad Down"
    case "dpad.left": return "D-Pad Left"
    case "dpad.right": return "D-Pad Right"
    case "dpad.up_left": return "D-Pad Up-Left"
    case "dpad.up_right": return "D-Pad Up-Right"
    case "dpad.down_left": return "D-Pad Down-Left"
    case "dpad.down_right": return "D-Pad Down-Right"
    case "wheel.scroll": return "Wheel Scroll"
    case "wheel.up": return "Wheel Up"
    case "wheel.down": return "Wheel Down"
    case "wheel.click": return "Wheel Click"
    default: return keyId
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
      dpadMode: profile.dpadMode,
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

struct KeymapPopupView: View {
  let maxWidth: CGFloat
  let maxHeight: CGFloat
  @ObservedObject private var controller = DaemonController.shared
  @State private var layoutRows: [[String]] = []
  @State private var labels: [String: String] = [:]
  @State private var profilesConfig: ProfilesConfig?
  @State private var macrosLookup: [UUID: Macro] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Keymap")
          .font(.title2)
          .bold()
      }
      Text("Profile: \(currentProfile()?.name ?? "Unknown") • Layer \(controller.currentLayer)")
        .foregroundStyle(.secondary)
      if layoutRows.isEmpty {
        Text("No layout loaded.")
          .foregroundStyle(.secondary)
      } else {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(layoutRows.indices, id: \.self) { rowIndex in
              HStack(spacing: 8) {
                ForEach(layoutRows[rowIndex], id: \.self) { key in
                  popupKeyCell(keyId: key)
                }
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("D-Pad")
              .font(.headline)
            popupDpadGrid(showDiagonals: popupShowDiagonals)
            Text("Wheel")
              .font(.headline)
            popupExtraCell(keyId: "wheel.scroll")
            popupExtraCell(keyId: "wheel.up")
            popupExtraCell(keyId: "wheel.down")
            popupExtraCell(keyId: "wheel.click")
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    )
    .onAppear {
      loadMapping()
      loadProfiles()
      loadMacros()
    }
  }

  private func loadMapping() {
    let loader = MappingLoader()
    let url = repoRoot().appendingPathComponent("configs/tartarus-pro.windows-default.json")
    if let mapping = try? loader.load(from: url) {
      layoutRows = mapping.layout.rows
      labels = mapping.layout.labels
    }
  }

  private func popupKeyCell(keyId: String, width: CGFloat = 110, height: CGFloat? = nil) -> some View {
    let actionLabel = actionDescription(for: keyId)
    return VStack(spacing: 4) {
      Text(labels[keyId] ?? keyId)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(actionLabel)
        .font(.footnote)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: width, height: height)
    .padding(.vertical, 6)
    .background(Color(.windowBackgroundColor).opacity(0.6))
    .cornerRadius(8)
  }

  private func popupExtraCell(keyId: String) -> some View {
    let actionLabel = actionDescription(for: keyId)
    return HStack {
      Text(extraInputLabel(keyId))
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(actionLabel)
        .font(.footnote)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(minWidth: 200, alignment: .leading)
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(Color(.windowBackgroundColor).opacity(0.6))
    .cornerRadius(8)
  }

  private var popupShowDiagonals: Bool {
    return currentProfile()?.dpadMode == .eightWay
  }

  private func popupDpadGrid(showDiagonals: Bool) -> some View {
    let rows: [[String?]] = [
      [showDiagonals ? "dpad.up_left" : nil, "dpad.up", showDiagonals ? "dpad.up_right" : nil],
      ["dpad.left", nil, "dpad.right"],
      [showDiagonals ? "dpad.down_left" : nil, "dpad.down", showDiagonals ? "dpad.down_right" : nil]
    ]
    return VStack(spacing: 8) {
      ForEach(0..<rows.count, id: \.self) { row in
        HStack(spacing: 8) {
          ForEach(0..<rows[row].count, id: \.self) { col in
            if let keyId = rows[row][col] {
              popupKeyCell(keyId: keyId, width: 86, height: 50)
            } else {
              Color.clear.frame(width: 86, height: 50)
            }
          }
        }
      }
    }
  }

  private func loadProfiles() {
    let loader = ProfilesLoader()
    let url = profilesURL()
    let resolved = ensureProfilesFile(at: url)
    profilesConfig = try? loader.load(from: resolved)
  }

  private func loadMacros() {
    let loader = MacroLibraryLoader()
    let url = macrosURL()
    if let library = try? loader.load(from: url) {
      macrosLookup = Dictionary(uniqueKeysWithValues: library.macros.map { ($0.id, $0) })
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

  private func macrosURL() -> URL {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
        .appendingPathComponent("macros.json")
      if fm.fileExists(atPath: path.path) {
        return path
      }
    }
    return repoRoot().appendingPathComponent("configs/macros.json")
  }

  private func currentProfile() -> LayeredProfile? {
    guard let config = profilesConfig else { return nil }
    if let name = controller.profileName,
       let match = config.profiles.first(where: { $0.name == name }) {
      return match
    }
    if let activeId = config.activeProfileId,
       let active = config.profiles.first(where: { $0.id == activeId }) {
      return active
    }
    return config.profiles.first
  }

  private func actionDescription(for keyId: String) -> String {
    guard let profile = currentProfile(),
          let layer = profile.layers[String(controller.currentLayer)],
          let action = layer[keyId] else {
      return "Unassigned"
    }
    switch action.type {
    case .disabled:
      return "Disabled"
    case .key:
      let mods = (action.modifiers ?? []).map(\.rawValue).joined(separator: "+")
      if mods.isEmpty {
        return "Key \(action.keyCode ?? 0)"
      }
      return "\(mods)+\(action.keyCode ?? 0)"
    case .macro:
      if let id = action.macroId, let macro = macrosLookup[id] {
        return macro.name
      }
      return "Macro"
    case .scroll:
      let mult = action.scrollMultiplier ?? 1
      return "Scroll x\(mult)"
    }
  }

  private var extraInputs: [String] {
    let diagonals: [String] = popupShowDiagonals
      ? ["dpad.up_left", "dpad.up_right", "dpad.down_left", "dpad.down_right"]
      : []
    return [
      "dpad.up",
      "dpad.down",
      "dpad.left",
      "dpad.right",
    ] + diagonals + [
      "wheel.scroll",
      "wheel.up",
      "wheel.down",
      "wheel.click",
    ]
  }

  private func extraInputLabel(_ keyId: String) -> String {
    switch keyId {
    case "dpad.up": return "D-Pad Up"
    case "dpad.down": return "D-Pad Down"
    case "dpad.left": return "D-Pad Left"
    case "dpad.right": return "D-Pad Right"
    case "dpad.up_left": return "D-Pad Up-Left"
    case "dpad.up_right": return "D-Pad Up-Right"
    case "dpad.down_left": return "D-Pad Down-Left"
    case "dpad.down_right": return "D-Pad Down-Right"
    case "wheel.scroll": return "Wheel Scroll"
    case "wheel.up": return "Wheel Up"
    case "wheel.down": return "Wheel Down"
    case "wheel.click": return "Wheel Click"
    default: return keyId
    }
  }
}

struct KeyActionEditor: View {
  let keyId: String
  @State private var actionType: ActionType
  @State private var keyCodeText: String
  @State private var modifiers: Set<HIDModifier>
  @State private var selectedMacroId: UUID?
  @State private var scrollMultiplierText: String
  let macros: [Macro]
  let onSave: (Action) -> Void
  let onCancel: () -> Void

  init(
    keyId: String,
    action: Action?,
    macros: [Macro],
    onSave: @escaping (Action) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.keyId = keyId
    _actionType = State(initialValue: action?.type ?? .disabled)
    _keyCodeText = State(initialValue: action?.keyCode.map(String.init) ?? "")
    _modifiers = State(initialValue: Set(action?.modifiers ?? []))
    _selectedMacroId = State(initialValue: action?.macroId)
    _scrollMultiplierText = State(initialValue: action?.scrollMultiplier.map(String.init) ?? "1")
    self.macros = macros
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
        Text("Macro").tag(ActionType.macro)
        Text("Scroll").tag(ActionType.scroll)
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
      if actionType == .macro {
        Picker("Macro", selection: $selectedMacroId) {
          Text("Select a macro").tag(UUID?.none)
          ForEach(macros, id: \.id) { macro in
            Text(macro.name).tag(Optional(macro.id))
          }
        }
        .frame(width: 320)
      }
      if actionType == .scroll {
        TextField("Scroll multiplier (per tick)", text: $scrollMultiplierText)
          .textFieldStyle(.roundedBorder)
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
            action = Action(type: .macro, macroId: selectedMacroId)
          case .scroll:
            let multiplier = Int(scrollMultiplierText) ?? 1
            action = Action(type: .scroll, scrollMultiplier: multiplier)
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
  let fileRoot = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  if FileManager.default.fileExists(atPath: fileRoot.appendingPathComponent("configs").path) {
    return fileRoot
  }

  if let execPath = Bundle.main.executableURL {
    var current = execPath.deletingLastPathComponent()
    for _ in 0..<6 {
      let candidate = current.appendingPathComponent("configs")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return current
      }
      current = current.deletingLastPathComponent()
    }
  }

  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private var statusMenuItem: NSMenuItem?
  private var profileMenuItem: NSMenuItem?
  private let controller = DaemonController.shared
  private var menuTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = signal(SIGPIPE, SIG_IGN)
    setupStatusItem()
    controller.startAutoRefresh()
    controller.updateActiveBundleId()
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
    window.level = .floating
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
