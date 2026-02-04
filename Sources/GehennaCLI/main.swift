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
}

enum Command {
  case list(ListOptions)
  case describe(DescribeOptions)
  case listen(ListenOptions)
}

func printUsage() {
  let usage = """
  GehennaCLI - HID tooling for Gehenna

  Usage:
    GehennaCLI list [--vendor <id>] [--product <id>] [--usagePage <id>] [--usage <id>] [--json]
    GehennaCLI describe [--vendor <id>] [--product <id>] [--index <n>]
    GehennaCLI listen [--vendor <id>] [--product <id>] [--index <n>] [--duration <sec>]

  Examples:
    GehennaCLI list
    GehennaCLI list --vendor 0x1532 --product 0x0244
    GehennaCLI describe --vendor 0x1532 --product 0x0244 --index 0
    GehennaCLI listen --vendor 0x1532 --product 0x0244 --index 0
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
      index += 1
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
      case "--duration":
        index += 1
        guard index < args.count, let value = Double(args[index]), value > 0 else {
          print("Invalid --duration value")
          return nil
        }
        options.duration = value
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
      index += 1
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

    let listener = HIDInputListener(device: device)
    try listener.start { report in
      let bytes = report.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
      print("[reportId=\(report.reportId) len=\(report.bytes.count)] \(bytes)")
    }

    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
      listener.stop()
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    signalSource.resume()

    if let duration = options.duration {
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        listener.stop()
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
