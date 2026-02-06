import Foundation
import GehennaCore
import GehennaHID
import Darwin

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
  var seize = false
}

struct ReportsOptions {
  var filter = CommonFilter()
  var index: Int?
}

struct ReportGetOptions {
  var filter = CommonFilter()
  var index: Int?
  var type: HIDReportTypeKind = .feature
  var reportId: Int?
  var length: Int?
  var seize = false
}

struct ReportSetOptions {
  var filter = CommonFilter()
  var index: Int?
  var type: HIDReportTypeKind = .feature
  var reportId: Int?
  var data: [UInt8] = []
  var seize = false
}

struct LightingProbeOptions {
  var filter = CommonFilter(vendorId: 0x1532, productId: nil, usagePage: nil, usage: nil)
  var index: Int?
  var length: Int = 90
  var seize = false
  var outputPath: String?
}

struct LightingOptions {
  var filter = CommonFilter(vendorId: 0x1532, productId: nil, usagePage: nil, usage: nil)
  var index: Int?
  var staticColor: TartarusProLightingColor?
  var brightness: UInt8?
  var layer: Int?
  var effect: TartarusProLightingEffect?
  var effectColor1: TartarusProLightingColor?
  var effectColor2: TartarusProLightingColor?
  var effectSpeed: UInt8?
  var readback = false
  var seize = false
}

struct DaemonControlRequest: Codable {
  let command: String
  let staticColorHex: String?
  let brightness: Int?
  let layer: Int?
  let effect: String?
  let effectColorHex1: String?
  let effectColorHex2: String?
  let effectSpeed: Int?
  let readback: Bool?
}

struct DaemonControlResponse: Codable {
  let ok: Bool
  let message: String
  let readbackHex: String?
}

enum Command {
  case list(ListOptions)
  case describe(DescribeOptions)
  case listen(ListenOptions)
  case reports(ReportsOptions)
  case reportGet(ReportGetOptions)
  case reportSet(ReportSetOptions)
  case lightingProbe(LightingProbeOptions)
  case lighting(LightingOptions)
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
    GehennaCLI listen [--vendor <id>] [--product <id>] [--index <n>] [--duration <sec>] [--values] [--decode] [--seize]
    GehennaCLI reports [--vendor <id>] [--product <id>] [--index <n>]
    GehennaCLI report-get --id <n> [--type input|output|feature] [--length <n>] [--vendor <id>] [--product <id>] [--index <n>] [--seize]
    GehennaCLI report-set --id <n> --data <hex-bytes> [--type input|output|feature] [--vendor <id>] [--product <id>] [--index <n>] [--seize]
    GehennaCLI lighting-probe [--vendor <id>] [--product <id>] [--index <n>] [--length <n>] [--out <path>] [--seize]
    GehennaCLI lighting [--vendor <id>] [--product <id>] [--index <n>] [--static <RRGGBB>] [--brightness <0-255>] [--layer <1-3>] [--effect <name>] [--effect-color1 <RRGGBB>] [--effect-color2 <RRGGBB>] [--effect-speed <n>] [--readback] [--seize]

  Examples:
    GehennaCLI list
    GehennaCLI list --vendor 0x1532 --product 0x0244
    GehennaCLI describe --vendor 0x1532 --product 0x0244 --index 0
    GehennaCLI listen --vendor 0x1532 --product 0x0244 --index 0
    GehennaCLI listen --vendor 0x1532 --product 0x0244 --index 1 --values --decode --seize
    GehennaCLI reports --vendor 0x1532 --product 0x0244
    GehennaCLI report-get --vendor 0x1532 --product 0x0244 --index 1 --type feature --id 0x00 --length 90
    GehennaCLI report-set --vendor 0x1532 --product 0x0244 --index 1 --type output --id 0x00 --data \"00 FF 00 FF\"
    GehennaCLI lighting-probe --product 0x0244 --index 1 --out /tmp/gehenna-lighting.txt
    GehennaCLI lighting --product 0x0244 --index 0 --layer 2 --brightness 180
    GehennaCLI lighting --product 0x0244 --index 0 --static 00AAFF --readback
    GehennaCLI lighting --product 0x0244 --index 0 --effect spectrum
    GehennaCLI lighting --product 0x0244 --index 0 --effect breathing-dual --effect-color1 FF7A00 --effect-color2 0055FF
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

func parseUInt8(_ value: String) -> UInt8? {
  guard let intValue = parseInt(value), intValue >= 0, intValue <= 255 else {
    return nil
  }
  return UInt8(intValue)
}

func parseReportType(_ value: String) -> HIDReportTypeKind? {
  switch value.lowercased() {
  case "input":
    return .input
  case "output":
    return .output
  case "feature":
    return .feature
  default:
    return nil
  }
}

func parseHexBytes(_ value: String) -> [UInt8]? {
  let cleaned = value
    .replacingOccurrences(of: "0x", with: "")
    .replacingOccurrences(of: "0X", with: "")
    .replacingOccurrences(of: " ", with: "")
    .replacingOccurrences(of: ",", with: "")
    .replacingOccurrences(of: "_", with: "")

  guard !cleaned.isEmpty, cleaned.count % 2 == 0 else {
    return nil
  }

  var bytes: [UInt8] = []
  bytes.reserveCapacity(cleaned.count / 2)
  var index = cleaned.startIndex
  while index < cleaned.endIndex {
    let next = cleaned.index(index, offsetBy: 2)
    let token = cleaned[index..<next]
    guard let byte = UInt8(token, radix: 16) else {
      return nil
    }
    bytes.append(byte)
    index = next
  }
  return bytes
}

func daemonControlSocketPath() -> String {
  "/var/tmp/gehenna-control-\(getuid()).sock"
}

func sendLightingControlToDaemon(_ options: LightingOptions) -> DaemonControlResponse? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    return nil
  }
  defer {
    close(fd)
  }

  var one: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let path = daemonControlSocketPath()
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
    return nil
  }

  let request = DaemonControlRequest(
    command: "lighting",
    staticColorHex: options.staticColor.map { String(format: "%02X%02X%02X", $0.r, $0.g, $0.b) },
    brightness: options.brightness.map { Int($0) },
    layer: options.layer,
    effect: options.effect?.rawValue,
    effectColorHex1: options.effectColor1.map { String(format: "%02X%02X%02X", $0.r, $0.g, $0.b) },
    effectColorHex2: options.effectColor2.map { String(format: "%02X%02X%02X", $0.r, $0.g, $0.b) },
    effectSpeed: options.effectSpeed.map { Int($0) },
    readback: options.readback
  )

  guard let payload = try? JSONEncoder().encode(request) else {
    return nil
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
    } else {
      break
    }
  }

  guard !data.isEmpty else {
    return nil
  }
  return try? JSONDecoder().decode(DaemonControlResponse.self, from: data)
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
      case "--seize":
        options.seize = true
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

  case "reports":
    var options = ReportsOptions()
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
      }
    }
    return .reports(options)

  case "report-get":
    var options = ReportGetOptions()
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
      case "--type":
        index += 1
        guard index < args.count, let type = parseReportType(args[index]) else {
          print("Invalid --type value. Use input|output|feature.")
          return nil
        }
        options.type = type
        index += 1
      case "--id":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value >= 0 else {
          print("Invalid --id value")
          return nil
        }
        options.reportId = value
        index += 1
      case "--length":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value > 0 else {
          print("Invalid --length value")
          return nil
        }
        options.length = value
        index += 1
      case "--seize":
        options.seize = true
        index += 1
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
      }
    }
    guard options.reportId != nil else {
      print("Missing required --id")
      return nil
    }
    return .reportGet(options)

  case "report-set":
    var options = ReportSetOptions()
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
      case "--type":
        index += 1
        guard index < args.count, let type = parseReportType(args[index]) else {
          print("Invalid --type value. Use input|output|feature.")
          return nil
        }
        options.type = type
        index += 1
      case "--id":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value >= 0 else {
          print("Invalid --id value")
          return nil
        }
        options.reportId = value
        index += 1
      case "--data":
        index += 1
        guard index < args.count, let data = parseHexBytes(args[index]) else {
          print("Invalid --data value. Use hex bytes like \"00FF10\" or \"00 FF 10\".")
          return nil
        }
        options.data = data
        index += 1
      case "--seize":
        options.seize = true
        index += 1
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
      }
    }
    guard options.reportId != nil else {
      print("Missing required --id")
      return nil
    }
    guard !options.data.isEmpty else {
      print("Missing required --data")
      return nil
    }
    return .reportSet(options)

  case "lighting-probe":
    var options = LightingProbeOptions()
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
      case "--length":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), value > 0 else {
          print("Invalid --length value")
          return nil
        }
        options.length = value
        index += 1
      case "--out":
        index += 1
        guard index < args.count, !args[index].isEmpty else {
          print("Invalid --out value")
          return nil
        }
        options.outputPath = args[index]
        index += 1
      case "--seize":
        options.seize = true
        index += 1
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
      }
    }
    return .lightingProbe(options)

  case "lighting":
    var options = LightingOptions()
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
      case "--static":
        index += 1
        guard index < args.count, let color = TartarusProLightingColor.fromHexString(args[index]) else {
          print("Invalid --static value. Use RRGGBB.")
          return nil
        }
        options.staticColor = color
        index += 1
      case "--brightness":
        index += 1
        guard index < args.count, let value = parseUInt8(args[index]) else {
          print("Invalid --brightness value. Use 0-255.")
          return nil
        }
        options.brightness = value
        index += 1
      case "--layer":
        index += 1
        guard index < args.count, let value = parseInt(args[index]), (1...3).contains(value) else {
          print("Invalid --layer value. Use 1-3.")
          return nil
        }
        options.layer = value
        index += 1
      case "--effect":
        index += 1
        guard index < args.count, let effect = TartarusProLightingEffect.fromString(args[index]) else {
          print("Invalid --effect value. Use off, static, spectrum, wave-left, wave-right, breathing-random, breathing-single, breathing-dual, reactive, starlight-random, starlight-single, or starlight-dual.")
          return nil
        }
        options.effect = effect
        index += 1
      case "--effect-color1":
        index += 1
        guard index < args.count, let color = TartarusProLightingColor.fromHexString(args[index]) else {
          print("Invalid --effect-color1 value. Use RRGGBB.")
          return nil
        }
        options.effectColor1 = color
        index += 1
      case "--effect-color2":
        index += 1
        guard index < args.count, let color = TartarusProLightingColor.fromHexString(args[index]) else {
          print("Invalid --effect-color2 value. Use RRGGBB.")
          return nil
        }
        options.effectColor2 = color
        index += 1
      case "--effect-speed":
        index += 1
        guard index < args.count, let value = parseUInt8(args[index]) else {
          print("Invalid --effect-speed value. Use 0-255.")
          return nil
        }
        options.effectSpeed = value
        index += 1
      case "--readback":
        options.readback = true
        index += 1
      case "--seize":
        options.seize = true
        index += 1
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
      }
    }
    if options.staticColor == nil
      && options.brightness == nil
      && options.layer == nil
      && options.effect == nil
      && !options.readback
    {
      print("Specify at least one operation: --static, --brightness, --layer, --effect, or --readback.")
      return nil
    }
    if options.effect == nil && (options.effectColor1 != nil || options.effectColor2 != nil || options.effectSpeed != nil) {
      print("Use --effect when providing --effect-color1, --effect-color2, or --effect-speed.")
      return nil
    }
    return .lighting(options)

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
    if error.localizedDescription.localizedCaseInsensitiveContains("exclusive access") {
      print("Error: \(error.localizedDescription)")
      print("Hint: lighting-probe needs direct HID access. Stop the daemon first, then run probe.")
      return 2
    }
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
    let openOptions = options.seize
      ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
      : IOOptionBits(kIOHIDOptionsTypeNone)

    switch options.mode {
    case .reports:
      let listener = HIDInputListener(device: device)
      try listener.start(
        handler: { report in
          let bytes = report.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
          if options.decode {
            let decoded = decodeKeyboardReport(report)
            print("[reportId=\(report.reportId) len=\(report.bytes.count)] \(decoded) raw=\(bytes)")
          } else {
            print("[reportId=\(report.reportId) len=\(report.bytes.count)] \(bytes)")
          }
        },
        openOptions: openOptions
      )
      stopHandler = {
        listener.stop()
      }
    case .values:
      let listener = HIDValueListener(device: device)
      try listener.start(
        handler: { event in
          let usagePage = hex(event.usagePage, width: 2)
          let usage = hex(event.usage, width: 2)
          if options.decode {
            let name = usageName(usagePage: event.usagePage, usage: event.usage)
            print("[\(name)] value=\(event.intValue) logical=\(event.logicalMin)...\(event.logicalMax) type=\(event.elementType) cookie=\(event.cookie)")
          } else {
            print("[usagePage=\(usagePage) usage=\(usage) value=\(event.intValue) logical=\(event.logicalMin)...\(event.logicalMax) type=\(event.elementType) cookie=\(event.cookie)]")
          }
        },
        openOptions: openOptions
      )
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

func bytesToHexString(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func runReports(_ options: ReportsOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }

    let info = device.info
    print("Report summary for \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")

    for type in [HIDReportTypeKind.input, .output, .feature] {
      let ids = device.reportIDs(for: type)
      let size = device.maxReportSize(for: type)
      let label = type.rawValue.uppercased()
      if ids.isEmpty {
        print("  \(label): none (maxSize=\(size))")
      } else {
        let idText = ids.map { hex($0, width: 2) }.joined(separator: ", ")
        print("  \(label): ids=[\(idText)] maxSize=\(size)")
      }
    }
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runReportGet(_ options: ReportGetOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }
    guard let reportId = options.reportId else {
      print("Missing report id")
      return 2
    }

    let openOptions = options.seize
      ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
      : IOOptionBits(kIOHIDOptionsTypeNone)

    let report = try device.getReport(
      type: options.type,
      reportId: reportId,
      length: options.length,
      openOptions: openOptions
    )
    print("[type=\(options.type.rawValue) id=\(hex(reportId, width: 2)) len=\(report.count)] \(bytesToHexString(report))")
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runReportSet(_ options: ReportSetOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }
    guard let reportId = options.reportId else {
      print("Missing report id")
      return 2
    }
    guard !options.data.isEmpty else {
      print("Missing report data")
      return 2
    }

    let openOptions = options.seize
      ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
      : IOOptionBits(kIOHIDOptionsTypeNone)

    try device.setReport(
      type: options.type,
      reportId: reportId,
      bytes: options.data,
      openOptions: openOptions
    )
    print("[type=\(options.type.rawValue) id=\(hex(reportId, width: 2)) len=\(options.data.count)] wrote \(bytesToHexString(options.data))")
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runLightingProbe(_ options: LightingProbeOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }

    let openOptions = options.seize
      ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
      : IOOptionBits(kIOHIDOptionsTypeNone)

    let info = device.info
    var logLines: [String] = []
    logLines.append("Gehenna lighting probe")
    logLines.append("timestamp=\(ISO8601DateFormatter().string(from: Date()))")
    logLines.append("device=\(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")
    logLines.append("transport=\(info.transport) usagePage=\(info.usagePage) usage=\(info.usage) locationId=\(info.locationId)")
    logLines.append("length=\(options.length) seize=\(options.seize)")
    logLines.append("")

    print("Lighting probe: \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")

    for type in [HIDReportTypeKind.feature, .output] {
      let maxSize = device.maxReportSize(for: type)
      var ids = device.reportIDs(for: type)
      if ids.isEmpty {
        ids = Array(0...15)
      }

      let effectiveLength = max(1, min(options.length, max(maxSize, 1)))
      let idText = ids.map { hex($0, width: 2) }.joined(separator: ", ")
      let header = "[\(type.rawValue)] maxSize=\(maxSize) length=\(effectiveLength) ids=[\(idText)]"
      print(header)
      logLines.append(header)

      for reportId in ids {
        do {
          let bytes = try device.getReport(
            type: type,
            reportId: reportId,
            length: effectiveLength,
            openOptions: openOptions
          )
          let line = "  OK id=\(hex(reportId, width: 2)) len=\(bytes.count) data=\(bytesToHexString(bytes))"
          print(line)
          logLines.append(line)
        } catch {
          let line = "  ERR id=\(hex(reportId, width: 2)) \(error.localizedDescription)"
          print(line)
          logLines.append(line)
        }
      }

      logLines.append("")
    }

    let outputPath = options.outputPath ?? "/tmp/gehenna-lighting-\(Int(Date().timeIntervalSince1970)).txt"
    let output = logLines.joined(separator: "\n") + "\n"
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("Wrote lighting probe output: \(outputPath)")
    print("Next step: use report-set on promising FEATURE ids from the probe output.")
    return 0
  } catch {
    print("Error: \(error.localizedDescription)")
    return 2
  }
}

func runLighting(_ options: LightingOptions) -> Int32 {
  do {
    let devices = try HIDEnumerator().openDevices(match: matchFrom(filter: options.filter))
    guard let device = selectDevice(from: devices, index: options.index) else {
      return 2
    }

    let openOptions = options.seize
      ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
      : IOOptionBits(kIOHIDOptionsTypeNone)

    let info = device.info
    print("Lighting target: \(hex(info.vendorId)):\(hex(info.productId)) \(info.product) [\(info.manufacturer)]")

    @discardableResult
    func sendFeatureCommand(_ request: [UInt8]) throws -> [UInt8] {
      try device.setReport(
        type: .feature,
        reportId: 0,
        bytes: request,
        openOptions: openOptions
      )
      return try device.getReport(
        type: .feature,
        reportId: 0,
        length: TartarusProLightingProtocol.reportLength,
        openOptions: openOptions
      )
    }

    func statusAndCommand(_ response: [UInt8]) -> (UInt8, UInt8) {
      let status = response.first ?? 0
      let command: UInt8 = response.count > 7 ? response[7] : 0
      return (status, command)
    }

    if let brightness = options.brightness {
      let request = TartarusProLightingProtocol.brightnessReport(value: brightness)
      let response = try sendFeatureCommand(request)
      let (status, command) = statusAndCommand(response)
      print(
        "brightness=\(brightness) status=\(hex(Int(status), width: 2)) command=\(hex(Int(command), width: 2))"
      )
    }

    if let staticColor = options.staticColor {
      let request = TartarusProLightingProtocol.staticEffectReport(color: staticColor)
      let response = try sendFeatureCommand(request)
      let (status, command) = statusAndCommand(response)
      print(
        "static=\(String(format: "%02X%02X%02X", staticColor.r, staticColor.g, staticColor.b)) status=\(hex(Int(status), width: 2)) command=\(hex(Int(command), width: 2))"
      )
    }

    if let layer = options.layer {
      let color = TartarusProLightingColor.layerIndicator(layer: layer)
      let request = TartarusProLightingProtocol.profileIndicatorReport(layer: layer)
      let response = try sendFeatureCommand(request)
      let (status, command) = statusAndCommand(response)
      print(
        "layer=\(layer) color=\(String(format: "%02X%02X%02X", color.r, color.g, color.b)) status=\(hex(Int(status), width: 2)) command=\(hex(Int(command), width: 2))"
      )
    }

    if let effect = options.effect {
      let color1 = options.effectColor1 ?? TartarusProLightingColor(r: 0x00, g: 0xFF, b: 0x00)
      let color2 = options.effectColor2 ?? TartarusProLightingColor(r: 0x00, g: 0x00, b: 0xFF)
      let speed = options.effectSpeed ?? 2
      let request = TartarusProLightingProtocol.matrixEffectReport(
        effect: effect,
        primaryColor: color1,
        secondaryColor: color2,
        speed: speed
      )
      let response = try sendFeatureCommand(request)
      let (status, command) = statusAndCommand(response)
      print(
        "effect=\(effect.rawValue) color1=\(String(format: "%02X%02X%02X", color1.r, color1.g, color1.b)) color2=\(String(format: "%02X%02X%02X", color2.r, color2.g, color2.b)) speed=\(speed) status=\(hex(Int(status), width: 2)) command=\(hex(Int(command), width: 2))"
      )
    }

    if options.readback {
      let response = try sendFeatureCommand(TartarusProLightingProtocol.getStaticEffectReport())
      if let color = TartarusProLightingProtocol.parseStaticColor(from: response) {
        print("readback static=\(String(format: "%02X%02X%02X", color.r, color.g, color.b)) status=\(hex(Int(response.first ?? 0), width: 2))")
      } else {
        print("readback failed status=\(hex(Int(response.first ?? 0), width: 2)) raw=\(bytesToHexString(response))")
      }
    }

    return 0
  } catch {
    if let hidError = error as? HIDError {
      if hidError.localizedDescription.localizedCaseInsensitiveContains("exclusive access") {
        if let response = sendLightingControlToDaemon(options) {
          if response.ok {
            print("daemon-control: \(response.message)")
            return 0
          }
          print("Error: daemon-control failed: \(response.message)")
          return 2
        }
        print("Error: \(hidError.localizedDescription)")
        print("Hint: daemon is likely running without control socket. Restart GehennaDaemon with latest build.")
        return 2
      }
    }
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
  case let .reports(options):
    return runReports(options)
  case let .reportGet(options):
    return runReportGet(options)
  case let .reportSet(options):
    return runReportSet(options)
  case let .lightingProbe(options):
    return runLightingProbe(options)
  case let .lighting(options):
    return runLighting(options)
  }
}

exit(run())
