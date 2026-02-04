import Foundation
import GehennaHID

struct CommonFilter {
  var vendorId: Int?
  var productId: Int?
  var usagePage: Int?
  var usage: Int?
}

struct ListOptions {
  var filter = CommonFilter()
  var jsonOutput = false
}

struct DescribeOptions {
  var filter = CommonFilter()
  var index: Int?
}

struct ListenOptions {
  var filter = CommonFilter()
  var index: Int?
  var duration: TimeInterval?
  var mode: ListenMode = .reports
  var decode = false
}

enum Command {
  case list(ListOptions)
  case describe(DescribeOptions)
  case listen(ListenOptions)
}

enum ListenMode {
  case reports
  case values
}

func printUsage() {
  let usage = """
  GehennaCLI - HID tooling for Gehenna

  Usage:
    GehennaCLI list [--vendor <id>] [--product <id>] [--usagePage <id>] [--usage <id>] [--json]
    GehennaCLI describe [--vendor <id>] [--product <id>] [--index <n>]
    GehennaCLI listen [--vendor <id>] [--product <id>] [--index <n>] [--duration <sec>] [--values] [--decode]

  Examples:
    GehennaCLI list
    GehennaCLI list --vendor 0x1532 --product 0x0244
    GehennaCLI describe --vendor 0x1532 --product 0x0244 --index 0
    GehennaCLI listen --vendor 0x1532 --product 0x0244 --index 0
    GehennaCLI listen --vendor 0x1532 --product 0x0244 --index 1 --values --decode
  """
  print(usage)
}

func parseInt(_ value: String) -> Int? {
  if value.lowercased().hasPrefix("0x") {
    let hex = String(value.dropFirst(2))
    return Int(hex, radix: 16)
  }
  return Int(value)
}

func parseCommon(args: [String], indexStart: Int) -> (CommonFilter, Int, String?) {
  var filter = CommonFilter()
  var index = indexStart
  while index < args.count {
    let arg = args[index]
    switch arg {
    case "--vendor":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        return (filter, index, "Invalid --vendor value")
      }
      filter.vendorId = value
    case "--product":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        return (filter, index, "Invalid --product value")
      }
      filter.productId = value
    case "--usagePage":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        return (filter, index, "Invalid --usagePage value")
      }
      filter.usagePage = value
    case "--usage":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        return (filter, index, "Invalid --usage value")
      }
      filter.usage = value
    default:
      return (filter, index, nil)
    }
    index += 1
  }

  return (filter, index, nil)
}

func parseArgs() -> Command? {
  var args = CommandLine.arguments
  args.removeFirst()

  if args.isEmpty || args.first == "-h" || args.first == "--help" {
    printUsage()
    return nil
  }

  let command = args[0]
  switch command {
  case "list":
    var options = ListOptions()
    var index = 1
    while index < args.count {
      let arg = args[index]
      if arg == "--json" {
        options.jsonOutput = true
        index += 1
        continue
      }

      let (filter, newIndex, error) = parseCommon(args: args, indexStart: index)
      if let error {
        print(error)
        return nil
      }
      if newIndex == index {
        print("Unknown argument: \(arg)")
        return nil
      }
      options.filter = filter
      index = newIndex
    }
    return .list(options)

  case "describe":
    var options = DescribeOptions()
    var index = 1
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--index":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value >= 0 else {
          print("Invalid --index value")
          return nil
        }
        options.index = value
        index += 1
        continue
      default:
        let (filter, newIndex, error) = parseCommon(args: args, indexStart: index)
        if let error {
          print(error)
          return nil
        }
        if newIndex == index {
          print("Unknown argument: \(arg)")
          return nil
        }
        options.filter = filter
        index = newIndex
        continue
      }
    }
    return .describe(options)

  case "listen":
    var options = ListenOptions()
    var index = 1
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--index":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value >= 0 else {
          print("Invalid --index value")
          return nil
        }
        options.index = value
        index += 1
        continue
      case "--duration":
        index += 1
        guard index < args.count, let value = Double(args[index]), value > 0 else {
          print("Invalid --duration value")
          return nil
        }
        options.duration = value
        index += 1
        continue
      case "--values":
        options.mode = .values
        index += 1
        continue
      case "--decode":
        options.decode = true
        index += 1
        continue
      default:
        let (filter, newIndex, error) = parseCommon(args: args, indexStart: index)
        if let error {
          print(error)
          return nil
        }
        if newIndex == index {
          print("Unknown argument: \(arg)")
          return nil
        }
        options.filter = filter
        index = newIndex
        continue
      }
    }
    return .listen(options)

  default:
    printUsage()
    return nil
  }
}

func hex(_ value: Int, width: Int = 4) -> String {
  String(format: "0x%0*X", width, value)
}

func decodeModifiers(_ value: UInt8) -> [String] {
  var result: [String] = []
  if value & 0x01 != 0 { result.append("L-Ctrl") }
  if value & 0x02 != 0 { result.append("L-Shift") }
  if value & 0x04 != 0 { result.append("L-Alt") }
  if value & 0x08 != 0 { result.append("L-GUI") }
  if value & 0x10 != 0 { result.append("R-Ctrl") }
  if value & 0x20 != 0 { result.append("R-Shift") }
  if value & 0x40 != 0 { result.append("R-Alt") }
  if value & 0x80 != 0 { result.append("R-GUI") }
  return result
}

func keyName(for usage: UInt8) -> String {
  switch usage {
  case 0x00: return "None"
  case 0x04...0x1D:
    if let scalar = UnicodeScalar(Int(usage) - 0x04 + 65) {
      return String(Character(scalar))
    }
    return String(format: "Key(0x%02X)", usage)
  case 0x1E...0x26:
    return String(Int(usage) - 0x1E + 1)
  case 0x27: return "0"
  case 0x28: return "Enter"
  case 0x29: return "Escape"
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
  case 0x39: return "CapsLock"
  case 0x3A...0x45:
    return "F\(Int(usage) - 0x39)"
  case 0x46: return "PrintScreen"
  case 0x47: return "ScrollLock"
  case 0x48: return "Pause"
  case 0x49: return "Insert"
  case 0x4A: return "Home"
  case 0x4B: return "PageUp"
  case 0x4C: return "Delete"
  case 0x4D: return "End"
  case 0x4E: return "PageDown"
  case 0x4F: return "RightArrow"
  case 0x50: return "LeftArrow"
  case 0x51: return "DownArrow"
  case 0x52: return "UpArrow"
  case 0x53: return "NumLock"
  case 0x54: return "Keypad /"
  case 0x55: return "Keypad *"
  case 0x56: return "Keypad -"
  case 0x57: return "Keypad +"
  case 0x58: return "Keypad Enter"
  case 0x59...0x61:
    return "Keypad \(Int(usage) - 0x59 + 1)"
  case 0x62: return "Keypad 0"
  case 0x63: return "Keypad ."
  case 0x64: return "NonUS \\|"
  case 0x65: return "App"
  case 0x66: return "Power"
  case 0x67: return "Keypad ="
  case 0x68...0x73:
    return "F\(Int(usage) - 0x67 + 13)"
  case 0x74: return "Execute"
  case 0x75: return "Help"
  case 0x76: return "Menu"
  case 0x77: return "Select"
  case 0x78: return "Stop"
  case 0x79: return "Again"
  case 0x7A: return "Undo"
  case 0x7B: return "Cut"
  case 0x7C: return "Copy"
  case 0x7D: return "Paste"
  case 0x7E: return "Find"
  case 0x7F: return "Mute"
  case 0x80: return "VolumeUp"
  case 0x81: return "VolumeDown"
  case 0xE0: return "L-Ctrl"
  case 0xE1: return "L-Shift"
  case 0xE2: return "L-Alt"
  case 0xE3: return "L-GUI"
  case 0xE4: return "R-Ctrl"
  case 0xE5: return "R-Shift"
  case 0xE6: return "R-Alt"
  case 0xE7: return "R-GUI"
  default:
    return String(format: "Key(0x%02X)", usage)
  }
}

func usageName(usagePage: Int, usage: Int) -> String {
  switch usagePage {
  case 0x01:
    switch usage {
    case 0x30: return "X"
    case 0x31: return "Y"
    case 0x32: return "Z"
    case 0x33: return "Rx"
    case 0x34: return "Ry"
    case 0x35: return "Rz"
    case 0x36: return "Slider"
    case 0x37: return "Dial"
    case 0x38: return "Wheel"
    case 0x39: return "HatSwitch"
    default:
      return "GenericDesktop(0x\(String(format: "%02X", usage)))"
    }
  case 0x07:
    return keyName(for: UInt8(truncatingIfNeeded: usage))
  case 0x09:
    return "Button \(usage)"
  case 0x0C:
    switch usage {
    case 0xE2: return "Mute"
    case 0xE9: return "VolumeUp"
    case 0xEA: return "VolumeDown"
    case 0xB5: return "ScanNextTrack"
    case 0xB6: return "ScanPreviousTrack"
    case 0xB7: return "Stop"
    case 0xCD: return "PlayPause"
    default:
      return "Consumer(0x\(String(format: "%02X", usage)))"
    }
  default:
    return "UsagePage(0x\(String(format: "%02X", usagePage))) Usage(0x\(String(format: "%02X", usage)))"
  }
}

func decodeKeyboardReport(_ report: HIDInputReport) -> String {
  guard report.bytes.count >= 3 else {
    return "Short report (\(report.bytes.count) bytes)"
  }

  let modifiers = decodeModifiers(report.bytes[0])
  let keys = report.bytes.dropFirst(2).filter { $0 != 0 }.map { keyName(for: $0) }

  if modifiers.isEmpty, keys.isEmpty {
    return "No keys"
  }

  var parts: [String] = []
  if !modifiers.isEmpty {
    parts.append("mods=\(modifiers.joined(separator: "+"))")
  }
  if !keys.isEmpty {
    parts.append("keys=\(keys.joined(separator: "+"))")
  }

  return parts.joined(separator: " ")
}

func renderTable(_ devices: [HIDDeviceInfo]) {
  if devices.isEmpty {
    print("No HID devices matched the filter.")
    return
  }

  for (index, device) in devices.enumerated() {
    let vendorHex = hex(device.vendorId)
    let productHex = hex(device.productId)
    print("[\(index)] \(vendorHex):\(productHex) \(device.product) [\(device.manufacturer)]")
    print("  transport=\(device.transport) usagePage=\(device.usagePage) usage=\(device.usage) locationId=\(device.locationId)")
  }
}

func renderJSON(_ devices: [HIDDeviceInfo]) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  do {
    let data = try encoder.encode(devices)
    if let string = String(data: data, encoding: .utf8) {
      print(string)
    }
  } catch {
    print("Failed to encode JSON: \(error.localizedDescription)")
  }
}

func matchFrom(filter: CommonFilter) -> HIDMatch {
  HIDMatch(
    vendorId: filter.vendorId,
    productId: filter.productId,
    usagePage: filter.usagePage,
    usage: filter.usage
  )
}

func selectDevice(from devices: [HIDDevice], index: Int?) -> HIDDevice? {
  if devices.isEmpty {
    print("No HID devices matched the filter.")
    return nil
  }

  if let index {
    guard index >= 0, index < devices.count else {
      print("Invalid index \(index). Available range: 0..\(devices.count - 1)")
      return nil
    }
    return devices[index]
  }

  if devices.count > 1 {
    print("Multiple devices matched. Provide --index:")
    for (idx, device) in devices.enumerated() {
      let info = device.info
      print("  [\(idx)] \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")
    }
    return nil
  }

  return devices[0]
}

func describeDevice(_ device: HIDDevice, index: Int) {
  let info = device.info
  print("Device [\(index)] \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")
  print("  transport=\(info.transport) usagePage=\(info.usagePage) usage=\(info.usage) locationId=\(info.locationId)")

  let elements = device.elements()
  print("  elements=\(elements.count)")

  for element in elements {
    let usagePage = "\(hex(element.usagePage, width: 2)) (\(element.usagePage))"
    let usage = "\(hex(element.usage, width: 2)) (\(element.usage))"
    print("  - type=\(element.type) usagePage=\(usagePage) usage=\(usage) reportId=\(element.reportId) size=\(element.reportSize) count=\(element.reportCount)")
  }
}

func runList(_ options: ListOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().listDevices(match: matchFrom(filter: options.filter))
    if options.jsonOutput {
      renderJSON(devices)
    } else {
      renderTable(devices)
    }
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runDescribe(_ options: DescribeOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    if let index = options.index {
      guard index >= 0, index < devices.count else {
        print("Invalid index \(index). Available range: 0..\(max(devices.count - 1, 0))")
        return 2
      }
      describeDevice(devices[index], index: index)
      return 0
    }

    if devices.isEmpty {
      print("No HID devices matched the filter.")
      return 1
    }

    for (idx, device) in devices.enumerated() {
      describeDevice(device, index: idx)
    }

    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runListen(_ options: ListenOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }

    let info = device.info
    print("Listening on \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")
    print("Press buttons or move controls. Ctrl+C to stop.")

    let stopHandler: () -> Void

    switch options.mode {
    case .reports:
      let listener = HIDInputListener(device: device)
      try listener.start { report in
        let bytes = report.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        if options.decode {
          let decoded = decodeKeyboardReport(report)
          print("[reportId=\(report.reportId) len=\(report.bytes.count)] \(decoded) raw=\(bytes)")
        } else {
          print("[reportId=\(report.reportId) len=\(report.bytes.count)] \(bytes)")
        }
      }
      stopHandler = {
        listener.stop()
      }
    case .values:
      let listener = HIDValueListener(device: device)
      try listener.start { event in
        let usagePage = hex(event.usagePage, width: 2)
        let usage = hex(event.usage, width: 2)
        if options.decode {
          let name = usageName(usagePage: event.usagePage, usage: event.usage)
          print("[\(name)] value=\(event.intValue) logical=\(event.logicalMin)...\(event.logicalMax) type=\(event.elementType) cookie=\(event.cookie)")
        } else {
          print("[usagePage=\(usagePage) usage=\(usage) value=\(event.intValue) logical=\(event.logicalMin)...\(event.logicalMax) type=\(event.elementType) cookie=\(event.cookie)]")
        }
      }
      stopHandler = {
        listener.stop()
      }
    }

    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
      stopHandler()
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    signalSource.resume()

    if let duration = options.duration {
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        stopHandler()
        CFRunLoopStop(CFRunLoopGetCurrent())
      }
    }

    CFRunLoopRun()
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func run() -> Int32 {
  guard let command = parseArgs() else {
    return 1
  }

  switch command {
  case let .list(options):
    return runList(options)
  case let .describe(options):
    return runDescribe(options)
  case let .listen(options):
    return runListen(options)
  }
}

exit(run())
