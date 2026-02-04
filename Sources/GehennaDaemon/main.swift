import Foundation
import GehennaCore
import GehennaHID

struct DaemonConfig {
  let mappingPath: String?
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

func parseArgs() -> DaemonConfig {
  var args = CommandLine.arguments
  args.removeFirst()

  var mappingPath: String?
  var index = 0
  while index < args.count {
    let arg = args[index]
    switch arg {
    case "--mapping":
      index += 1
      if index < args.count {
        mappingPath = args[index]
      }
    default:
      break
    }
    index += 1
  }

  return DaemonConfig(mappingPath: mappingPath)
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

func startDaemon(mapping: DeviceMapping) throws {
  let lookup = buildLookup(mapping: mapping)
  let match = HIDMatch(vendorId: mapping.device.vendorId, productId: mapping.device.productId)
  let devices = try HIDEnumerator().openDevices(match: match)

  if devices.isEmpty {
    print("No HID devices found for vendorId=\(mapping.device.vendorId) productId=\(mapping.device.productId)")
    return
  }

  let deviceByInterface = classifyInterfaces(devices: devices)
  let usedInterfaces = Set(mapping.inputs.values.map { $0.hid.interface })
  var listeners: [AnyObject] = []
  var previousKeys: [Int: Set<InputKey>] = [:]
  var previousModifiers: [Int: Set<HIDModifier>] = [:]
  var currentLayer = 1
  var layerHoldActive = false
  var layerUsedAsModifier = false

  func emit(_ event: InputEvent) {
    if let value = event.value {
      print("[\(event.state)] \(event.inputId) value=\(value) layer=\(event.layer) mod=\(event.layerModifier)")
    } else {
      print("[\(event.state)] \(event.inputId) layer=\(event.layer) mod=\(event.layerModifier)")
    }
  }

  func toggleLayerIfNeeded() {
    if layerUsedAsModifier {
      return
    }
    currentLayer = currentLayer % 3 + 1
    print("[layer] switched to \(currentLayer)")
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
      try listener.start { event in
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
            layer: currentLayer,
            layerModifier: layerHoldActive
          ))
        }
      }
      listeners.append(listener)
    }

    if hasKeys {
      let listener = HIDInputListener(device: device)
      try listener.start { report in
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

        for key in pressed {
          if let inputId = lookup[key] {
            emit(InputEvent(
              inputId: inputId,
              state: "pressed",
              value: nil,
              layer: currentLayer,
              layerModifier: layerHoldActive
            ))
          }
        }

        for key in released {
          if let inputId = lookup[key] {
            emit(InputEvent(
              inputId: inputId,
              state: "released",
              value: nil,
              layer: currentLayer,
              layerModifier: layerHoldActive
            ))
          }
        }
      }
      listeners.append(listener)
    }
  }

  if listeners.isEmpty {
    print("No listeners started. Check mapping inputs.")
    return
  }

  let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  signal(SIGINT, SIG_IGN)
  signalSource.setEventHandler {
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
  signalSource.resume()

  print("GehennaDaemon running. Ctrl+C to stop.")
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
  let config = parseArgs()
  do {
    let mapping = try loadMapping(config: config)
    print("Loaded mapping: \(mapping.layout.name) for \(mapping.device.name)")
    try startDaemon(mapping: mapping)
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

exit(run())
