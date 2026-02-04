import Foundation
import GehennaHID

struct CLIOptions {
  var vendorId: Int?
  var productId: Int?
  var usagePage: Int?
  var usage: Int?
  var jsonOutput = false
}

func printUsage() {
  let usage = """
  GehennaCLI - HID device enumerator for Gehenna

  Usage:
    GehennaCLI list [--vendor <id>] [--product <id>] [--usagePage <id>] [--usage <id>] [--json]

  Examples:
    GehennaCLI list
    GehennaCLI list --vendor 0x1532
    GehennaCLI list --vendor 0x1532 --product 0x022B
    GehennaCLI list --json
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

func parseArgs() -> CLIOptions? {
  var args = CommandLine.arguments
  args.removeFirst()

  if args.isEmpty || args.first == "-h" || args.first == "--help" {
    printUsage()
    return nil
  }

  guard args.first == "list" else {
    printUsage()
    return nil
  }

  var options = CLIOptions()
  var index = 1
  while index < args.count {
    let arg = args[index]
    switch arg {
    case "--vendor":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        print("Invalid --vendor value")
        return nil
      }
      options.vendorId = value
    case "--product":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        print("Invalid --product value")
        return nil
      }
      options.productId = value
    case "--usagePage":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        print("Invalid --usagePage value")
        return nil
      }
      options.usagePage = value
    case "--usage":
      index += 1
      guard index < args.count, let value = parseInt(args[index]) else {
        print("Invalid --usage value")
        return nil
      }
      options.usage = value
    case "--json":
      options.jsonOutput = true
    default:
      print("Unknown argument: \(arg)")
      return nil
    }

    index += 1
  }

  return options
}

func renderTable(_ devices: [HIDDeviceInfo]) {
  if devices.isEmpty {
    print("No HID devices matched the filter.")
    return
  }

  for device in devices {
    let vendorHex = String(format: "0x%04X", device.vendorId)
    let productHex = String(format: "0x%04X", device.productId)
    print("\(vendorHex):\(productHex) \(device.product) [\(device.manufacturer)]")
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

func run() -> Int32 {
  guard let options = parseArgs() else {
    return 1
  }

  let match = HIDMatch(
    vendorId: options.vendorId,
    productId: options.productId,
    usagePage: options.usagePage,
    usage: options.usage
  )

  do {
    let devices = try HIDEnumerator().listDevices(match: match)
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

exit(run())
