import Foundation
import GehennaCore
import GehennaHID
import ApplicationServices
import Darwin

struct DaemonConfig {
  let mappingPath: String?
  let profilesPath: String?
  let macrosPath: String?
  let enableOutput: Bool
  let seize: Bool
  let suppressMapped: Bool
  let injectOnRelease: Bool
  let logKeyboardType: Bool
  let suppressKeyboardType: Int?
  let logTapAll: Bool
  let logInputEvents: Bool
  let seizeFallback: Bool
  let enableLighting: Bool
  let lightingBrightness: UInt8?
  let lightingStaticColor: TartarusProLightingColor?
  let lightingEffect: TartarusProLightingEffect?
  let lightingEffectColor1: TartarusProLightingColor?
  let lightingEffectColor2: TartarusProLightingColor?
  let lightingEffectSpeed: UInt8?
}

struct InputKey: Hashable {
  let interface: Int
  let usagePage: Int
  let usage: Int
  let modifiers: [HIDModifier]
}

struct InputEvent {
  let inputId: String
  let state: String
  let value: Int?
  let layer: Int
  let layerModifier: Bool
}

final class RuntimeState: @unchecked Sendable {
  private let queue = DispatchQueue(label: "gehenna.runtime")
  private var profilesConfig: ProfilesConfig?
  private var macroLookup: [UUID: Macro]

  init(profilesConfig: ProfilesConfig?, macroLookup: [UUID: Macro]) {
    self.profilesConfig = profilesConfig
    self.macroLookup = macroLookup
  }

  func update(profilesConfig: ProfilesConfig?, macroLookup: [UUID: Macro]) {
    queue.sync {
      self.profilesConfig = profilesConfig
      self.macroLookup = macroLookup
    }
  }

  func snapshot() -> (ProfilesConfig?, [UUID: Macro]) {
    queue.sync {
      (profilesConfig, macroLookup)
    }
  }
}

public struct DaemonStatus: Codable {
  public let pid: Int
  public let deviceName: String
  public let connected: Bool
  public let layer: Int
  public let layerModifier: Bool
  public let profileName: String?
  public let bundleId: String?
  public let lastEvent: String?
  public let keymapPopupToken: Int?
  public let keymapPopupVisible: Bool
  public let updatedAt: String
}

private let modifierOrder: [HIDModifier] = [
  .leftControl,
  .leftShift,
  .leftAlt,
  .leftGUI,
  .rightControl,
  .rightShift,
  .rightAlt,
  .rightGUI
]

func normalizedModifiers(_ modifiers: [HIDModifier]?) -> [HIDModifier] {
  let list = modifiers ?? []
  return list.sorted {
    (modifierOrder.firstIndex(of: $0) ?? Int.max) < (modifierOrder.firstIndex(of: $1) ?? Int.max)
  }
}

func parseArgs(arguments: [String]) -> DaemonConfig {
  var args = arguments
  if !args.isEmpty {
    args.removeFirst()
  }

  var mappingPath: String?
  var profilesPath: String?
  var macrosPath: String?
  var enableOutput = false
  var seize = false
  var suppressMapped = false
  var injectOnRelease = false
  var logKeyboardType = false
  var suppressKeyboardType: Int?
  var logTapAll = false
  var logInputEvents = false
  var seizeFallback = false
  var enableLighting = true
  var lightingBrightness: UInt8?
  var lightingStaticColor: TartarusProLightingColor?
  var lightingEffect: TartarusProLightingEffect?
  var lightingEffectColor1: TartarusProLightingColor?
  var lightingEffectColor2: TartarusProLightingColor?
  var lightingEffectSpeed: UInt8?
  var index = 0
  while index < args.count {
    let arg = args[index]
    switch arg {
    case "--mapping":
      index += 1
      if index < args.count {
        mappingPath = args[index]
      }
    case "--profiles":
      index += 1
      if index < args.count {
        profilesPath = args[index]
      }
    case "--macros":
      index += 1
      if index < args.count {
        macrosPath = args[index]
      }
    case "--enable-output":
      enableOutput = true
      suppressMapped = true
    case "--seize":
      seize = true
    case "--seize-fallback":
      seizeFallback = true
    case "--allow-native":
      suppressMapped = false
    case "--inject-release":
      injectOnRelease = true
    case "--log-keyboard-type":
      logKeyboardType = true
    case "--suppress-keyboard-type":
      index += 1
      if index < args.count {
        suppressKeyboardType = Int(args[index])
      }
    case "--log-tap":
      logTapAll = true
    case "--log-input":
      logInputEvents = true
    case "--no-lighting":
      enableLighting = false
    case "--lighting-brightness":
      index += 1
      if index < args.count, let value = Int(args[index]), (0...255).contains(value) {
        lightingBrightness = UInt8(value)
      }
    case "--lighting-static":
      index += 1
      if index < args.count {
        lightingStaticColor = TartarusProLightingColor.fromHexString(args[index])
      }
    case "--lighting-effect":
      index += 1
      if index < args.count {
        lightingEffect = TartarusProLightingEffect.fromString(args[index])
      }
    case "--lighting-effect-color1":
      index += 1
      if index < args.count {
        lightingEffectColor1 = TartarusProLightingColor.fromHexString(args[index])
      }
    case "--lighting-effect-color2":
      index += 1
      if index < args.count {
        lightingEffectColor2 = TartarusProLightingColor.fromHexString(args[index])
      }
    case "--lighting-effect-speed":
      index += 1
      if index < args.count, let value = Int(args[index]), (0...255).contains(value) {
        lightingEffectSpeed = UInt8(value)
      }
    default:
      break
    }
    index += 1
  }

  return DaemonConfig(
    mappingPath: mappingPath,
    profilesPath: profilesPath,
    macrosPath: macrosPath,
    enableOutput: enableOutput,
    seize: seize,
    suppressMapped: suppressMapped,
    injectOnRelease: injectOnRelease,
    logKeyboardType: logKeyboardType,
    suppressKeyboardType: suppressKeyboardType,
    logTapAll: logTapAll,
    logInputEvents: logInputEvents,
    seizeFallback: seizeFallback,
    enableLighting: enableLighting,
    lightingBrightness: lightingBrightness,
    lightingStaticColor: lightingStaticColor,
    lightingEffect: lightingEffect,
    lightingEffectColor1: lightingEffectColor1,
    lightingEffectColor2: lightingEffectColor2,
    lightingEffectSpeed: lightingEffectSpeed
  )
}

func defaultMappingURL() -> URL? {
  let fm = FileManager.default
  if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
      .appendingPathComponent("device-mapping.json")
    if fm.fileExists(atPath: path.path) {
      return path
    }
  }

  let local = URL(fileURLWithPath: "configs/tartarus-pro.windows-default.json")
  if fm.fileExists(atPath: local.path) {
    return local
  }

  return nil
}

func defaultProfilesURL() -> URL? {
  let fm = FileManager.default
  if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
      .appendingPathComponent("profiles.json")
    if fm.fileExists(atPath: path.path) {
      return path
    }
  }

  let local = URL(fileURLWithPath: "configs/profiles.json")
  if fm.fileExists(atPath: local.path) {
    return local
  }

  return nil
}

func defaultMacrosURL() -> URL? {
  let fm = FileManager.default
  if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    let path = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
      .appendingPathComponent("macros.json")
    if fm.fileExists(atPath: path.path) {
      return path
    }
  }

  let local = URL(fileURLWithPath: "configs/macros.json")
  if fm.fileExists(atPath: local.path) {
    return local
  }

  return nil
}

func statusFileURL() -> URL? {
  let fm = FileManager.default
  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let home = String(cString: pw.pointee.pw_dir)
    let base = URL(fileURLWithPath: home)
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
    let dir = base.appendingPathComponent("Gehenna", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("status.json")
  }

  guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
    return nil
  }
  let dir = appSupport.appendingPathComponent("Gehenna", isDirectory: true)
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("status.json")
}

final class StatusPublisher {
  private let queue = DispatchQueue(label: "gehenna.status.publisher")
  private var clients: [Int32] = []

  func addClient(_ fd: Int32) {
    queue.sync {
      var one: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      clients.append(fd)
    }
  }

  func publish(_ status: DaemonStatus) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let payload = try? encoder.encode(status) else { return }
    var closed: [Int32] = []
    queue.sync {
      for fd in clients {
        var length = UInt32(payload.count).bigEndian
        let headerResult = withUnsafeBytes(of: &length) { ptr in
          write(fd, ptr.baseAddress, ptr.count)
        }
        if headerResult != MemoryLayout<UInt32>.size {
          closed.append(fd)
          continue
        }
        let bodyResult = payload.withUnsafeBytes { ptr in
          write(fd, ptr.baseAddress, payload.count)
        }
        if bodyResult != payload.count {
          closed.append(fd)
        }
      }
      if !closed.isEmpty {
        clients.removeAll { fd in
          if closed.contains(fd) {
            close(fd)
            return true
          }
          return false
        }
      }
    }
  }
}

func statusSocketPath() -> String {
  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    return "/var/tmp/gehenna-status-\(uid).sock"
  }
  return "/var/tmp/gehenna-status-\(getuid()).sock"
}

func startStatusServer(publisher: StatusPublisher) -> DispatchSourceRead? {
  let path = statusSocketPath()
  _ = unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 {
    return nil
  }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
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

  let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
      Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bindResult != 0 {
    close(fd)
    return nil
  }

  _ = listen(fd, 16)
  _ = fcntl(fd, F_SETFL, O_NONBLOCK)

  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    let gid = pw.pointee.pw_gid
    _ = chown(path, uid, gid)
    _ = chmod(path, S_IRUSR | S_IWUSR)
  } else {
    _ = chmod(path, S_IRUSR | S_IWUSR)
  }

  let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
  source.setEventHandler {
    while true {
      var addr = sockaddr()
      var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(fd, &addr, &len)
      if client < 0 {
        if errno == EWOULDBLOCK || errno == EAGAIN {
          break
        }
        break
      }
      publisher.addClient(client)
    }
  }
  source.setCancelHandler {
    close(fd)
    _ = unlink(path)
  }
  source.resume()
  return source
}

final class ActiveAppState {
  private let queue = DispatchQueue(label: "gehenna.active-app.state")
  private var bundleId: String? = nil

  func get() -> String? {
    queue.sync { bundleId }
  }

  func set(_ value: String?) {
    queue.sync { bundleId = value }
  }
}

public struct ActiveAppMessage: Codable {
  public let bundleId: String

  public init(bundleId: String) {
    self.bundleId = bundleId
  }
}

public struct DaemonControlRequest: Codable {
  public let command: String
  public let staticColorHex: String?
  public let brightness: Int?
  public let layer: Int?
  public let effect: String?
  public let effectColorHex1: String?
  public let effectColorHex2: String?
  public let effectSpeed: Int?
  public let readback: Bool?

  public init(
    command: String,
    staticColorHex: String?,
    brightness: Int?,
    layer: Int?,
    effect: String?,
    effectColorHex1: String?,
    effectColorHex2: String?,
    effectSpeed: Int?,
    readback: Bool?
  ) {
    self.command = command
    self.staticColorHex = staticColorHex
    self.brightness = brightness
    self.layer = layer
    self.effect = effect
    self.effectColorHex1 = effectColorHex1
    self.effectColorHex2 = effectColorHex2
    self.effectSpeed = effectSpeed
    self.readback = readback
  }
}

public struct DaemonControlResponse: Codable {
  public let ok: Bool
  public let message: String
  public let readbackHex: String?

  public init(ok: Bool, message: String, readbackHex: String?) {
    self.ok = ok
    self.message = message
    self.readbackHex = readbackHex
  }
}

func activeAppSocketPath() -> String {
  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    return "/var/tmp/gehenna-active-app-\(uid).sock"
  }
  return "/var/tmp/gehenna-active-app-\(getuid()).sock"
}

func startActiveAppServer(
  state: ActiveAppState,
  onUpdate: @escaping (String?) -> Void
) -> DispatchSourceRead? {
  let path = activeAppSocketPath()
  _ = unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 {
    return nil
  }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
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

  let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
      Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bindResult != 0 {
    close(fd)
    return nil
  }

  _ = listen(fd, 8)
  _ = fcntl(fd, F_SETFL, O_NONBLOCK)

  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    let gid = pw.pointee.pw_gid
    _ = chown(path, uid, gid)
    _ = chmod(path, S_IRUSR | S_IWUSR)
  } else {
    _ = chmod(path, S_IRUSR | S_IWUSR)
  }

  let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
  source.setEventHandler {
    while true {
      var addr = sockaddr()
      var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(fd, &addr, &len)
      if client < 0 {
        if errno == EWOULDBLOCK || errno == EAGAIN {
          break
        }
        break
      }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = read(client, &buffer, buffer.count)
        if count > 0 {
          data.append(buffer, count: count)
        } else {
          break
        }
      }
      close(client)
      if let message = try? JSONDecoder().decode(ActiveAppMessage.self, from: data) {
        state.set(message.bundleId)
        onUpdate(message.bundleId)
      }
    }
  }
  source.setCancelHandler {
    close(fd)
    _ = unlink(path)
  }
  source.resume()
  return source
}

func controlSocketPath() -> String {
  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    return "/var/tmp/gehenna-control-\(uid).sock"
  }
  return "/var/tmp/gehenna-control-\(getuid()).sock"
}

func startControlServer(
  handler: @escaping (DaemonControlRequest) -> DaemonControlResponse
) -> DispatchSourceRead? {
  let path = controlSocketPath()
  _ = unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 {
    return nil
  }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
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

  let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
      Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bindResult != 0 {
    close(fd)
    return nil
  }

  _ = listen(fd, 8)
  _ = fcntl(fd, F_SETFL, O_NONBLOCK)

  if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
     let pw = getpwnam(sudoUser) {
    let uid = pw.pointee.pw_uid
    let gid = pw.pointee.pw_gid
    _ = chown(path, uid, gid)
    _ = chmod(path, S_IRUSR | S_IWUSR)
  } else {
    _ = chmod(path, S_IRUSR | S_IWUSR)
  }

  let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
  source.setEventHandler {
    while true {
      var addr = sockaddr()
      var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(fd, &addr, &len)
      if client < 0 {
        if errno == EWOULDBLOCK || errno == EAGAIN {
          break
        }
        break
      }

      // Accepted sockets inherit nonblocking behavior from the listener on some systems.
      // Switch client to blocking so we can reliably read the full JSON request.
      _ = fcntl(client, F_SETFL, 0)

      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = read(client, &buffer, buffer.count)
        if count > 0 {
          data.append(buffer, count: count)
        } else if count < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }

      let response: DaemonControlResponse
      if let request = try? JSONDecoder().decode(DaemonControlRequest.self, from: data) {
        response = handler(request)
      } else {
        response = DaemonControlResponse(
          ok: false,
          message: "Invalid control payload.",
          readbackHex: nil
        )
      }

      if let payload = try? JSONEncoder().encode(response) {
        _ = payload.withUnsafeBytes { ptr in
          write(client, ptr.baseAddress, payload.count)
        }
      }

      close(client)
    }
  }
  source.setCancelHandler {
    close(fd)
    _ = unlink(path)
  }
  source.resume()
  return source
}

func resolveProfile(config: ProfilesConfig?, bundleId: String?) -> LayeredProfile? {
  guard let config else { return nil }
  if let bundleId,
     let perApp = config.profiles.first(where: { $0.perAppBundleId == bundleId }) {
    return perApp
  }
  if let activeId = config.activeProfileId,
     let active = config.profiles.first(where: { $0.id == activeId }),
     active.perAppBundleId == nil {
    return active
  }
  if let fallback = config.profiles.first(where: { $0.name.lowercased() == "default" }) {
    return fallback
  }
  return config.profiles.first
}

func loadMapping(config: DaemonConfig) throws -> DeviceMapping {
  let loader = MappingLoader()
  if let mappingPath = config.mappingPath {
    return try loader.load(from: URL(fileURLWithPath: mappingPath))
  }
  if let url = defaultMappingURL() {
    return try loader.load(from: url)
  }

  throw MappingError.fileNotFound
}

func loadProfiles(config: DaemonConfig) throws -> ProfilesConfig {
  let loader = ProfilesLoader()
  if let profilesPath = config.profilesPath {
    return try loader.load(from: URL(fileURLWithPath: profilesPath))
  }
  if let url = defaultProfilesURL() {
    return try loader.load(from: url)
  }

  throw ProfilesError.fileNotFound
}

func loadMacros(config: DaemonConfig) throws -> MacroLibrary {
  let loader = MacroLibraryLoader()
  if let macrosPath = config.macrosPath {
    return try loader.load(from: URL(fileURLWithPath: macrosPath))
  }
  if let url = defaultMacrosURL() {
    return try loader.load(from: url)
  }

  return MacroLibrary(macros: [])
}

func resolveAction(profile: LayeredProfile, layer: Int, inputId: String) -> Action? {
  if let action = profile.layers["\(layer)"]?[inputId] {
    return action
  }
  if layer != 1, let fallback = profile.layers["1"]?[inputId] {
    return fallback
  }
  return nil
}

func cgFlags(from modifiers: [HIDModifier]?) -> CGEventFlags {
  var flags: CGEventFlags = []
  for modifier in modifiers ?? [] {
    switch modifier {
    case .leftControl, .rightControl:
      flags.insert(.maskControl)
    case .leftShift, .rightShift:
      flags.insert(.maskShift)
    case .leftAlt, .rightAlt:
      flags.insert(.maskAlternate)
    case .leftGUI, .rightGUI:
      flags.insert(.maskCommand)
    }
  }
  return flags
}

final class EventInjector: @unchecked Sendable {
  static let sourceTag: Int64 = 0x4745484E
  private let source = CGEventSource(stateID: .hidSystemState)

  func sendKey(usage: Int, modifiers: [HIDModifier]?, isDown: Bool) {
    guard let keyCode = HIDKeyMap.keyCode(forUsage: usage) else {
      print("[inject] Unknown HID usage \(usage)")
      return
    }

    guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else {
      return
    }

    event.flags = cgFlags(from: modifiers)
    event.setIntegerValueField(.eventSourceUserData, value: EventInjector.sourceTag)
    event.post(tap: .cghidEventTap)
  }

  func sendKeyPress(usage: Int, modifiers: [HIDModifier]?) {
    sendKey(usage: usage, modifiers: modifiers, isDown: true)
    sendKey(usage: usage, modifiers: modifiers, isDown: false)
  }

  func sendScroll(delta: Int) {
    guard let event = CGEvent(
      scrollWheelEvent2Source: source,
      units: .line,
      wheelCount: 1,
      wheel1: Int32(delta),
      wheel2: 0,
      wheel3: 0
    ) else {
      return
    }
    event.setIntegerValueField(.eventSourceUserData, value: EventInjector.sourceTag)
    event.post(tap: .cghidEventTap)
  }
}

final class EventSuppressor {
  private let window: TimeInterval
  private var recent: [InputKey: CFAbsoluteTime] = [:]
  private var recentKeyCodes: [CGKeyCode: CFAbsoluteTime] = [:]
  private let queue = DispatchQueue(label: "gehenna.suppressor")

  init(window: TimeInterval) {
    self.window = window
  }

  func record(_ key: InputKey) {
    let now = CFAbsoluteTimeGetCurrent()
    queue.sync {
      recent[key] = now
    }
  }

  func recordKeyCode(_ keyCode: CGKeyCode) {
    let now = CFAbsoluteTimeGetCurrent()
    queue.sync {
      recentKeyCodes[keyCode] = now
    }
  }

  func shouldSuppress(_ key: InputKey) -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    return queue.sync {
      guard let last = recent[key] else {
        return false
      }
      return (now - last) <= window
    }
  }

  func shouldSuppressKeyCode(_ keyCode: CGKeyCode) -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    return queue.sync {
      guard let last = recentKeyCodes[keyCode] else {
        return false
      }
      return (now - last) <= window
    }
  }
}

final class SuppressedKeySet {
  private var active: Set<CGKeyCode> = []
  private let queue = DispatchQueue(label: "gehenna.suppressset")

  func add(_ keyCode: CGKeyCode) {
    _ = queue.sync {
      active.insert(keyCode)
    }
  }

  func remove(_ keyCode: CGKeyCode) {
    _ = queue.sync {
      active.remove(keyCode)
    }
  }

  func contains(_ keyCode: CGKeyCode) -> Bool {
    queue.sync {
      active.contains(keyCode)
    }
  }
}

final class KeyEventTap {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private let handler: (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

  init(handler: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) {
    self.handler = handler
  }

  func start() {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: { proxy, type, event, userInfo in
        guard let userInfo else {
          return Unmanaged.passRetained(event)
        }
        let tap = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handler(type, event) ?? Unmanaged.passRetained(event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      print("Failed to create key event tap. Ensure Accessibility permission is granted.")
      return
    }

    self.tap = tap
    self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let source {
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func stop() {
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    source = nil
    tap = nil
  }
}

final class MacroRunner {
  private let injector: EventInjector

  init(injector: EventInjector) {
    self.injector = injector
  }

  func run(_ macro: Macro) {
    var offsetMs = 0
    for step in macro.steps {
      switch step.type {
      case .delay:
        offsetMs += max(0, step.delayMs ?? 0)
      case .keyDown, .keyUp:
        guard let keyCode = step.keyCode else {
          continue
        }
        let isDown = step.type == .keyDown
        let modifiers = step.modifiers
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [injector] in
          injector.sendKey(usage: keyCode, modifiers: modifiers, isDown: isDown)
        }
      }
    }
  }
}

func buildLookup(mapping: DeviceMapping) -> [InputKey: String] {
  var lookup: [InputKey: String] = [:]
  for (inputId, def) in mapping.inputs {
    let key = InputKey(
      interface: def.hid.interface,
      usagePage: def.hid.usagePage,
      usage: def.hid.usage,
      modifiers: normalizedModifiers(def.hid.modifiers)
    )
    lookup[key] = inputId
  }
  return lookup
}

func startDaemon(mapping: DeviceMapping, profiles: ProfilesConfig?, macros: MacroLibrary, config: DaemonConfig) throws {
  let lookup = buildLookup(mapping: mapping)
  let mappedUsages: Set<Int> = Set(
    mapping.inputs.values.compactMap { input in
      if input.kind == .button, input.hid.usagePage == 7, input.hid.interface != 1 {
        return input.hid.usage
      }
      return nil
    }
  )
  let match = HIDMatch(vendorId: mapping.device.vendorId, productId: mapping.device.productId)
  let devices = try HIDEnumerator().openDevices(match: match)

  var currentLayer = 1
  var layerHoldActive = false
  var layerUsedAsModifier = false

  let deviceByInterface = classifyInterfaces(devices: devices)
  let usedInterfaces = Set(mapping.inputs.values.map { $0.hid.interface })
  var listeners: [AnyObject] = []
  var openedLightingDeviceKeys: Set<String> = []
  var previousKeys: [Int: Set<InputKey>] = [:]
  var previousModifiers: [Int: Set<HIDModifier>] = [:]
  // currentLayer/layerHoldActive initialized above for status reporting.
  let injector = EventInjector()
  let macroRunner = MacroRunner(injector: injector)
  let macroLookup = Dictionary(uniqueKeysWithValues: macros.macros.map { ($0.id, $0) })
  let runtime = RuntimeState(profilesConfig: profiles, macroLookup: macroLookup)
  let enableOutput = config.enableOutput && profiles != nil
  let suppressor = EventSuppressor(window: 0.15)
  let suppressedKeys = SuppressedKeySet()
  var eventTap: KeyEventTap?
  var tartarusKeyboardType: Int? = config.suppressKeyboardType
  let openOptions = config.seize
    ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    : IOOptionBits(kIOHIDOptionsTypeNone)
  var seizeFallbackInterfaceCount = 0
  var lastBundleId: String? = nil
  let activeAppState = ActiveAppState()
  let statusPublisher = StatusPublisher()
  var keymapPopupToken = 0
  var layerHoldTimer: DispatchSourceTimer?
  var layerPopupTriggered = false
  var keymapPopupVisible = false
  var dpadPressed: Set<String> = []
  var lastDpadEffective: String? = nil
  var lightingListeners: [HIDInputListener] = []
  var activeLightingListenerIndex = 0

  if config.enableOutput && profiles == nil {
    print("Output enabled but no profiles loaded. Output will remain disabled.")
  }

  func publishStatus(lastEvent: String?) {
    let (profilesConfig, _) = runtime.snapshot()
    let bundleId = activeAppState.get()
    let profile = resolveProfile(config: profilesConfig, bundleId: bundleId)
    lastBundleId = bundleId
    let status = DaemonStatus(
      pid: Int(getpid()),
      deviceName: mapping.device.name,
      connected: !devices.isEmpty,
      layer: currentLayer,
      layerModifier: layerHoldActive,
      profileName: profile?.name,
      bundleId: bundleId,
      lastEvent: lastEvent,
      keymapPopupToken: keymapPopupToken == 0 ? nil : keymapPopupToken,
      keymapPopupVisible: keymapPopupVisible,
      updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    statusPublisher.publish(status)
  }

  if devices.isEmpty {
    print("No HID devices found for vendorId=\(mapping.device.vendorId) productId=\(mapping.device.productId)")
    publishStatus(lastEvent: "no devices found")
    return
  }
  if let server = startActiveAppServer(state: activeAppState, onUpdate: { newBundleId in
    if newBundleId != lastBundleId {
      publishStatus(lastEvent: "app switched")
    }
  }) {
    listeners.append(server)
  }
  if let statusServer = startStatusServer(publisher: statusPublisher) {
    listeners.append(statusServer)
  }

  func emit(_ event: InputEvent) {
    if config.logInputEvents {
      if let value = event.value {
        print("[\(event.state)] \(event.inputId) value=\(value) layer=\(event.layer) mod=\(event.layerModifier)")
      } else {
        print("[\(event.state)] \(event.inputId) layer=\(event.layer) mod=\(event.layerModifier)")
      }
    }
    let suffix = event.value != nil ? " value=\(event.value ?? 0)" : ""
    publishStatus(lastEvent: "\(event.inputId) \(event.state)\(suffix)")
  }

  @discardableResult
  func writeLightingReport(_ request: [UInt8], eventName: String) -> [UInt8]? {
    guard config.enableLighting else {
      return nil
    }
    guard !lightingListeners.isEmpty else {
      return nil
    }

    var lastError: Error?
    for offset in 0..<lightingListeners.count {
      let index = (activeLightingListenerIndex + offset) % lightingListeners.count
      let listener = lightingListeners[index]
      do {
        try listener.setReport(type: .feature, reportId: 0, bytes: request)
        let response = try listener.getReport(
          type: .feature,
          reportId: 0,
          length: TartarusProLightingProtocol.reportLength
        )
        activeLightingListenerIndex = index
        if !TartarusProLightingProtocol.isSuccessfulResponse(response), config.logInputEvents {
          print("[lighting] \(eventName) non-success status=\(response.first ?? 0)")
        }
        return response
      } catch {
        lastError = error
      }
    }

    if let lastError {
      print("Lighting transport error: \(lastError.localizedDescription)")
    }
    return nil
  }

  func applyLayerLighting(_ layer: Int) {
    let request = TartarusProLightingProtocol.profileIndicatorReport(layer: layer)
    writeLightingReport(request, eventName: "layer=\(layer)")
  }

  func lightingEffectPayload(
    effect: TartarusProLightingEffect,
    color1: TartarusProLightingColor?,
    color2: TartarusProLightingColor?,
    speed: Int?
  ) -> (packet: [UInt8], color1Hex: String, color2Hex: String, speed: UInt8) {
    let resolvedColor1 = color1 ?? TartarusProLightingColor(r: 0x00, g: 0xFF, b: 0x00)
    let resolvedColor2 = color2 ?? TartarusProLightingColor(r: 0x00, g: 0x00, b: 0xFF)
    let resolvedSpeed = UInt8(max(0, min(255, speed ?? 2)))
    let packet = TartarusProLightingProtocol.matrixEffectReport(
      effect: effect,
      primaryColor: resolvedColor1,
      secondaryColor: resolvedColor2,
      speed: resolvedSpeed
    )
    let color1Hex = String(format: "%02X%02X%02X", resolvedColor1.r, resolvedColor1.g, resolvedColor1.b)
    let color2Hex = String(format: "%02X%02X%02X", resolvedColor2.r, resolvedColor2.g, resolvedColor2.b)
    return (packet: packet, color1Hex: color1Hex, color2Hex: color2Hex, speed: resolvedSpeed)
  }

  func handleLightingControl(_ request: DaemonControlRequest) -> DaemonControlResponse {
    guard request.command == "lighting" else {
      return DaemonControlResponse(ok: false, message: "Unknown command '\(request.command)'.", readbackHex: nil)
    }
    guard config.enableLighting else {
      return DaemonControlResponse(ok: false, message: "Lighting is disabled in daemon config.", readbackHex: nil)
    }
    guard !lightingListeners.isEmpty else {
      return DaemonControlResponse(ok: false, message: "No lighting interface is open.", readbackHex: nil)
    }

    var summary: [String] = []
    var readbackHex: String?

    if let brightness = request.brightness {
      guard (0...255).contains(brightness) else {
        return DaemonControlResponse(ok: false, message: "Invalid brightness \(brightness).", readbackHex: nil)
      }
      let packet = TartarusProLightingProtocol.brightnessReport(value: UInt8(brightness))
      guard let response = writeLightingReport(packet, eventName: "control brightness=\(brightness)") else {
        return DaemonControlResponse(ok: false, message: "Failed to write brightness packet.", readbackHex: nil)
      }
      summary.append("brightness=\(brightness) status=\(response.first ?? 0)")
    }

    if let staticColorHex = request.staticColorHex {
      guard let color = TartarusProLightingColor.fromHexString(staticColorHex) else {
        return DaemonControlResponse(ok: false, message: "Invalid static color '\(staticColorHex)'.", readbackHex: nil)
      }
      let packet = TartarusProLightingProtocol.staticEffectReport(color: color)
      guard let response = writeLightingReport(packet, eventName: "control static=\(staticColorHex)") else {
        return DaemonControlResponse(ok: false, message: "Failed to write static color packet.", readbackHex: nil)
      }
      summary.append(
        "static=\(String(format: "%02X%02X%02X", color.r, color.g, color.b)) status=\(response.first ?? 0)"
      )
    }

    if let layer = request.layer {
      guard (1...3).contains(layer) else {
        return DaemonControlResponse(ok: false, message: "Invalid layer \(layer).", readbackHex: nil)
      }
      let color = TartarusProLightingColor.layerIndicator(layer: layer)
      let packet = TartarusProLightingProtocol.profileIndicatorReport(layer: layer)
      guard let response = writeLightingReport(packet, eventName: "control layer=\(layer)") else {
        return DaemonControlResponse(ok: false, message: "Failed to write layer indicator packet.", readbackHex: nil)
      }
      summary.append(
        "layer=\(layer) color=\(String(format: "%02X%02X%02X", color.r, color.g, color.b)) status=\(response.first ?? 0)"
      )
    }

    if let effectRaw = request.effect {
      guard let effect = TartarusProLightingEffect.fromString(effectRaw) else {
        return DaemonControlResponse(ok: false, message: "Invalid effect '\(effectRaw)'.", readbackHex: nil)
      }
      if let rawColor1 = request.effectColorHex1, TartarusProLightingColor.fromHexString(rawColor1) == nil {
        return DaemonControlResponse(ok: false, message: "Invalid effectColorHex1 '\(rawColor1)'.", readbackHex: nil)
      }
      if let rawColor2 = request.effectColorHex2, TartarusProLightingColor.fromHexString(rawColor2) == nil {
        return DaemonControlResponse(ok: false, message: "Invalid effectColorHex2 '\(rawColor2)'.", readbackHex: nil)
      }
      let color1 = request.effectColorHex1.flatMap { TartarusProLightingColor.fromHexString($0) }
      let color2 = request.effectColorHex2.flatMap { TartarusProLightingColor.fromHexString($0) }
      let payload = lightingEffectPayload(
        effect: effect,
        color1: color1,
        color2: color2,
        speed: request.effectSpeed
      )
      guard let response = writeLightingReport(
        payload.packet,
        eventName: "control effect=\(effect.rawValue) color1=\(payload.color1Hex) color2=\(payload.color2Hex) speed=\(payload.speed)"
      ) else {
        return DaemonControlResponse(ok: false, message: "Failed to write effect packet.", readbackHex: nil)
      }
      summary.append(
        "effect=\(effect.rawValue) color1=\(payload.color1Hex) color2=\(payload.color2Hex) speed=\(payload.speed) status=\(response.first ?? 0)"
      )
    }

    if request.readback == true {
      let packet = TartarusProLightingProtocol.getStaticEffectReport()
      guard let response = writeLightingReport(packet, eventName: "control readback") else {
        return DaemonControlResponse(ok: false, message: "Failed to read back static color.", readbackHex: nil)
      }
      if let color = TartarusProLightingProtocol.parseStaticColor(from: response) {
        readbackHex = String(format: "%02X%02X%02X", color.r, color.g, color.b)
        summary.append("readback=\(readbackHex ?? "unknown") status=\(response.first ?? 0)")
      } else {
        summary.append("readback parse failed status=\(response.first ?? 0)")
      }
    }

    if summary.isEmpty {
      return DaemonControlResponse(
        ok: false,
        message: "No lighting fields supplied. Provide brightness, staticColorHex, layer, effect, or readback.",
        readbackHex: nil
      )
    }

    return DaemonControlResponse(ok: true, message: summary.joined(separator: " | "), readbackHex: readbackHex)
  }

  if let controlServer = startControlServer(handler: { request in
    handleLightingControl(request)
  }) {
    listeners.append(controlServer)
  }

  func toggleLayerIfNeeded() {
    if layerUsedAsModifier {
      return
    }
    currentLayer = currentLayer % 3 + 1
    if config.logInputEvents {
      print("[layer] switched to \(currentLayer)")
    }
    applyLayerLighting(currentLayer)
    publishStatus(lastEvent: "layer switched to \(currentLayer)")
  }

  func effectiveLayer() -> Int {
    if layerHoldActive {
      return currentLayer % 3 + 1
    }
    return currentLayer
  }

  func effectiveDpadInput() -> String? {
    let up = dpadPressed.contains("dpad.up")
    let down = dpadPressed.contains("dpad.down")
    let left = dpadPressed.contains("dpad.left")
    let right = dpadPressed.contains("dpad.right")
    if up && left { return "dpad.up_left" }
    if up && right { return "dpad.up_right" }
    if down && left { return "dpad.down_left" }
    if down && right { return "dpad.down_right" }
    if up { return "dpad.up" }
    if down { return "dpad.down" }
    if left { return "dpad.left" }
    if right { return "dpad.right" }
    return nil
  }

  func executeAction(
    inputId: String,
    state: String,
    profile: LayeredProfile,
    macroLookup: [UUID: Macro]
  ) {
    guard let action = resolveAction(profile: profile, layer: effectiveLayer(), inputId: inputId) else {
      return
    }

    switch action.type {
    case .disabled:
      return
    case .key:
      if state == "released" && !config.injectOnRelease {
        return
      }
      guard let keyCode = action.keyCode else {
        return
      }
      let isDown = state == "pressed"
      injector.sendKey(usage: keyCode, modifiers: action.modifiers, isDown: isDown)
    case .macro:
      guard state == "pressed" else {
        return
      }
      guard let macroId = action.macroId, let macro = macroLookup[macroId] else {
        return
      }
      macroRunner.run(macro)
    case .scroll:
      return
    }
  }

  func handleDpad(
    inputId: String,
    state: String,
    mode: DPadMode,
    profile: LayeredProfile,
    macroLookup: [UUID: Macro]
  ) -> Bool {
    let baseIds: Set<String> = ["dpad.up", "dpad.down", "dpad.left", "dpad.right"]
    guard baseIds.contains(inputId) else { return false }
    if mode == .fourWay {
      return false
    }
    if state == "pressed" {
      dpadPressed.insert(inputId)
    } else if state == "released" {
      dpadPressed.remove(inputId)
    }
    let effective = effectiveDpadInput()
    if effective != lastDpadEffective {
      if let prev = lastDpadEffective {
        executeAction(inputId: prev, state: "released", profile: profile, macroLookup: macroLookup)
      }
      if let next = effective {
        executeAction(inputId: next, state: "pressed", profile: profile, macroLookup: macroLookup)
      }
      lastDpadEffective = effective
    }
    return true
  }

  func handleAxisAction(inputId: String, value: Int) {
    let (profilesConfig, macroLookup) = runtime.snapshot()
    let bundleId = activeAppState.get()
    guard enableOutput, let profile = resolveProfile(config: profilesConfig, bundleId: bundleId) else {
      return
    }
    let directionId: String?
    if value > 0 {
      directionId = "wheel.up"
    } else if value < 0 {
      directionId = "wheel.down"
    } else {
      directionId = nil
    }

    if let dir = directionId,
       let dirAction = resolveAction(profile: profile, layer: effectiveLayer(), inputId: dir),
       dirAction.type != .disabled {
      switch dirAction.type {
      case .disabled:
        return
      case .key:
        guard let keyCode = dirAction.keyCode else { return }
        injector.sendKeyPress(usage: keyCode, modifiers: dirAction.modifiers)
      case .macro:
        guard let macroId = dirAction.macroId, let macro = macroLookup[macroId] else { return }
        macroRunner.run(macro)
      case .scroll:
        let multiplier = dirAction.scrollMultiplier ?? 1
        injector.sendScroll(delta: value * multiplier)
      }
      return
    }

    guard let action = resolveAction(profile: profile, layer: effectiveLayer(), inputId: inputId) else {
      return
    }

    switch action.type {
    case .disabled:
      return
    case .key:
      guard let keyCode = action.keyCode else { return }
      injector.sendKeyPress(usage: keyCode, modifiers: action.modifiers)
    case .macro:
      guard let macroId = action.macroId, let macro = macroLookup[macroId] else { return }
      macroRunner.run(macro)
    case .scroll:
      let multiplier = action.scrollMultiplier ?? 1
      injector.sendScroll(delta: value * multiplier)
    }
  }

  func handleAction(inputId: String, state: String) {
    let (profilesConfig, macroLookup) = runtime.snapshot()
    let bundleId = activeAppState.get()
    guard enableOutput, let profile = resolveProfile(config: profilesConfig, bundleId: bundleId) else {
      return
    }

    let dpadMode = profile.dpadMode ?? .fourWay
    if handleDpad(inputId: inputId, state: state, mode: dpadMode, profile: profile, macroLookup: macroLookup) {
      return
    }

    executeAction(inputId: inputId, state: state, profile: profile, macroLookup: macroLookup)
  }

  func modifiersFromFlags(_ flags: CGEventFlags) -> [HIDModifier] {
    var modifiers: [HIDModifier] = []
    if flags.contains(.maskControl) { modifiers.append(.leftControl) }
    if flags.contains(.maskShift) { modifiers.append(.leftShift) }
    if flags.contains(.maskAlternate) { modifiers.append(.leftAlt) }
    if flags.contains(.maskCommand) { modifiers.append(.leftGUI) }
    return normalizedModifiers(modifiers)
  }

  func keyCodeToUsage(_ keyCode: CGKeyCode) -> Int? {
    HIDKeyMap.usage(forKeyCode: Int(keyCode))
  }

  if enableOutput {
    eventTap = KeyEventTap { type, event in
      guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passRetained(event)
      }

      let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let keyboardType = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
      if config.logTapAll {
        let flags = event.flags
        let kind = type == .keyDown ? "down" : "up"
        let sourceTag = event.getIntegerValueField(.eventSourceUserData)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
        print("[tap] \(kind) keyCode=\(keyCode) keyboardType=\(keyboardType) flags=\(flags.rawValue) source=\(sourceTag) repeat=\(isRepeat)")
      }

      if event.getIntegerValueField(.eventSourceUserData) == EventInjector.sourceTag {
        return Unmanaged.passRetained(event)
      }

      guard let usage = keyCodeToUsage(keyCode) else {
        return Unmanaged.passRetained(event)
      }

      if config.logKeyboardType {
        let flags = event.flags
        let kind = type == .keyDown ? "down" : "up"
        print("[tap] \(kind) keyCode=\(keyCode) keyboardType=\(keyboardType) flags=\(flags.rawValue)")
      }

      if let suppressType = tartarusKeyboardType, keyboardType == suppressType {
        return nil
      }

      if tartarusKeyboardType == nil, mappedUsages.contains(usage) {
        tartarusKeyboardType = keyboardType
        if config.logKeyboardType || config.logTapAll {
          print("[tap] learned keyboardType=\(keyboardType) for mapped usage \(usage)")
        }
        return nil
      }

      if config.suppressMapped, suppressedKeys.contains(keyCode) {
        return nil
      }

      if config.suppressMapped, suppressor.shouldSuppressKeyCode(keyCode) {
        return nil
      }

      let flags = event.flags
      let modifiers = modifiersFromFlags(flags)
      let candidates = [
        InputKey(interface: 2, usagePage: 7, usage: usage, modifiers: modifiers),
        InputKey(interface: 0, usagePage: 7, usage: usage, modifiers: modifiers)
      ]

      if config.suppressMapped {
        for key in candidates {
          if lookup[key] != nil {
            return nil
          }
          if suppressor.shouldSuppress(key) {
            return nil
          }
          let unmodified = InputKey(
            interface: key.interface,
            usagePage: key.usagePage,
            usage: key.usage,
            modifiers: []
          )
          if suppressor.shouldSuppress(unmodified) {
            return nil
          }
        }
      }

      return Unmanaged.passRetained(event)
    }
    eventTap?.start()
  }

  func startWithFallback(_ start: (IOOptionBits) throws -> Void) throws {
    do {
      try start(openOptions)
    } catch {
      if config.seize && config.seizeFallback {
        seizeFallbackInterfaceCount += 1
        try start(IOOptionBits(kIOHIDOptionsTypeNone))
      } else {
        throw error
      }
    }
  }

  func lightingDeviceKey(_ device: HIDDevice) -> String {
    let info = device.info
    let featureIds = device.reportIDs(for: .feature)
      .map(String.init)
      .joined(separator: ",")
    return "\(info.vendorId):\(info.productId):\(info.locationId):\(info.usagePage):\(info.usage):\(device.inputReportSize()):\(device.maxReportSize(for: .feature)):\(featureIds)"
  }

  for interfaceIndex in usedInterfaces.sorted() {
    guard let device = deviceByInterface[interfaceIndex] else {
      print("Mapping references interface \(interfaceIndex), but no matching HID interface was classified.")
      continue
    }

    let hasAxis = mapping.inputs.values.contains {
      $0.hid.interface == interfaceIndex && $0.kind == .axis
    }

    let hasKeys = mapping.inputs.values.contains {
      $0.hid.interface == interfaceIndex && $0.kind == .button && $0.hid.usagePage == 7
    }

    if hasAxis {
      let listener = HIDValueListener(device: device)
      try startWithFallback { options in
        try listener.start(handler: { event in
          let key = InputKey(
            interface: interfaceIndex,
            usagePage: event.usagePage,
            usage: event.usage,
            modifiers: []
          )

          guard let inputId = lookup[key] else {
            return
          }

          if event.intValue != 0 {
            emit(InputEvent(
              inputId: inputId,
              state: "axis",
              value: event.intValue,
              layer: effectiveLayer(),
              layerModifier: layerHoldActive
            ))
            if enableOutput {
              handleAxisAction(inputId: inputId, value: event.intValue)
            }
          }
        }, openOptions: options)
      }
      listeners.append(listener)
    }

    if hasKeys {
      let listener = HIDInputListener(device: device)
      try startWithFallback { options in
        try listener.start(handler: { report in
          guard let decoded = HIDKeyboardReportDecoder.decode(report: report.bytes) else {
            return
          }

          let modifiers = Set(HIDModifierSet.toModifiers(decoded.modifiers))
          let filteredModifiers = normalizedModifiers(modifiers.filter { $0 != .leftAlt })
          let keys = decoded.keys

          if interfaceIndex == 0 {
            let previous = previousModifiers[interfaceIndex] ?? Set()
            let hasLayerNow = modifiers.contains(.leftAlt)
            let hadLayer = previous.contains(.leftAlt)

            if hasLayerNow && !hadLayer {
              layerHoldActive = true
              layerUsedAsModifier = false
              layerPopupTriggered = false
              layerHoldTimer?.cancel()
              let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
              timer.schedule(deadline: .now() + 5.0)
              timer.setEventHandler {
                if layerHoldActive && !layerPopupTriggered {
                  layerPopupTriggered = true
                  keymapPopupVisible = true
                  keymapPopupToken += 1
                  publishStatus(lastEvent: "keymap popup")
                }
              }
              layerHoldTimer = timer
              timer.resume()
              if config.logInputEvents {
                print("[layer] hold start")
              }
            } else if !hasLayerNow && hadLayer {
              layerHoldActive = false
              layerHoldTimer?.cancel()
              layerHoldTimer = nil
              if !layerPopupTriggered {
                toggleLayerIfNeeded()
              }
              keymapPopupVisible = false
              if layerPopupTriggered {
                publishStatus(lastEvent: "keymap popup dismissed")
              }
              layerUsedAsModifier = false
              if config.logInputEvents {
                print("[layer] hold end")
              }
            }

            previousModifiers[interfaceIndex] = modifiers
          }

          let currentSet: Set<InputKey> = Set(keys.map { key in
            InputKey(
              interface: interfaceIndex,
              usagePage: 7,
              usage: Int(key),
              modifiers: filteredModifiers
            )
          })

          let previous = previousKeys[interfaceIndex] ?? Set()
          let pressed = currentSet.subtracting(previous)
          let released = previous.subtracting(currentSet)
          previousKeys[interfaceIndex] = currentSet

          if layerHoldActive, !pressed.isEmpty {
            layerUsedAsModifier = true
          }

          func recordSuppression(_ key: InputKey) {
            suppressor.record(key)
            if !key.modifiers.isEmpty {
              let unmodified = InputKey(
                interface: key.interface,
                usagePage: key.usagePage,
                usage: key.usage,
                modifiers: []
              )
              suppressor.record(unmodified)
            }
            if let keyCode = HIDKeyMap.keyCode(forUsage: key.usage) {
              suppressor.recordKeyCode(CGKeyCode(keyCode))
            }
          }

          for key in pressed {
            if let inputId = lookup[key] {
              if let keyCode = HIDKeyMap.keyCode(forUsage: key.usage), config.suppressMapped {
                suppressedKeys.add(CGKeyCode(keyCode))
              }
              let event = InputEvent(
                inputId: inputId,
                state: "pressed",
                value: nil,
                layer: effectiveLayer(),
                layerModifier: layerHoldActive
              )
              emit(event)
              if enableOutput {
                recordSuppression(key)
              }
              handleAction(inputId: inputId, state: "pressed")
            }
          }

          for key in released {
            if let inputId = lookup[key] {
              if let keyCode = HIDKeyMap.keyCode(forUsage: key.usage), config.suppressMapped {
                suppressedKeys.remove(CGKeyCode(keyCode))
              }
              let event = InputEvent(
                inputId: inputId,
                state: "released",
                value: nil,
                layer: effectiveLayer(),
                layerModifier: layerHoldActive
              )
              emit(event)
              if enableOutput {
                recordSuppression(key)
              }
              handleAction(inputId: inputId, state: "released")
            }
          }
        }, openOptions: options)
      }
      let featureIds = device.reportIDs(for: .feature)
      if !featureIds.isEmpty {
        lightingListeners.append(listener)
        openedLightingDeviceKeys.insert(lightingDeviceKey(device))
      }
      listeners.append(listener)
    }
  }

  if config.enableLighting && lightingListeners.isEmpty {
    for device in devices {
      let deviceKey = lightingDeviceKey(device)
      guard !openedLightingDeviceKeys.contains(deviceKey) else {
        continue
      }
      let featureIds = device.reportIDs(for: .feature)
      let maxFeatureSize = device.maxReportSize(for: .feature)
      guard !featureIds.isEmpty || maxFeatureSize > 0 else {
        continue
      }

      let listener = HIDInputListener(device: device)
      do {
        try startWithFallback { options in
          try listener.start(handler: { _ in }, openOptions: options)
        }
        lightingListeners.append(listener)
        listeners.append(listener)
        openedLightingDeviceKeys.insert(deviceKey)
        if config.logInputEvents {
          let info = device.info
          print("[lighting] opened dedicated listener vendor=\(info.vendorId) product=\(info.productId) location=\(info.locationId) usagePage=\(info.usagePage) usage=\(info.usage) featureIds=\(featureIds)")
        }
      } catch {
        if config.logInputEvents {
          let info = device.info
          print("[lighting] failed to open dedicated listener vendor=\(info.vendorId) product=\(info.productId) location=\(info.locationId) usagePage=\(info.usagePage) usage=\(info.usage): \(error.localizedDescription)")
        }
      }
    }
  }

  if config.enableLighting, let brightness = config.lightingBrightness {
    let request = TartarusProLightingProtocol.brightnessReport(value: brightness)
    writeLightingReport(request, eventName: "brightness=\(brightness)")
  }

  if config.enableLighting, let staticColor = config.lightingStaticColor {
    let request = TartarusProLightingProtocol.staticEffectReport(color: staticColor)
    writeLightingReport(
      request,
      eventName: "startup static=\(String(format: "%02X%02X%02X", staticColor.r, staticColor.g, staticColor.b))"
    )
  }

  if config.enableLighting, let effect = config.lightingEffect {
    let payload = lightingEffectPayload(
      effect: effect,
      color1: config.lightingEffectColor1,
      color2: config.lightingEffectColor2,
      speed: config.lightingEffectSpeed.map { Int($0) }
    )
    writeLightingReport(
      payload.packet,
      eventName: "startup effect=\(effect.rawValue) color1=\(payload.color1Hex) color2=\(payload.color2Hex) speed=\(payload.speed)"
    )
  }

  if config.enableLighting {
    applyLayerLighting(currentLayer)
  }

  if listeners.isEmpty {
    print("No listeners started. Check mapping inputs.")
    publishStatus(lastEvent: "no listeners started")
    return
  }

  let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  signal(SIGINT, SIG_IGN)
  signalSource.setEventHandler {
    eventTap?.stop()
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
  signalSource.resume()

  let reloadSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
  signal(SIGUSR1, SIG_IGN)
  reloadSource.setEventHandler {
    let profiles = try? loadProfiles(config: config)
    let macros = (try? loadMacros(config: config)) ?? MacroLibrary(macros: [])
    let updatedMacros = Dictionary(uniqueKeysWithValues: macros.macros.map { ($0.id, $0) })
    runtime.update(profilesConfig: profiles, macroLookup: updatedMacros)
    print("[reload] profiles and macros reloaded")
    publishStatus(lastEvent: "reloaded profiles/macros")
  }
  reloadSource.resume()

  if seizeFallbackInterfaceCount > 0 {
    print("Seize failed for \(seizeFallbackInterfaceCount) interface(s); continuing without seize.")
  }
  print("GehennaDaemon running. Ctrl+C to stop.")
  publishStatus(lastEvent: "daemon started")
  CFRunLoopRun()
}

func classifyInterfaces(devices: [HIDDevice]) -> [Int: HIDDevice] {
  var result: [Int: HIDDevice] = [:]

  for device in devices {
    let elements = device.elements()
    let hasWheel = elements.contains { element in
      element.usagePage == 0x01 && element.usage == 0x38
    }
    let reportSize = device.inputReportSize()

    if hasWheel, result[1] == nil {
      result[1] = device
      continue
    }

    if reportSize <= 8, result[0] == nil {
      result[0] = device
      continue
    }

    if result[2] == nil {
      result[2] = device
    }
  }

  return result
}

public func runGehennaDaemon(arguments: [String] = CommandLine.arguments) -> Int32 {
  _ = signal(SIGPIPE, SIG_IGN)
  setbuf(stdout, nil)
  setbuf(stderr, nil)
  let execPath = arguments.first ?? "(unknown)"
  let argList = arguments.dropFirst().joined(separator: " ")
  print("[startup] exec=\(execPath) pid=\(getpid()) ppid=\(getppid()) uid=\(getuid()) euid=\(geteuid()) args=\(argList)")
  let config = parseArgs(arguments: arguments)
  do {
    let mapping = try loadMapping(config: config)
    print("Loaded mapping: \(mapping.layout.name) for \(mapping.device.name)")
    let profiles = try? loadProfiles(config: config)
    let macros = (try? loadMacros(config: config)) ?? MacroLibrary(macros: [])
    if profiles != nil {
      print("Loaded profiles.")
    } else {
      print("No profiles loaded (output disabled).")
    }
    if config.enableOutput {
      print("Output injection enabled.")
    } else {
      print("Output injection disabled.")
    }
    if config.enableLighting {
      var components: [String] = []
      if let brightness = config.lightingBrightness {
        components.append("brightness=\(brightness)")
      }
      if let staticColor = config.lightingStaticColor {
        components.append("static=\(String(format: "%02X%02X%02X", staticColor.r, staticColor.g, staticColor.b))")
      }
      if let effect = config.lightingEffect {
        components.append("effect=\(effect.rawValue)")
      }
      if let color1 = config.lightingEffectColor1 {
        components.append("effectColor1=\(String(format: "%02X%02X%02X", color1.r, color1.g, color1.b))")
      }
      if let color2 = config.lightingEffectColor2 {
        components.append("effectColor2=\(String(format: "%02X%02X%02X", color2.r, color2.g, color2.b))")
      }
      if let speed = config.lightingEffectSpeed {
        components.append("effectSpeed=\(speed)")
      }
      if components.isEmpty {
        print("Lighting enabled.")
      } else {
        print("Lighting enabled (\(components.joined(separator: ", "))).")
      }
    } else {
      print("Lighting disabled.")
    }
    if config.seize {
      if config.seizeFallback {
        print("Seize mode enabled (fallback allowed).")
      } else {
        print("Seize mode enabled (strict).")
      }
    }
    try startDaemon(mapping: mapping, profiles: profiles, macros: macros, config: config)
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}
