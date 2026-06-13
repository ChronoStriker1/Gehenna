import AppKit
import GehennaCore
import GehennaDaemonShared
import SwiftUI
import Darwin
import ApplicationServices
import ServiceManagement

enum AppSettingKey {
  static let startMinimized = "gehenna.startMinimized"
  static let autoStartDaemon = "gehenna.autoStartDaemon"
  static let closeToTray = "gehenna.closeToTray"
  static let runAtLogin = "gehenna.runAtLogin"
  static let hideDockIcon = "gehenna.hideDockIcon"
  static let logInputEvents = "gehenna.logInputEvents"
  static let startupLightingBrightness = "gehenna.startupLightingBrightness"
  static let startupLightingEffect = "gehenna.startupLightingEffect"
  static let startupLightingEffectColor1 = "gehenna.startupLightingEffectColor1"
  static let startupLightingEffectColor2 = "gehenna.startupLightingEffectColor2"
  static let startupLightingEffectSpeed = "gehenna.startupLightingEffectSpeed"
}

enum AppInfo {
  static let version = "0.7.5"
}

private let gehennaDaemonModeFlag = "--gehenna-daemon-mode"
private let daemonProcessRegex = "gehenna-daemon-mode|GehennaDaemon"

private func daemonModeArgumentsFromCommandLine(_ commandLine: [String] = CommandLine.arguments) -> [String]? {
  guard commandLine.contains(gehennaDaemonModeFlag) else {
    return nil
  }
  var daemonArgs: [String] = [commandLine.first ?? "GehennaApp"]
  daemonArgs.append(contentsOf: commandLine.dropFirst().filter { $0 != gehennaDaemonModeFlag })
  return daemonArgs
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
  @Published var runAtLogin: Bool {
    didSet {
      UserDefaults.standard.set(runAtLogin, forKey: AppSettingKey.runAtLogin)
      guard oldValue != runAtLogin, !syncingRunAtLogin else { return }
      applyRunAtLoginPreference(runAtLogin)
    }
  }
  @Published var hideDockIcon: Bool {
    didSet {
      UserDefaults.standard.set(hideDockIcon, forKey: AppSettingKey.hideDockIcon)
      applyDockIconVisibility()
    }
  }
  @Published var logInputEvents: Bool {
    didSet { UserDefaults.standard.set(logInputEvents, forKey: AppSettingKey.logInputEvents) }
  }
  @Published var startupLightingBrightness: Int {
    didSet { UserDefaults.standard.set(startupLightingBrightness, forKey: AppSettingKey.startupLightingBrightness) }
  }
  @Published var startupLightingEffect: String {
    didSet { UserDefaults.standard.set(startupLightingEffect, forKey: AppSettingKey.startupLightingEffect) }
  }
  @Published var startupLightingEffectColor1: String {
    didSet { UserDefaults.standard.set(startupLightingEffectColor1, forKey: AppSettingKey.startupLightingEffectColor1) }
  }
  @Published var startupLightingEffectColor2: String {
    didSet { UserDefaults.standard.set(startupLightingEffectColor2, forKey: AppSettingKey.startupLightingEffectColor2) }
  }
  @Published var startupLightingEffectSpeed: Int {
    didSet { UserDefaults.standard.set(startupLightingEffectSpeed, forKey: AppSettingKey.startupLightingEffectSpeed) }
  }
  @Published var lightingDiagnostics = "No lighting command sent yet."
  @Published var lightingReadbackHex: String? = nil

  private var timer: Timer?
  private var daemonLaunchTask: Process?
  private var daemonLogHandle: FileHandle?
  private var isStoppingDaemon = false
  private var syncingRunAtLogin = false

  private func appLogURL() -> URL? {
    let fm = FileManager.default
    guard let logsDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Gehenna", isDirectory: true)
    else {
      return nil
    }
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent("app.log")
  }

  private func logApp(_ message: String) {
    guard let url = appLogURL() else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func daemonLogURL() -> URL? {
    let fm = FileManager.default
    let logsDir = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Gehenna", isDirectory: true)
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent("daemon.log")
  }

  private func configureDaemonLogging(for process: Process) {
    releaseDaemonLoggingHandle()
    guard let logURL = daemonLogURL() else { return }
    let fm = FileManager.default
    if !fm.fileExists(atPath: logURL.path) {
      fm.createFile(atPath: logURL.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    _ = try? handle.seekToEnd()
    process.standardOutput = handle
    process.standardError = handle
    daemonLogHandle = handle
  }

  private func releaseDaemonLoggingHandle() {
    try? daemonLogHandle?.close()
    daemonLogHandle = nil
  }

  private func runningDaemonPIDs() -> [Int] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", daemonProcessRegex]
    let output = Pipe()
    process.standardOutput = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let text = String(data: data, encoding: .utf8) ?? ""
      return text
        .split(whereSeparator: \.isNewline)
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    } catch {
      return []
    }
  }

  private func hasRunningDaemonProcess() -> Bool {
    !runningDaemonPIDs().isEmpty
  }

  private func hasRequiredPermissions(prompt: Bool) -> Bool {
    var ok = true

    if !CGPreflightListenEventAccess() {
      if prompt {
        _ = CGRequestListenEventAccess()
      }
      ok = false
    }

    let axPromptKey = "AXTrustedCheckOptionPrompt" as CFString
    let axOptions = [axPromptKey: prompt as CFBoolean] as CFDictionary
    if !AXIsProcessTrustedWithOptions(axOptions) {
      ok = false
    }

    return ok
  }

  private init() {
    startMinimized = UserDefaults.standard.bool(forKey: AppSettingKey.startMinimized)
    autoStartDaemon = UserDefaults.standard.bool(forKey: AppSettingKey.autoStartDaemon)
    closeToTray = UserDefaults.standard.bool(forKey: AppSettingKey.closeToTray)
    if let storedRunAtLogin = UserDefaults.standard.object(forKey: AppSettingKey.runAtLogin) as? Bool {
      runAtLogin = storedRunAtLogin
    } else {
      runAtLogin = Self.currentSystemRunAtLoginState()
    }
    hideDockIcon = UserDefaults.standard.bool(forKey: AppSettingKey.hideDockIcon)
    logInputEvents = UserDefaults.standard.bool(forKey: AppSettingKey.logInputEvents)
    let storedBrightness = UserDefaults.standard.object(forKey: AppSettingKey.startupLightingBrightness) as? Int
    startupLightingBrightness = min(255, max(0, storedBrightness ?? 180))
    let storedEffect = UserDefaults.standard.string(forKey: AppSettingKey.startupLightingEffect) ?? "spectrum"
    startupLightingEffect = TartarusProLightingEffect.fromString(storedEffect)?.rawValue ?? "spectrum"
    startupLightingEffectColor1 = UserDefaults.standard.string(forKey: AppSettingKey.startupLightingEffectColor1) ?? "00FF00"
    startupLightingEffectColor2 = UserDefaults.standard.string(forKey: AppSettingKey.startupLightingEffectColor2) ?? "0000FF"
    let storedSpeed = UserDefaults.standard.object(forKey: AppSettingKey.startupLightingEffectSpeed) as? Int
    startupLightingEffectSpeed = min(255, max(0, storedSpeed ?? 2))
  }

  func applyDockIconVisibility() {
    let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
    _ = NSApp.setActivationPolicy(policy)
  }

  private static func currentSystemRunAtLoginState() -> Bool {
    if #available(macOS 13.0, *) {
      switch SMAppService.mainApp.status {
      case .enabled, .requiresApproval:
        return true
      default:
        return false
      }
    }
    return false
  }

  private func applyRunAtLoginPreference(_ enabled: Bool) {
    guard #available(macOS 13.0, *) else {
      status = "Run at login is unavailable on this macOS version."
      return
    }

    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      syncRunAtLoginFromSystem()
      status = enabled ? "Run at login enabled." : "Run at login disabled."
    } catch {
      status = "Failed to update run at login: \(error.localizedDescription)"
      syncRunAtLoginFromSystem()
    }
  }

  private func syncRunAtLoginFromSystem() {
    syncingRunAtLogin = true
    runAtLogin = Self.currentSystemRunAtLoginState()
    syncingRunAtLogin = false
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
    if !hasRequiredPermissions(prompt: true) {
      status = "Grant Input Monitoring + Accessibility for Gehenna, then start daemon again."
      return
    }

    if daemonLaunchTask?.isRunning == true || hasRunningDaemonProcess() {
      status = "Daemon already running."
      refreshStatus()
      return
    }

    guard let executableURL = Bundle.main.executableURL else {
      status = "Missing app executable."
      return
    }
    let root = repoRoot()
    let workingRoot = runtimeWorkingRoot(from: root)
    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = workingRoot
    configureDaemonLogging(for: process)
    let args = daemonArguments(seize: true)
    process.arguments = args
    logApp("runSeizedDaemon start binary=\(executableURL.path) cwd=\(workingRoot.path) args=\(args.joined(separator: " "))")
    isStoppingDaemon = false
    process.terminationHandler = { [weak self] task in
      DispatchQueue.main.async {
        self?.logApp("runSeizedDaemon exit status=\(task.terminationStatus)")
        self?.releaseDaemonLoggingHandle()
        if self?.daemonLaunchTask === task {
          self?.daemonLaunchTask = nil
        }
        if task.terminationStatus != 0, self?.isStoppingDaemon == false {
          self?.status = "Seized start failed (exit \(task.terminationStatus)); trying non-seized mode."
          self?.runDaemonWithoutSeize()
        }
        self?.refreshStatus()
        self?.refreshLog()
      }
    }

    status = "Launching daemon..."
    do {
      daemonLaunchTask = process
      try process.run()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.refreshStatus()
        self?.refreshLog()
      }
    } catch {
      daemonLaunchTask = nil
      releaseDaemonLoggingHandle()
      status = "Failed to start daemon: \(error.localizedDescription)"
    }
  }

  private func daemonArguments(seize: Bool) -> [String] {
    var args: [String] = [gehennaDaemonModeFlag, "--enable-output"]
    if seize {
      args.append(contentsOf: ["--seize", "--seize-fallback"])
    }
    if logInputEvents {
      args.append("--log-input")
    }
    let brightness = min(255, max(0, startupLightingBrightness))
    args.append(contentsOf: ["--lighting-brightness", "\(brightness)"])
    if let effect = TartarusProLightingEffect.fromString(startupLightingEffect) {
      args.append(contentsOf: ["--lighting-effect", effect.rawValue])
    }
    if let color1 = normalizeColorHex(startupLightingEffectColor1) {
      args.append(contentsOf: ["--lighting-effect-color1", color1])
    }
    if let color2 = normalizeColorHex(startupLightingEffectColor2) {
      args.append(contentsOf: ["--lighting-effect-color2", color2])
    }
    let speed = min(255, max(0, startupLightingEffectSpeed))
    args.append(contentsOf: ["--lighting-effect-speed", "\(speed)"])
    return args
  }

  private func sendDaemonSignal(_ signalName: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-\(signalName)", "-f", daemonProcessRegex]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      logApp("sendDaemonSignal failed signal=\(signalName) error=\(error.localizedDescription)")
    }
  }

  private func runDaemonWithoutSeize() {
    if daemonLaunchTask?.isRunning == true || hasRunningDaemonProcess() {
      status = "Daemon already running."
      refreshStatus()
      return
    }

    guard let executableURL = Bundle.main.executableURL else {
      status = "Missing app executable."
      return
    }
    let root = repoRoot()
    let workingRoot = runtimeWorkingRoot(from: root)
    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = workingRoot
    configureDaemonLogging(for: process)
    let args = daemonArguments(seize: false)
    process.arguments = args
    logApp("runDaemonWithoutSeize start binary=\(executableURL.path) cwd=\(workingRoot.path) args=\(args.joined(separator: " "))")
    isStoppingDaemon = false
    process.terminationHandler = { [weak self] task in
      DispatchQueue.main.async {
        self?.logApp("runDaemonWithoutSeize exit status=\(task.terminationStatus)")
        self?.releaseDaemonLoggingHandle()
        if self?.daemonLaunchTask === task {
          self?.daemonLaunchTask = nil
        }
        if task.terminationStatus != 0, self?.isStoppingDaemon == false {
          self?.status = "Failed to start daemon in non-seized mode (exit \(task.terminationStatus))."
        }
        self?.refreshStatus()
        self?.refreshLog()
      }
    }

    do {
      daemonLaunchTask = process
      try process.run()
      logApp("runDaemonWithoutSeize launched pid=\(process.processIdentifier)")
      status = "Daemon started in non-seized mode."
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.refreshStatus()
        self?.refreshLog()
      }
    } catch {
      releaseDaemonLoggingHandle()
      logApp("runDaemonWithoutSeize failed error=\(error.localizedDescription)")
      status = "Fallback start failed: \(error.localizedDescription)"
    }
  }

  func stopDaemon() {
    isStoppingDaemon = true
    if let task = daemonLaunchTask, task.isRunning {
      task.terminate()
    }
    sendDaemonSignal("TERM")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.status = "Stop signal sent."
      self?.refreshStatus()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.isStoppingDaemon = false
    }
  }

  func restartDaemon() {
    stopDaemon()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.runSeizedDaemon()
    }
  }

  func reloadConfigs() {
    sendDaemonSignal("USR1")
    status = "Reload signal sent."
  }

  func refreshStatus() {
    let pids = runningDaemonPIDs()
    isRunning = !pids.isEmpty
    if isRunning {
      status = "Running (pid \(pids[0]))"
    } else {
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
    guard let logURL = daemonLogURL() else {
      logText = "No log found yet."
      return
    }
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
    guard let logURL = daemonLogURL() else {
      status = "Failed to clear log: unable to resolve log path."
      return
    }
    do {
      try Data().write(to: logURL, options: .atomic)
      logText = ""
      status = "Log cleared."
    } catch {
      status = "Failed to clear log: \(error.localizedDescription)"
    }
  }

  private func normalizeColorHex(_ raw: String) -> String? {
    guard let color = TartarusProLightingColor.fromHexString(raw) else {
      return nil
    }
    return String(format: "%02X%02X%02X", color.r, color.g, color.b)
  }

  func applyLightingBrightness(_ value: Int) {
    let brightness = min(255, max(0, value))
    startupLightingBrightness = brightness
    sendLightingControl(
      request: DaemonControlRequest(
        command: "lighting",
        staticColorHex: nil,
        brightness: brightness,
        layer: nil,
        effect: nil,
        effectColorHex1: nil,
        effectColorHex2: nil,
        effectSpeed: nil,
        readback: false
      ),
      successPrefix: "Brightness applied"
    )
  }

  func applyLightingEffect(
    _ effect: TartarusProLightingEffect,
    color1Hex: String?,
    color2Hex: String?,
    speed: Int?
  ) {
    let safeSpeed = min(255, max(0, speed ?? 2))
    let normalizedColor1 = color1Hex.flatMap(normalizeColorHex)
    let normalizedColor2 = color2Hex.flatMap(normalizeColorHex)
    startupLightingEffect = effect.rawValue
    if let normalizedColor1 {
      startupLightingEffectColor1 = normalizedColor1
    }
    if let normalizedColor2 {
      startupLightingEffectColor2 = normalizedColor2
    }
    startupLightingEffectSpeed = safeSpeed
    sendLightingControl(
      request: DaemonControlRequest(
        command: "lighting",
        staticColorHex: nil,
        brightness: nil,
        layer: nil,
        effect: effect.rawValue,
        effectColorHex1: normalizedColor1,
        effectColorHex2: normalizedColor2,
        effectSpeed: safeSpeed,
        readback: false
      ),
      successPrefix: "Style applied"
    )
  }

  func lightingDiagnosticsReadback() {
    sendLightingControl(
      request: DaemonControlRequest(
        command: "lighting",
        staticColorHex: nil,
        brightness: nil,
        layer: nil,
        effect: nil,
        effectColorHex1: nil,
        effectColorHex2: nil,
        effectSpeed: nil,
        readback: true
      ),
      successPrefix: "Diagnostics"
    )
  }

  private func controlSocketPath() -> String {
    "/var/tmp/gehenna-control-\(getuid()).sock"
  }

  private func sendLightingControl(request: DaemonControlRequest, successPrefix: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      lightingDiagnostics = "Lighting control socket creation failed."
      return
    }
    defer {
      close(fd)
    }

    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = controlSocketPath()
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
      lightingDiagnostics = "Daemon lighting socket unavailable."
      return
    }

    guard let payload = try? JSONEncoder().encode(request) else {
      lightingDiagnostics = "Failed to encode lighting request."
      return
    }
    _ = payload.withUnsafeBytes { ptr in
      write(fd, ptr.baseAddress, payload.count)
    }
    shutdown(fd, SHUT_WR)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        data.append(buffer, count: count)
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        break
      }
    }

    guard let response = try? JSONDecoder().decode(DaemonControlResponse.self, from: data) else {
      lightingDiagnostics = "Lighting response decode failed."
      return
    }

    if response.ok {
      lightingDiagnostics = "\(successPrefix): \(response.message)"
      lightingReadbackHex = response.readbackHex
    } else {
      lightingDiagnostics = "Lighting failed: \(response.message)"
      lightingReadbackHex = nil
    }
  }

}

struct ContentView: View {
  @ObservedObject private var controller = DaemonController.shared

  var body: some View {
    TabView {
      KeymapView()
        .tabItem { Label("Keymap", systemImage: "keyboard") }
      MacrosView()
        .tabItem { Label("Macros", systemImage: "bolt.horizontal") }
      LightingView()
        .tabItem { Label("Lighting", systemImage: "lightbulb") }
      StatusView()
        .tabItem { Label("Status", systemImage: "waveform.path") }
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
        Button("Start Daemon") {
          controller.runSeizedDaemon()
        }
        Button("Restart Daemon") {
          controller.restartDaemon()
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
      Toggle("Run at login", isOn: $controller.runAtLogin)
      Toggle("Hide app from Dock", isOn: $controller.hideDockIcon)
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

struct LightingView: View {
  @ObservedObject private var controller = DaemonController.shared
  @State private var liveBrightness = 180.0
  @State private var selectedEffectRaw = TartarusProLightingEffect.spectrum.rawValue
  @State private var liveEffectColor1 = "00FF00"
  @State private var liveEffectColor2 = "0000FF"
  @State private var liveEffectSpeed = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Lighting")
        .font(.largeTitle)
        .bold()
      Text("Control key and wheel lighting style and brightness.")
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Picker("Style", selection: $selectedEffectRaw) {
          ForEach(TartarusProLightingEffect.allCases, id: \.rawValue) { effect in
            Text(effectLabel(effect)).tag(effect.rawValue)
          }
        }
        .pickerStyle(.menu)
        Button("Apply Style") {
          guard let effect = TartarusProLightingEffect.fromString(selectedEffectRaw) else {
            return
          }
          controller.applyLightingEffect(
            effect,
            color1Hex: liveEffectColor1,
            color2Hex: liveEffectColor2,
            speed: liveEffectSpeed
          )
        }
      }

      if effectUsesPrimaryColor {
        HStack(spacing: 12) {
          Text("Color 1 (RRGGBB)")
          TextField("00FF00", text: $liveEffectColor1)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        }
      }

      if effectUsesSecondaryColor {
        HStack(spacing: 12) {
          Text("Color 2 (RRGGBB)")
          TextField("0000FF", text: $liveEffectColor2)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        }
      }

      if effectUsesSpeed {
        HStack(spacing: 12) {
          Text("Speed")
          Slider(
            value: Binding(
              get: { Double(liveEffectSpeed) },
              set: { liveEffectSpeed = Int($0.rounded()) }
            ),
            in: speedRange,
            step: 1
          )
          .frame(width: 220)
          Text("\(liveEffectSpeed)")
            .font(.system(.footnote, design: .monospaced))
            .frame(width: 40, alignment: .trailing)
        }
        Text("Used by the current style.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        Text("Brightness")
        Slider(value: $liveBrightness, in: 0...255, step: 1)
          .frame(width: 220)
        Text("\(Int(liveBrightness))")
          .font(.system(.footnote, design: .monospaced))
          .frame(width: 40, alignment: .trailing)
        Button("Apply") {
          controller.applyLightingBrightness(Int(liveBrightness))
        }
      }

      Text("Layer LEDs follow the active Tartarus layer automatically.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Text("Manual layer/static LED override is disabled.")
        .font(.footnote)
        .foregroundStyle(.secondary)

      Divider()
      Text("Last applied settings are remembered and used when starting the daemon.")
        .font(.footnote)
        .foregroundStyle(.secondary)

      HStack {
        Button("Diagnostics") {
          controller.lightingDiagnosticsReadback()
        }
        if let readback = controller.lightingReadbackHex {
          Text("Readback: \(readback)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }

      Text(controller.lightingDiagnostics)
        .font(.footnote)
        .foregroundStyle(.secondary)

      Spacer()
    }
    .padding(24)
    .onAppear {
      liveBrightness = Double(controller.startupLightingBrightness)
      selectedEffectRaw = controller.startupLightingEffect
      liveEffectColor1 = controller.startupLightingEffectColor1
      liveEffectColor2 = controller.startupLightingEffectColor2
      liveEffectSpeed = controller.startupLightingEffectSpeed
      clampSpeedForSelectedEffect()
    }
    .onChange(of: selectedEffectRaw) { _ in
      clampSpeedForSelectedEffect()
    }
  }

  private func effectLabel(_ effect: TartarusProLightingEffect) -> String {
    switch effect {
    case .off:
      return "Off"
    case .static:
      return "Static"
    case .spectrum:
      return "Spectrum (Rainbow)"
    case .waveLeft:
      return "Wave Left"
    case .waveRight:
      return "Wave Right"
    case .breathingRandom:
      return "Breathing (Random)"
    case .breathingSingle:
      return "Breathing (Single)"
    case .breathingDual:
      return "Breathing (Dual)"
    case .reactive:
      return "Reactive"
    case .starlightRandom:
      return "Starlight (Random)"
    case .starlightSingle:
      return "Starlight (Single)"
    case .starlightDual:
      return "Starlight (Dual)"
    }
  }

  private var selectedEffect: TartarusProLightingEffect {
    TartarusProLightingEffect.fromString(selectedEffectRaw) ?? .spectrum
  }

  private var effectUsesPrimaryColor: Bool {
    switch selectedEffect {
    case .static, .breathingSingle, .breathingDual, .reactive, .starlightSingle, .starlightDual:
      return true
    default:
      return false
    }
  }

  private var effectUsesSecondaryColor: Bool {
    switch selectedEffect {
    case .breathingDual, .starlightDual:
      return true
    default:
      return false
    }
  }

  private var effectUsesSpeed: Bool {
    switch selectedEffect {
    case .reactive, .starlightRandom, .starlightSingle, .starlightDual:
      return true
    default:
      return false
    }
  }

  private var speedRange: ClosedRange<Double> {
    switch selectedEffect {
    case .starlightRandom, .starlightSingle, .starlightDual:
      return 1...3
    case .reactive:
      return 1...4
    default:
      return 1...4
    }
  }

  private func clampSpeedForSelectedEffect() {
    let lower = Int(speedRange.lowerBound.rounded())
    let upper = Int(speedRange.upperBound.rounded())
    liveEffectSpeed = min(max(liveEffectSpeed, lower), upper)
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

@MainActor
final class MacroRecorder: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var steps: [MacroStep] = []

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var lastTimestamp: CFAbsoluteTime?
  private static let injectorSourceTag: Int64 = 0x4745484E

  func start() -> Bool {
    guard !isRecording else { return true }
    steps = []
    lastTimestamp = nil

    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passRetained(event) }
      let recorder = Unmanaged<MacroRecorder>.fromOpaque(refcon).takeUnretainedValue()
      return recorder.handle(type: type, event: event)
    }

    let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: callback,
      userInfo: refcon
    )

    guard let tap else { return false }
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let source {
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
    isRecording = true
    return true
  }

  func stop() {
    guard isRecording else { return }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    tap = nil
    source = nil
    isRecording = false
  }

  func clear() {
    steps = []
    lastTimestamp = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passRetained(event)
    }

    guard isRecording else {
      return Unmanaged.passRetained(event)
    }

    if type != .keyDown && type != .keyUp {
      return Unmanaged.passRetained(event)
    }

    let sourceTag = event.getIntegerValueField(.eventSourceUserData)
    if sourceTag == MacroRecorder.injectorSourceTag {
      return Unmanaged.passRetained(event)
    }

    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if isRepeat && type == .keyDown {
      return Unmanaged.passRetained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    guard let usage = HIDKeyMap.usage(forKeyCode: keyCode) else {
      return Unmanaged.passRetained(event)
    }

    if usage >= 0xE0 && usage <= 0xE7 {
      return Unmanaged.passRetained(event)
    }

    let now = CFAbsoluteTimeGetCurrent()
    if let last = lastTimestamp {
      let delayMs = Int(((now - last) * 1000).rounded())
      if delayMs > 0 {
        steps.append(MacroStep(type: .delay, delayMs: delayMs))
      }
    }
    lastTimestamp = now

    let modifiers = normalizedModifiers(modifiersFromFlags(event.flags))
    let stepType: MacroStepType = (type == .keyDown) ? .keyDown : .keyUp
    steps.append(MacroStep(type: stepType, keyCode: usage, modifiers: modifiers.isEmpty ? nil : modifiers))
    return Unmanaged.passRetained(event)
  }

  private func modifiersFromFlags(_ flags: CGEventFlags) -> [HIDModifier] {
    var modifiers: [HIDModifier] = []
    if flags.contains(.maskControl) { modifiers.append(.leftControl) }
    if flags.contains(.maskShift) { modifiers.append(.leftShift) }
    if flags.contains(.maskAlternate) { modifiers.append(.leftAlt) }
    if flags.contains(.maskCommand) { modifiers.append(.leftGUI) }
    return modifiers
  }

  private func normalizedModifiers(_ modifiers: [HIDModifier]) -> [HIDModifier] {
    let order: [HIDModifier] = [
      .leftControl,
      .leftShift,
      .leftAlt,
      .leftGUI,
      .rightControl,
      .rightShift,
      .rightAlt,
      .rightGUI
    ]
    return modifiers.sorted {
      (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max)
    }
  }
}

private struct MacroEditSession: Identifiable {
  let id: UUID
  let macro: Macro

  init(macro: Macro) {
    id = macro.id
    self.macro = macro
  }
}

private struct MacroDeletePrompt: Identifiable {
  let id: UUID
  let name: String
}

private struct GroupDeletePrompt: Identifiable {
  let id: String
  let name: String

  init(name: String) {
    id = name
    self.name = name
  }
}

private struct EditableMacroStep: Identifiable {
  let id = UUID()
  var type: MacroStepType
  var keyCodeText: String
  var modifiersSelection: Set<HIDModifier>
  var delayMsText: String
  var pairedKeyUp: Bool

  init(step: MacroStep, pairedKeyUp: Bool = false) {
    type = step.type
    keyCodeText = step.keyCode.map(String.init) ?? "4"
    modifiersSelection = Set(step.modifiers ?? [])
    delayMsText = String(step.delayMs ?? 0)
    self.pairedKeyUp = pairedKeyUp
  }

  func toMacroStep() -> MacroStep {
    switch type {
    case .delay:
      let parsedDelay = Int(delayMsText) ?? 0
      let clampedDelay = max(0, parsedDelay)
      return MacroStep(type: .delay, delayMs: clampedDelay)
    case .keyDown, .keyUp:
      let parsedUsage = Int(keyCodeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4
      let clampedUsage = max(0, min(255, parsedUsage))
      let orderedModifiers = modifiersSelection.sorted {
        (modifierOrder.firstIndex(of: $0) ?? Int.max) < (modifierOrder.firstIndex(of: $1) ?? Int.max)
      }
      return MacroStep(
        type: type,
        keyCode: clampedUsage,
        modifiers: orderedModifiers.isEmpty ? nil : orderedModifiers
      )
    }
  }

  private var modifierOrder: [HIDModifier] {
    [.leftControl, .leftShift, .leftAlt, .leftGUI, .rightControl, .rightShift, .rightAlt, .rightGUI]
  }

  func keySignatureMatches(_ other: EditableMacroStep) -> Bool {
    keyCodeText.trimmingCharacters(in: .whitespacesAndNewlines)
      == other.keyCodeText.trimmingCharacters(in: .whitespacesAndNewlines)
      && modifiersSelection == other.modifiersSelection
  }
}

struct MacroEditorSheet: View {
  let macro: Macro
  let availableGroups: [String]
  let onSave: (Macro) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @State private var selectedGroup: String?
  @State private var splitKeyEvents: Bool
  @State private var steps: [EditableMacroStep]

  init(
    macro: Macro,
    availableGroups: [String],
    onSave: @escaping (Macro) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.macro = macro
    self.availableGroups = availableGroups
    self.onSave = onSave
    self.onCancel = onCancel
    _name = State(initialValue: macro.name)
    _selectedGroup = State(initialValue: macro.group)
    _splitKeyEvents = State(initialValue: macro.splitKeyEvents)
    _steps = State(
      initialValue: macro.splitKeyEvents
        ? macro.steps.map { EditableMacroStep(step: $0) }
        : MacroEditorSheet.compressEditableSteps(macro.steps.map { EditableMacroStep(step: $0) })
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit Macro")
        .font(.title2)
        .bold()
      Text("Macro Name")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      TextField("Macro name", text: $name)
        .textFieldStyle(.roundedBorder)
      Picker("Group", selection: $selectedGroup) {
        Text("Ungrouped").tag(String?.none)
        ForEach(availableGroups, id: \.self) { group in
          Text(group).tag(Optional(group))
        }
      }
      .pickerStyle(.menu)
      Toggle("Split key down/up steps", isOn: $splitKeyEvents)
        .toggleStyle(.switch)
        .onChange(of: splitKeyEvents) { enabled in
          steps = enabled ? expandEditableSteps(steps) : Self.compressEditableSteps(steps)
        }

      if steps.isEmpty {
        Text("No steps in this macro.")
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.indices), id: \.self) { index in
              macroStepRow(index: index)
            }
          }
        }
        .frame(minHeight: 220, maxHeight: 320)
      }

      HStack(spacing: 12) {
        if splitKeyEvents {
          Button("Add Key Down") {
            steps.append(
              EditableMacroStep(
                step: MacroStep(type: .keyDown, keyCode: 4, modifiers: nil)
              )
            )
          }
          Button("Add Key Up") {
            steps.append(
              EditableMacroStep(
                step: MacroStep(type: .keyUp, keyCode: 4, modifiers: nil)
              )
            )
          }
        } else {
          Button("Add Key Tap") {
            steps.append(
              EditableMacroStep(
                step: MacroStep(type: .keyDown, keyCode: 4, modifiers: nil),
                pairedKeyUp: true
              )
            )
          }
        }
        Button("Add Delay Step") {
          steps.append(
            EditableMacroStep(
              step: MacroStep(type: .delay, delayMs: 100)
            )
          )
        }
        Spacer()
        Button("Cancel") {
          onCancel()
        }
        Button("Save") {
          let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmedName.isEmpty else {
            return
          }
          let rebuiltSteps = rebuiltMacroSteps()
          onSave(
            Macro(
              id: macro.id,
              name: trimmedName,
              group: selectedGroup,
              splitKeyEvents: splitKeyEvents,
              steps: rebuiltSteps
            )
          )
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 460)
  }

  private func macroStepRow(index: Int) -> some View {
    HStack(spacing: 10) {
      Text("\(index + 1).")
        .font(.system(.footnote, design: .monospaced))
        .frame(width: 28, alignment: .trailing)
      stepDetails(index: index)
      Spacer()
      Button("Up") {
        moveStep(from: index, to: index - 1)
      }
      .disabled(index == 0)
      Button("Down") {
        moveStep(from: index, to: index + 1)
      }
      .disabled(index >= steps.count - 1)
      Button("Delete", role: .destructive) {
        steps.remove(at: index)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func stepDetails(index: Int) -> some View {
    let step = steps[index]
    switch step.type {
    case .delay:
      Text("Delay")
        .frame(width: 70, alignment: .leading)
      TextField(
        "ms",
        text: Binding(
          get: { steps[index].delayMsText },
          set: { steps[index].delayMsText = $0 }
        )
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 120)
      Text("ms")
        .foregroundStyle(.secondary)
    case .keyDown, .keyUp:
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(keyStepLabel(step))
            .frame(width: 90, alignment: .leading)
          Text("Usage")
            .foregroundStyle(.secondary)
          TextField(
            "HID",
            text: Binding(
              get: { steps[index].keyCodeText },
              set: { steps[index].keyCodeText = $0 }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 80)
          Text(readableKeyLabel(forUsage: Int(steps[index].keyCodeText) ?? 0))
            .foregroundStyle(.secondary)
            .font(.system(.footnote, design: .monospaced))
        }
        HStack(spacing: 6) {
          Text("Modifiers")
            .foregroundStyle(.secondary)
          ForEach(HIDModifier.allCases, id: \.self) { modifier in
            Toggle(shortModifierName(modifier), isOn: Binding(
              get: { steps[index].modifiersSelection.contains(modifier) },
              set: { isOn in
                if isOn {
                  steps[index].modifiersSelection.insert(modifier)
                } else {
                  steps[index].modifiersSelection.remove(modifier)
                }
              }
            ))
            .toggleStyle(.button)
            .controlSize(.small)
          }
        }
      }
    }
  }

  private func keyStepLabel(_ step: EditableMacroStep) -> String {
    if !splitKeyEvents, step.type == .keyDown, step.pairedKeyUp {
      return "Key Tap"
    }
    return step.type == .keyDown ? "Key Down" : "Key Up"
  }

  private func rebuiltMacroSteps() -> [MacroStep] {
    if splitKeyEvents {
      return steps.map { $0.toMacroStep() }
    }
    var rebuilt: [MacroStep] = []
    for step in steps {
      switch step.type {
      case .delay:
        rebuilt.append(step.toMacroStep())
      case .keyUp:
        rebuilt.append(step.toMacroStep())
      case .keyDown:
        let down = step.toMacroStep()
        rebuilt.append(down)
        if step.pairedKeyUp {
          rebuilt.append(
            MacroStep(
              type: .keyUp,
              keyCode: down.keyCode,
              modifiers: down.modifiers
            )
          )
        }
      }
    }
    return rebuilt
  }

  private func expandEditableSteps(_ source: [EditableMacroStep]) -> [EditableMacroStep] {
    var expanded: [EditableMacroStep] = []
    for step in source {
      if step.type == .keyDown && step.pairedKeyUp {
        var down = step
        down.pairedKeyUp = false
        expanded.append(down)
        expanded.append(
          EditableMacroStep(
            step: MacroStep(
              type: .keyUp,
              keyCode: Int(step.keyCodeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4,
              modifiers: Array(step.modifiersSelection)
            )
          )
        )
      } else {
        var copy = step
        copy.pairedKeyUp = false
        expanded.append(copy)
      }
    }
    return expanded
  }

  private static func compressEditableSteps(_ source: [EditableMacroStep]) -> [EditableMacroStep] {
    var compressed: [EditableMacroStep] = []
    var index = 0
    while index < source.count {
      var current = source[index]
      if current.type == .keyDown, index + 1 < source.count {
        let next = source[index + 1]
        if next.type == .keyUp, current.keySignatureMatches(next) {
          current.pairedKeyUp = true
          compressed.append(current)
          index += 2
          continue
        }
      }
      current.pairedKeyUp = false
      compressed.append(current)
      index += 1
    }
    return compressed
  }

  private func moveStep(from source: Int, to destination: Int) {
    guard source != destination, destination >= 0, destination < steps.count else {
      return
    }
    let step = steps.remove(at: source)
    steps.insert(step, at: destination)
  }

  private func shortModifierName(_ modifier: HIDModifier) -> String {
    switch modifier {
    case .leftControl: return "LCtrl"
    case .leftShift: return "LShift"
    case .leftAlt: return "LAlt"
    case .leftGUI: return "LCmd"
    case .rightControl: return "RCtrl"
    case .rightShift: return "RShift"
    case .rightAlt: return "RAlt"
    case .rightGUI: return "RCmd"
    }
  }

  private func readableKeyLabel(forUsage usage: Int) -> String {
    switch usage {
    case 0x04...0x1D:
      let scalarValue = 65 + (usage - 0x04)
      return String(Character(UnicodeScalar(scalarValue)!))
    case 0x1E...0x26:
      return String(usage - 0x1D)
    case 0x27:
      return "0"
    case 0x28: return "Enter"
    case 0x29: return "Esc"
    case 0x2A: return "Backspace"
    case 0x2B: return "Tab"
    case 0x2C: return "Space"
    case 0x2D: return "-"
    case 0x2E: return "="
    case 0x2F: return "["
    case 0x30: return "]"
    case 0x31: return "\\"
    case 0x33: return ";"
    case 0x34: return "'"
    case 0x35: return "`"
    case 0x36: return ","
    case 0x37: return "."
    case 0x38: return "/"
    case 0x3A...0x45:
      return "F\(usage - 0x39)"
    case 0x4F: return "Right"
    case 0x50: return "Left"
    case 0x51: return "Down"
    case 0x52: return "Up"
    default:
      return "?"
    }
  }
}

struct MacrosView: View {
  @StateObject private var recorder = MacroRecorder()
  @State private var macros: [Macro] = []
  @State private var groups: [String] = []
  @State private var status = "Not loaded"
  @State private var showSaveSheet = false
  @State private var newMacroName = ""
  @State private var showCreateGroupSheet = false
  @State private var newGroupName = ""
  @State private var editSession: MacroEditSession? = nil
  @State private var deletePrompt: MacroDeletePrompt? = nil
  @State private var groupDeletePrompt: GroupDeletePrompt? = nil
  @State private var expandedGroups: Set<String> = []
  @State private var isUngroupedExpanded = false

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
        Button("New Group") {
          newGroupName = ""
          showCreateGroupSheet = true
        }
        if recorder.isRecording {
          Button("Stop Recording") {
            stopRecording()
          }
        } else {
          Button("Start Recording") {
            startRecording()
          }
        }
        Text(status)
          .foregroundStyle(.secondary)
      }
      if recorder.isRecording {
        Text("Recording... \(recorder.steps.count) steps captured")
          .foregroundStyle(.secondary)
      }
      if macros.isEmpty {
        Text("No macros defined yet.")
          .foregroundStyle(.secondary)
      } else {
        List {
          ForEach(groups, id: \.self) { group in
            let grouped = groupedMacros(group)
            Section {
              if expandedGroups.contains(group) {
                if grouped.isEmpty {
                  Text("No macros in this group.")
                    .foregroundStyle(.secondary)
                } else {
                  ForEach(grouped, id: \.id) { macro in
                    macroRow(macro)
                  }
                }
              }
            } header: {
              HStack {
                Button {
                  toggleGroup(group)
                } label: {
                  HStack(spacing: 6) {
                    Image(systemName: expandedGroups.contains(group) ? "chevron.down" : "chevron.right")
                    Text(group)
                  }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(grouped.count)")
                  .foregroundStyle(.secondary)
                Button(role: .destructive) {
                  groupDeletePrompt = GroupDeletePrompt(name: group)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
            }
          }

          Section {
            if isUngroupedExpanded {
              if ungroupedMacros.isEmpty {
                Text("No ungrouped macros.")
                  .foregroundStyle(.secondary)
              } else {
                ForEach(ungroupedMacros, id: \.id) { macro in
                  macroRow(macro)
                }
              }
            }
          } header: {
            HStack {
              Button {
                isUngroupedExpanded.toggle()
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: isUngroupedExpanded ? "chevron.down" : "chevron.right")
                  Text("Ungrouped")
                }
              }
              .buttonStyle(.plain)
              Spacer()
              Text("\(ungroupedMacros.count)")
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear(perform: loadMacros)
    .sheet(isPresented: $showSaveSheet) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Save Macro")
          .font(.headline)
        TextField("Macro name", text: $newMacroName)
          .textFieldStyle(.roundedBorder)
        HStack(spacing: 12) {
          Button("Discard") {
            showSaveSheet = false
            recorder.stop()
            recorder.clear()
          }
          Spacer()
          Button("Save") {
            saveRecordedMacro()
          }
          .disabled(newMacroName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(20)
      .frame(width: 420)
    }
    .sheet(isPresented: $showCreateGroupSheet) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Create Group")
          .font(.headline)
        TextField("Group name", text: $newGroupName)
          .textFieldStyle(.roundedBorder)
        HStack(spacing: 12) {
          Button("Cancel") {
            showCreateGroupSheet = false
          }
          Spacer()
          Button("Create") {
            createGroup()
          }
          .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(20)
      .frame(width: 420)
    }
    .sheet(item: $editSession) { session in
      MacroEditorSheet(
        macro: session.macro,
        availableGroups: groups,
        onSave: { updated in
          saveEditedMacro(updated)
          editSession = nil
        },
        onCancel: {
          editSession = nil
        }
      )
    }
    .alert(item: $deletePrompt) { prompt in
      Alert(
        title: Text("Delete Macro"),
        message: Text("Delete '\(prompt.name)'? This cannot be undone."),
        primaryButton: .destructive(Text("Delete")) {
          deleteMacro(id: prompt.id, name: prompt.name)
        },
        secondaryButton: .cancel()
      )
    }
    .alert(item: $groupDeletePrompt) { prompt in
      Alert(
        title: Text("Remove Group"),
        message: Text("Remove group '\(prompt.name)'? Macros in this group will become ungrouped."),
        primaryButton: .destructive(Text("Remove")) {
          deleteGroup(name: prompt.name)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private func loadMacros() {
    let loader = MacroLibraryLoader()
    let url = ensureMacrosFile(at: macrosURL())
    do {
      let library = try loader.load(from: url)
      let normalized = normalizedState(macros: library.macros, groups: library.groups)
      macros = normalized.macros
      groups = normalized.groups
      expandedGroups = expandedGroups.intersection(Set(normalized.groups))
      status = "Loaded \(normalized.macros.count) macros in \(normalized.groups.count) groups"
    } catch {
      status = "Failed: \(error.localizedDescription)"
    }
  }

  private func startRecording() {
    if recorder.start() {
      status = "Recording started."
    } else {
      status = "Failed to start recording. Enable Accessibility access."
    }
  }

  private func stopRecording() {
    recorder.stop()
    if recorder.steps.isEmpty {
      status = "No input recorded."
    } else {
      newMacroName = "Recorded Macro \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
      showSaveSheet = true
    }
  }

  private func saveRecordedMacro() {
    let name = newMacroName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let macro = Macro(id: UUID(), name: name, group: nil, steps: recorder.steps)
    persistLibrary(
      macros: macros + [macro],
      groups: groups,
      successMessage: "Saved macro: \(name)"
    )
    showSaveSheet = false
    recorder.clear()
  }

  private func saveEditedMacro(_ macro: Macro) {
    var updatedMacros = macros
    if let index = updatedMacros.firstIndex(where: { $0.id == macro.id }) {
      updatedMacros[index] = macro
    } else {
      updatedMacros.append(macro)
    }
    persistLibrary(
      macros: updatedMacros,
      groups: groups,
      successMessage: "Updated macro: \(macro.name)"
    )
  }

  private func deleteMacro(id: UUID, name: String) {
    let updatedMacros = macros.filter { $0.id != id }
    persistLibrary(
      macros: updatedMacros,
      groups: groups,
      successMessage: "Deleted macro: \(name)"
    )
  }

  private func createGroup() {
    guard let group = normalizedGroupName(newGroupName) else {
      return
    }
    if groups.contains(where: { $0.localizedCaseInsensitiveCompare(group) == .orderedSame }) {
      status = "Group already exists: \(group)"
      showCreateGroupSheet = false
      return
    }
    persistLibrary(
      macros: macros,
      groups: groups + [group],
      successMessage: "Created group: \(group)"
    )
    showCreateGroupSheet = false
  }

  private func deleteGroup(name: String) {
    let updatedMacros = macros.map { macro in
      if macro.group?.localizedCaseInsensitiveCompare(name) == .orderedSame {
        return Macro(
          id: macro.id,
          name: macro.name,
          group: nil,
          splitKeyEvents: macro.splitKeyEvents,
          steps: macro.steps
        )
      }
      return macro
    }
    let updatedGroups = groups.filter { $0.localizedCaseInsensitiveCompare(name) != .orderedSame }
    expandedGroups.remove(name)
    persistLibrary(
      macros: updatedMacros,
      groups: updatedGroups,
      successMessage: "Removed group: \(name)"
    )
  }

  private func persistLibrary(macros: [Macro], groups: [String], successMessage: String) {
    let url = ensureMacrosFile(at: macrosURL())
    let normalized = normalizedState(macros: macros, groups: groups)
    do {
      let library = MacroLibrary(macros: normalized.macros, groups: normalized.groups)
      try writeMacros(library, to: url)
      self.macros = normalized.macros
      self.groups = normalized.groups
      status = successMessage
    } catch {
      status = "Failed to write macros: \(error.localizedDescription)"
    }
  }

  private func normalizedState(macros: [Macro], groups: [String]) -> (macros: [Macro], groups: [String]) {
    let normalizedMacros = macros.map { macro in
      Macro(
        id: macro.id,
        name: macro.name.trimmingCharacters(in: .whitespacesAndNewlines),
        group: normalizedGroupName(macro.group),
        splitKeyEvents: macro.splitKeyEvents,
        steps: macro.steps
      )
    }
    let normalizedGroups = normalizeGroups(explicit: groups, macros: normalizedMacros)
    return (normalizedMacros, normalizedGroups)
  }

  private func normalizeGroups(explicit: [String], macros: [Macro]) -> [String] {
    var set = Set<String>()
    for group in explicit {
      if let normalized = normalizedGroupName(group) {
        set.insert(normalized)
      }
    }
    for macro in macros {
      if let normalized = normalizedGroupName(macro.group) {
        set.insert(normalized)
      }
    }
    return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private func normalizedGroupName(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func groupedMacros(_ group: String) -> [Macro] {
    macros
      .filter { $0.group?.localizedCaseInsensitiveCompare(group) == .orderedSame }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func toggleGroup(_ group: String) {
    if expandedGroups.contains(group) {
      expandedGroups.remove(group)
    } else {
      expandedGroups.insert(group)
    }
  }

  private var ungroupedMacros: [Macro] {
    macros
      .filter { normalizedGroupName($0.group) == nil }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  @ViewBuilder
  private func macroRow(_ macro: Macro) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(macro.name)
          .font(.headline)
        Text("\(macro.steps.count) steps")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Edit") {
        editSession = MacroEditSession(macro: macro)
      }
      .buttonStyle(.borderless)
      Button("Delete", role: .destructive) {
        deletePrompt = MacroDeletePrompt(id: macro.id, name: macro.name)
      }
      .buttonStyle(.borderless)
    }
  }

  private func macrosURL() -> URL {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      return appSupport.appendingPathComponent("Gehenna", isDirectory: true)
        .appendingPathComponent("macros.json")
    }
    return repoRoot().appendingPathComponent("configs/macros.json")
  }

  private func ensureMacrosFile(at url: URL) -> URL {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      return url
    }
    let fallback = repoRoot().appendingPathComponent("configs/macros.json")
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

  private func writeMacros(_ library: MacroLibrary, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(library)
    try data.write(to: url, options: .atomic)
  }
}

private func repoRoot() -> URL {
  func candidateScore(_ root: URL) -> Int {
    let fm = FileManager.default
    let hasConfigs = fm.fileExists(atPath: root.appendingPathComponent("configs").path)
    let hasScripts = fm.fileExists(atPath: root.appendingPathComponent("scripts").path)
    if hasConfigs && hasScripts {
      return 3
    }
    if hasConfigs {
      return 2
    }
    if hasScripts {
      return 1
    }
    return 0
  }

  func bestLayout(at root: URL) -> (URL, Int) {
    var best = (root, candidateScore(root))
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    let resourcesScore = candidateScore(resources)
    if resourcesScore > best.1 {
      best = (resources, resourcesScore)
    }
    return best
  }

  var bestFound: (URL, Int)? = nil
  if let execPath = Bundle.main.executableURL {
    var current = execPath.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = bestLayout(at: current)
      if candidate.1 == 3 {
        return candidate.0
      }
      if let existing = bestFound {
        if candidate.1 > existing.1 {
          bestFound = candidate
        }
      } else if candidate.1 > 0 {
        bestFound = candidate
      }
      current = current.deletingLastPathComponent()
    }
  }

  let fileRoot = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let fileCandidate = bestLayout(at: fileRoot)
  if fileCandidate.1 == 3 {
    return fileCandidate.0
  }
  if let existing = bestFound {
    if fileCandidate.1 > existing.1 {
      bestFound = fileCandidate
    }
  } else if fileCandidate.1 > 0 {
    bestFound = fileCandidate
  }
  if let bestFound {
    return bestFound.0
  }

  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func runtimeWorkingRoot(from root: URL) -> URL {
  let fm = FileManager.default
  if fm.fileExists(atPath: root.appendingPathComponent("configs").path) {
    return root
  }
  let parent = root.deletingLastPathComponent()
  if fm.fileExists(atPath: parent.appendingPathComponent("configs").path) {
    return parent
  }
  return root
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private var statusMenuItem: NSMenuItem?
  private var profileMenuItem: NSMenuItem?
  private let controller = DaemonController.shared
  private var menuTimer: Timer?

  func applicationWillFinishLaunching(_ notification: Notification) {
    if daemonModeArgumentsFromCommandLine() != nil {
      NSApp.setActivationPolicy(.prohibited)
      return
    }
    controller.applyDockIconVisibility()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let daemonArgs = daemonModeArgumentsFromCommandLine() {
      NSApp.setActivationPolicy(.prohibited)
      DispatchQueue.global(qos: .userInitiated).async {
        let code = runGehennaDaemon(arguments: daemonArgs)
        DispatchQueue.main.async {
          NSApp.terminate(nil)
          Darwin.exit(code)
        }
      }
      return
    }

    _ = signal(SIGPIPE, SIG_IGN)
    controller.applyDockIconVisibility()
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
      if daemonModeArgumentsFromCommandLine() == nil {
        ContentView()
      } else {
        EmptyView()
      }
    }
  }
}
