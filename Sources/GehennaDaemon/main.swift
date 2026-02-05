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
  let seizeFallback: Bool
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
  private var activeProfile: LayeredProfile?
  private var macroLookup: [UUID: Macro]

  init(activeProfile: LayeredProfile?, macroLookup: [UUID: Macro]) {
    self.activeProfile = activeProfile
    self.macroLookup = macroLookup
  }

  func update(activeProfile: LayeredProfile?, macroLookup: [UUID: Macro]) {
    queue.sync {
      self.activeProfile = activeProfile
      self.macroLookup = macroLookup
    }
  }

  func snapshot() -> (LayeredProfile?, [UUID: Macro]) {
    queue.sync {
      (activeProfile, macroLookup)
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

private let hidUsageToKeyCode: [Int: CGKeyCode] = [
  0x04: 0,   // A
  0x05: 11,  // B
  0x06: 8,   // C
  0x07: 2,   // D
  0x08: 14,  // E
  0x09: 3,   // F
  0x0A: 5,   // G
  0x0B: 4,   // H
  0x0C: 34,  // I
  0x0D: 38,  // J
  0x0E: 40,  // K
  0x0F: 37,  // L
  0x10: 46,  // M
  0x11: 45,  // N
  0x12: 31,  // O
  0x13: 35,  // P
  0x14: 12,  // Q
  0x15: 15,  // R
  0x16: 1,   // S
  0x17: 17,  // T
  0x18: 32,  // U
  0x19: 9,   // V
  0x1A: 13,  // W
  0x1B: 7,   // X
  0x1C: 16,  // Y
  0x1D: 6,   // Z
  0x1E: 18,  // 1
  0x1F: 19,  // 2
  0x20: 20,  // 3
  0x21: 21,  // 4
  0x22: 23,  // 5
  0x23: 22,  // 6
  0x24: 26,  // 7
  0x25: 28,  // 8
  0x26: 25,  // 9
  0x27: 29,  // 0
  0x28: 36,  // Enter
  0x29: 53,  // Escape
  0x2A: 51,  // Backspace
  0x2B: 48,  // Tab
  0x2C: 49,  // Space
  0x2D: 27,  // -
  0x2E: 24,  // =
  0x2F: 33,  // [
  0x30: 30,  // ]
  0x31: 42,  // \\
  0x33: 41,  // ;
  0x34: 39,  // '
  0x35: 50,  // `
  0x36: 43,  // ,
  0x37: 47,  // .
  0x38: 44,  // /
  0x39: 57,  // CapsLock
  0x3A: 122, // F1
  0x3B: 120, // F2
  0x3C: 99,  // F3
  0x3D: 118, // F4
  0x3E: 96,  // F5
  0x3F: 97,  // F6
  0x40: 98,  // F7
  0x41: 100, // F8
  0x42: 101, // F9
  0x43: 109, // F10
  0x44: 103, // F11
  0x45: 111, // F12
  0x4F: 124, // Right
  0x50: 123, // Left
  0x51: 125, // Down
  0x52: 126, // Up
  0xE0: 59,  // L-Ctrl
  0xE1: 56,  // L-Shift
  0xE2: 58,  // L-Alt
  0xE3: 55,  // L-GUI
  0xE4: 62,  // R-Ctrl
  0xE5: 60,  // R-Shift
  0xE6: 61,  // R-Alt
  0xE7: 54   // R-GUI
]

func normalizedModifiers(_ modifiers: [HIDModifier]?) -> [HIDModifier] {
  let list = modifiers ?? []
  return list.sorted {
    (modifierOrder.firstIndex(of: $0) ?? Int.max) < (modifierOrder.firstIndex(of: $1) ?? Int.max)
  }
}

func parseArgs() -> DaemonConfig {
  var args = CommandLine.arguments
  args.removeFirst()

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
  var seizeFallback = false
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
    seizeFallback: seizeFallback
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

func writeStatus(_ status: DaemonStatus) {
  guard let url = statusFileURL() else { return }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(status) else { return }
  let tmp = url.appendingPathExtension("tmp")
  do {
    try data.write(to: tmp, options: .atomic)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
  } catch {
    try? data.write(to: url, options: .atomic)
  }
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

func activeProfile(from config: ProfilesConfig) -> LayeredProfile? {
  if let activeId = config.activeProfileId {
    return config.profiles.first { $0.id == activeId }
  }
  return config.profiles.first
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
    guard let keyCode = hidUsageToKeyCode[usage] else {
      print("[inject] Unknown HID usage \(usage)")
      return
    }

    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
      return
    }

    event.flags = cgFlags(from: modifiers)
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
  var previousKeys: [Int: Set<InputKey>] = [:]
  var previousModifiers: [Int: Set<HIDModifier>] = [:]
  // currentLayer/layerHoldActive initialized above for status reporting.
  let injector = EventInjector()
  let macroRunner = MacroRunner(injector: injector)
  let macroLookup = Dictionary(uniqueKeysWithValues: macros.macros.map { ($0.id, $0) })
  let active = profiles.flatMap { activeProfile(from: $0) }
  let runtime = RuntimeState(activeProfile: active, macroLookup: macroLookup)
  let enableOutput = config.enableOutput && active != nil
  let suppressor = EventSuppressor(window: 0.15)
  let suppressedKeys = SuppressedKeySet()
  var eventTap: KeyEventTap?
  var tartarusKeyboardType: Int? = config.suppressKeyboardType
  let openOptions = config.seize
    ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    : IOOptionBits(kIOHIDOptionsTypeNone)

  if config.enableOutput && active == nil {
    print("Output enabled but no profiles loaded. Output will remain disabled.")
  }

  func publishStatus(lastEvent: String?) {
    let (profile, _) = runtime.snapshot()
    let status = DaemonStatus(
      pid: Int(getpid()),
      deviceName: mapping.device.name,
      connected: !devices.isEmpty,
      layer: currentLayer,
      layerModifier: layerHoldActive,
      profileName: profile?.name,
      lastEvent: lastEvent,
      updatedAt: ISO8601DateFormatter().string(from: Date())
    )
    writeStatus(status)
  }

  if devices.isEmpty {
    print("No HID devices found for vendorId=\(mapping.device.vendorId) productId=\(mapping.device.productId)")
    publishStatus(lastEvent: "no devices found")
    return
  }

  func emit(_ event: InputEvent) {
    if let value = event.value {
      print("[\(event.state)] \(event.inputId) value=\(value) layer=\(event.layer) mod=\(event.layerModifier)")
    } else {
      print("[\(event.state)] \(event.inputId) layer=\(event.layer) mod=\(event.layerModifier)")
    }
    let suffix = event.value != nil ? " value=\(event.value ?? 0)" : ""
    publishStatus(lastEvent: "\(event.inputId) \(event.state)\(suffix)")
  }

  func toggleLayerIfNeeded() {
    if layerUsedAsModifier {
      return
    }
    currentLayer = currentLayer % 3 + 1
    print("[layer] switched to \(currentLayer)")
    publishStatus(lastEvent: "layer switched to \(currentLayer)")
  }

  func effectiveLayer() -> Int {
    if layerHoldActive {
      return currentLayer % 3 + 1
    }
    return currentLayer
  }

  func handleAction(inputId: String, state: String) {
    let (profile, macroLookup) = runtime.snapshot()
    guard enableOutput, let profile else {
      return
    }

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
    }
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
    for (usage, code) in hidUsageToKeyCode where code == keyCode {
      return usage
    }
    return nil
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
        print("Seize failed for an interface (continuing without seize).")
        try start(IOOptionBits(kIOHIDOptionsTypeNone))
      } else {
        throw error
      }
    }
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
              print("[layer] hold start")
            } else if !hasLayerNow && hadLayer {
              layerHoldActive = false
              toggleLayerIfNeeded()
              layerUsedAsModifier = false
              print("[layer] hold end")
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
            if let keyCode = hidUsageToKeyCode[key.usage] {
              suppressor.recordKeyCode(keyCode)
            }
          }

          for key in pressed {
            if let inputId = lookup[key] {
              if let keyCode = hidUsageToKeyCode[key.usage], config.suppressMapped {
                suppressedKeys.add(keyCode)
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
              if let keyCode = hidUsageToKeyCode[key.usage], config.suppressMapped {
                suppressedKeys.remove(keyCode)
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
      listeners.append(listener)
    }
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
    let updatedProfile = profiles.flatMap { activeProfile(from: $0) }
    let updatedMacros = Dictionary(uniqueKeysWithValues: macros.macros.map { ($0.id, $0) })
    runtime.update(activeProfile: updatedProfile, macroLookup: updatedMacros)
    print("[reload] profiles and macros reloaded")
    publishStatus(lastEvent: "reloaded profiles/macros")
  }
  reloadSource.resume()

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

func run() -> Int32 {
  setbuf(stdout, nil)
  setbuf(stderr, nil)
  let config = parseArgs()
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

exit(run())
