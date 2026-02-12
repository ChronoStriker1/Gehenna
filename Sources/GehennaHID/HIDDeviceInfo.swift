import Foundation
import IOKit.hid

public struct HIDMatch: Sendable, Equatable {
  public let vendorId: Int?
  public let productId: Int?
  public let usagePage: Int?
  public let usage: Int?

  public init(
    vendorId: Int? = nil,
    productId: Int? = nil,
    usagePage: Int? = nil,
    usage: Int? = nil
  ) {
    self.vendorId = vendorId
    self.productId = productId
    self.usagePage = usagePage
    self.usage = usage
  }

  func toMatchingDictionary() -> CFDictionary? {
    var dict: [String: Any] = [:]

    if let vendorId {
      dict[kIOHIDVendorIDKey] = vendorId
    }
    if let productId {
      dict[kIOHIDProductIDKey] = productId
    }
    if let usagePage {
      dict[kIOHIDDeviceUsagePageKey] = usagePage
    }
    if let usage {
      dict[kIOHIDDeviceUsageKey] = usage
    }

    if dict.isEmpty {
      return nil
    }

    return dict as CFDictionary
  }
}

public struct HIDDeviceInfo: Sendable, Codable, Equatable {
  public let vendorId: Int
  public let productId: Int
  public let product: String
  public let manufacturer: String
  public let transport: String
  public let usagePage: Int
  public let usage: Int
  public let locationId: Int

  public init(
    vendorId: Int,
    productId: Int,
    product: String,
    manufacturer: String,
    transport: String,
    usagePage: Int,
    usage: Int,
    locationId: Int
  ) {
    self.vendorId = vendorId
    self.productId = productId
    self.product = product
    self.manufacturer = manufacturer
    self.transport = transport
    self.usagePage = usagePage
    self.usage = usage
    self.locationId = locationId
  }
}

extension HIDDeviceInfo {
  static func from(device: IOHIDDevice) -> HIDDeviceInfo {
    HIDDeviceInfo(
      vendorId: device.intProperty(key: kIOHIDVendorIDKey),
      productId: device.intProperty(key: kIOHIDProductIDKey),
      product: device.stringProperty(key: kIOHIDProductKey),
      manufacturer: device.stringProperty(key: kIOHIDManufacturerKey),
      transport: device.stringProperty(key: kIOHIDTransportKey),
      usagePage: device.intProperty(key: kIOHIDDeviceUsagePageKey),
      usage: device.intProperty(key: kIOHIDDeviceUsageKey),
      locationId: device.intProperty(key: kIOHIDLocationIDKey)
    )
  }
}

public enum HIDError: Error, LocalizedError {
  case managerOpenFailed(IOReturn)

  public var errorDescription: String? {
    switch self {
    case .managerOpenFailed(let code):
      if code == kIOReturnExclusiveAccess {
        return "Failed to open IOHIDManager (exclusive access). Another process has seized the device."
      }
      if code == kIOReturnNotPermitted {
        return "Failed to open IOHIDManager (not permitted). Ensure Input Monitoring is granted and start Gehenna without forcing sudo/root."
      }
      return "Failed to open IOHIDManager (IOReturn: \(code))."
    }
  }
}

public struct HIDEnumerator {
  public init() {}

  public func listDevices(match: HIDMatch? = nil) throws -> [HIDDeviceInfo] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    if let matching = match?.toMatchingDictionary() {
      IOHIDManagerSetDeviceMatching(manager, matching)
    } else {
      IOHIDManagerSetDeviceMatching(manager, nil)
    }

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
      throw HIDError.managerOpenFailed(openResult)
    }

    defer {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    let devices = devicesFrom(manager: manager)

    return devices.map { device in
      HIDDeviceInfo.from(device: device)
    }
    .sorted { lhs, rhs in
      if lhs.vendorId != rhs.vendorId {
        return lhs.vendorId < rhs.vendorId
      }
      if lhs.productId != rhs.productId {
        return lhs.productId < rhs.productId
      }
      return lhs.product < rhs.product
    }
  }

  public func openDevices(match: HIDMatch? = nil) throws -> [HIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    if let matching = match?.toMatchingDictionary() {
      IOHIDManagerSetDeviceMatching(manager, matching)
    } else {
      IOHIDManagerSetDeviceMatching(manager, nil)
    }

    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
      throw HIDError.managerOpenFailed(openResult)
    }

    defer {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    let devices = devicesFrom(manager: manager)
    return devices.map { HIDDevice(device: $0) }
      .sorted { lhs, rhs in
        if lhs.info.vendorId != rhs.info.vendorId {
          return lhs.info.vendorId < rhs.info.vendorId
        }
        if lhs.info.productId != rhs.info.productId {
          return lhs.info.productId < rhs.info.productId
        }
        return lhs.info.product < rhs.info.product
      }
  }
}

private func devicesFrom(manager: IOHIDManager) -> [IOHIDDevice] {
  guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
    return []
  }

  let count = CFSetGetCount(deviceSet)
  if count == 0 {
    return []
  }

  var values = [UnsafeRawPointer?](repeating: nil, count: count)
  CFSetGetValues(deviceSet, &values)
  return values.compactMap { pointer in
    guard let pointer else {
      return nil
    }
    return unsafeBitCast(pointer, to: IOHIDDevice.self)
  }
}

extension IOHIDDevice {
  func stringProperty(key: String) -> String {
    guard let value = IOHIDDeviceGetProperty(self, key as CFString) else {
      return ""
    }

    if let stringValue = value as? String {
      return stringValue
    }

    return ""
  }

  func intProperty(key: String) -> Int {
    guard let value = IOHIDDeviceGetProperty(self, key as CFString) else {
      return 0
    }

    if let number = value as? NSNumber {
      return number.intValue
    }

    return 0
  }
}
