import Foundation
import IOKit.hid

public enum HIDReportTypeKind: String, Sendable, Codable, Equatable {
  case input
  case output
  case feature

  var ioType: IOHIDReportType {
    switch self {
    case .input:
      return kIOHIDReportTypeInput
    case .output:
      return kIOHIDReportTypeOutput
    case .feature:
      return kIOHIDReportTypeFeature
    }
  }
}

public struct HIDElementInfo: Sendable, Codable, Equatable {
  public let type: String
  public let usagePage: Int
  public let usage: Int
  public let reportId: Int
  public let reportSize: Int
  public let reportCount: Int
  public let logicalMin: Int
  public let logicalMax: Int
  public let physicalMin: Int
  public let physicalMax: Int
  public let unit: Int
  public let unitExponent: Int
  public let cookie: Int
}

public final class HIDDevice {
  public let info: HIDDeviceInfo
  private let device: IOHIDDevice

  init(device: IOHIDDevice) {
    self.device = device
    self.info = HIDDeviceInfo.from(device: device)
  }

  public func elements() -> [HIDElementInfo] {
    guard let array = IOHIDDeviceCopyMatchingElements(
      device,
      nil,
      IOOptionBits(kIOHIDOptionsTypeNone)
    ) else {
      return []
    }

    let count = CFArrayGetCount(array)
    if count == 0 {
      return []
    }

    var results: [HIDElementInfo] = []
    results.reserveCapacity(count)

    for index in 0..<count {
      let raw = CFArrayGetValueAtIndex(array, index)
      let element = unsafeBitCast(raw, to: IOHIDElement.self)

      results.append(
        HIDElementInfo(
          type: elementTypeName(element),
          usagePage: Int(IOHIDElementGetUsagePage(element)),
          usage: Int(IOHIDElementGetUsage(element)),
          reportId: Int(IOHIDElementGetReportID(element)),
          reportSize: Int(IOHIDElementGetReportSize(element)),
          reportCount: Int(IOHIDElementGetReportCount(element)),
          logicalMin: Int(IOHIDElementGetLogicalMin(element)),
          logicalMax: Int(IOHIDElementGetLogicalMax(element)),
          physicalMin: Int(IOHIDElementGetPhysicalMin(element)),
          physicalMax: Int(IOHIDElementGetPhysicalMax(element)),
          unit: Int(IOHIDElementGetUnit(element)),
          unitExponent: Int(IOHIDElementGetUnitExponent(element)),
          cookie: Int(IOHIDElementGetCookie(element))
        )
      )
    }

    return results.sorted { lhs, rhs in
      if lhs.type != rhs.type {
        return lhs.type < rhs.type
      }
      if lhs.usagePage != rhs.usagePage {
        return lhs.usagePage < rhs.usagePage
      }
      if lhs.usage != rhs.usage {
        return lhs.usage < rhs.usage
      }
      return lhs.reportId < rhs.reportId
    }
  }

  public func inputReportSize() -> Int {
    let size = device.intProperty(key: kIOHIDMaxInputReportSizeKey)
    return size > 0 ? size : 512
  }

  public func maxReportSize(for type: HIDReportTypeKind) -> Int {
    let key: String
    switch type {
    case .input:
      key = kIOHIDMaxInputReportSizeKey
    case .output:
      key = kIOHIDMaxOutputReportSizeKey
    case .feature:
      key = kIOHIDMaxFeatureReportSizeKey
    }

    let size = device.intProperty(key: key)
    if size > 0 {
      return size
    }

    let matchingElements = elements().filter {
      switch type {
      case .input:
        return $0.type.hasPrefix("Input_")
      case .output:
        return $0.type == "Output"
      case .feature:
        return $0.type == "Feature"
      }
    }

    if let largest = matchingElements.map({ $0.reportSize * $0.reportCount / 8 }).max(), largest > 0 {
      return largest
    }

    return 512
  }

  public func reportIDs(for type: HIDReportTypeKind) -> [Int] {
    let ids = elements().compactMap { element -> Int? in
      switch type {
      case .input:
        return element.type.hasPrefix("Input_") ? element.reportId : nil
      case .output:
        return element.type == "Output" ? element.reportId : nil
      case .feature:
        return element.type == "Feature" ? element.reportId : nil
      }
    }
    return Array(Set(ids)).sorted()
  }

  public func getReport(
    type: HIDReportTypeKind,
    reportId: Int,
    length: Int? = nil,
    openOptions: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeNone)
  ) throws -> [UInt8] {
    let requestedLength = max(1, length ?? maxReportSize(for: type))

    try open(options: openOptions)
    defer {
      close()
    }
    return try getReportOpened(type: type, reportId: reportId, length: requestedLength)
  }

  public func setReport(
    type: HIDReportTypeKind,
    reportId: Int,
    bytes: [UInt8],
    openOptions: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeNone)
  ) throws {
    try open(options: openOptions)
    defer {
      close()
    }
    try setReportOpened(type: type, reportId: reportId, bytes: bytes)
  }

  func getReportOpened(
    type: HIDReportTypeKind,
    reportId: Int,
    length: Int
  ) throws -> [UInt8] {
    let requestedLength = max(1, length)
    var buffer = [UInt8](repeating: 0, count: requestedLength)
    var reportLength = requestedLength

    let result = IOHIDDeviceGetReport(
      device,
      type.ioType,
      CFIndex(reportId),
      &buffer,
      &reportLength
    )
    guard result == kIOReturnSuccess else {
      throw HIDDeviceError.reportGetFailed(result)
    }

    return Array(buffer.prefix(reportLength))
  }

  func setReportOpened(
    type: HIDReportTypeKind,
    reportId: Int,
    bytes: [UInt8]
  ) throws {
    guard !bytes.isEmpty else {
      throw HIDDeviceError.invalidReportData("Report payload cannot be empty.")
    }

    let result = bytes.withUnsafeBufferPointer { ptr -> IOReturn in
      guard let base = ptr.baseAddress else {
        return kIOReturnBadArgument
      }

      return IOHIDDeviceSetReport(
        device,
        type.ioType,
        CFIndex(reportId),
        base,
        ptr.count
      )
    }
    guard result == kIOReturnSuccess else {
      throw HIDDeviceError.reportSetFailed(result)
    }
  }

  func open(options: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeNone)) throws {
    let result = IOHIDDeviceOpen(device, options)
    guard result == kIOReturnSuccess else {
      throw HIDDeviceError.deviceOpenFailed(result)
    }
  }

  func close() {
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  func schedule() {
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
  }

  func unschedule() {
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
  }

  func registerInputReportCallback(
    buffer: inout [UInt8],
    context: UnsafeMutableRawPointer?,
    callback: @escaping IOHIDReportCallback
  ) {
    let count = buffer.count
    buffer.withUnsafeMutableBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return
      }
      IOHIDDeviceRegisterInputReportCallback(
        device,
        base,
        count,
        callback,
        context
      )
    }
  }

  func registerInputValueCallback(
    context: UnsafeMutableRawPointer?,
    callback: @escaping IOHIDValueCallback
  ) {
    IOHIDDeviceRegisterInputValueCallback(device, callback, context)
  }
}

public enum HIDDeviceError: Error, LocalizedError {
  case deviceOpenFailed(IOReturn)
  case reportGetFailed(IOReturn)
  case reportSetFailed(IOReturn)
  case invalidReportData(String)

  public var errorDescription: String? {
    switch self {
    case let .deviceOpenFailed(code):
      return "Failed to open HID device (IOReturn: \(code))."
    case let .reportGetFailed(code):
      return "Failed to read HID report (IOReturn: \(code))."
    case let .reportSetFailed(code):
      return "Failed to write HID report (IOReturn: \(code))."
    case let .invalidReportData(message):
      return message
    }
  }
}

public struct HIDInputReport: Sendable, Codable, Equatable {
  public let reportId: Int
  public let bytes: [UInt8]
}

public struct HIDValueEvent: Sendable, Codable, Equatable {
  public let usagePage: Int
  public let usage: Int
  public let intValue: Int
  public let logicalMin: Int
  public let logicalMax: Int
  public let elementType: String
  public let cookie: Int
}

public final class HIDInputListener {
  public typealias ReportHandler = (HIDInputReport) -> Void

  private let device: HIDDevice
  private var buffer: [UInt8]
  private var handler: ReportHandler?
  private var isRunning = false

  public init(device: HIDDevice) {
    self.device = device
    self.buffer = [UInt8](repeating: 0, count: device.inputReportSize())
  }

  public func start(
    handler: @escaping ReportHandler,
    openOptions: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeNone)
  ) throws {
    if isRunning {
      return
    }

    self.handler = handler
    try device.open(options: openOptions)

    let context = Unmanaged.passUnretained(self).toOpaque()
    device.registerInputReportCallback(buffer: &buffer, context: context, callback: inputReportCallback)
    device.schedule()
    isRunning = true
  }

  public func stop() {
    guard isRunning else {
      return
    }

    device.unschedule()
    device.close()
    isRunning = false
  }

  deinit {
    stop()
  }

  fileprivate func handleReport(reportId: Int, report: [UInt8]) {
    handler?(HIDInputReport(reportId: reportId, bytes: report))
  }

  public func setReport(
    type: HIDReportTypeKind,
    reportId: Int,
    bytes: [UInt8]
  ) throws {
    try device.setReportOpened(type: type, reportId: reportId, bytes: bytes)
  }

  public func getReport(
    type: HIDReportTypeKind,
    reportId: Int,
    length: Int
  ) throws -> [UInt8] {
    try device.getReportOpened(type: type, reportId: reportId, length: length)
  }
}

public final class HIDValueListener {
  public typealias ValueHandler = (HIDValueEvent) -> Void

  private let device: HIDDevice
  private var handler: ValueHandler?
  private var isRunning = false

  public init(device: HIDDevice) {
    self.device = device
  }

  public func start(
    handler: @escaping ValueHandler,
    openOptions: IOOptionBits = IOOptionBits(kIOHIDOptionsTypeNone)
  ) throws {
    if isRunning {
      return
    }

    self.handler = handler
    try device.open(options: openOptions)

    let context = Unmanaged.passUnretained(self).toOpaque()
    device.registerInputValueCallback(context: context, callback: inputValueCallback)
    device.schedule()
    isRunning = true
  }

  public func stop() {
    guard isRunning else {
      return
    }

    device.unschedule()
    device.close()
    isRunning = false
  }

  deinit {
    stop()
  }

  fileprivate func handleValue(_ event: HIDValueEvent) {
    handler?(event)
  }
}

private let inputReportCallback: IOHIDReportCallback = {
  context,
  result,
  sender,
  type,
  reportID,
  report,
  reportLength in

  guard let context, reportLength > 0 else {
    return
  }

  guard result == kIOReturnSuccess else {
    return
  }

  let listener = Unmanaged<HIDInputListener>.fromOpaque(context).takeUnretainedValue()
  let buffer = UnsafeBufferPointer(start: report, count: reportLength)
  listener.handleReport(reportId: Int(reportID), report: Array(buffer))
}

private let inputValueCallback: IOHIDValueCallback = {
  context,
  result,
  sender,
  value in

  guard let context else {
    return
  }

  guard result == kIOReturnSuccess else {
    return
  }

  let element = IOHIDValueGetElement(value)
  let event = HIDValueEvent(
    usagePage: Int(IOHIDElementGetUsagePage(element)),
    usage: Int(IOHIDElementGetUsage(element)),
    intValue: Int(IOHIDValueGetIntegerValue(value)),
    logicalMin: Int(IOHIDElementGetLogicalMin(element)),
    logicalMax: Int(IOHIDElementGetLogicalMax(element)),
    elementType: elementTypeName(element),
    cookie: Int(IOHIDElementGetCookie(element))
  )

  let listener = Unmanaged<HIDValueListener>.fromOpaque(context).takeUnretainedValue()
  listener.handleValue(event)
}

private func elementTypeName(_ element: IOHIDElement) -> String {
  switch IOHIDElementGetType(element) {
  case kIOHIDElementTypeInput_Misc:
    return "Input_Misc"
  case kIOHIDElementTypeInput_Button:
    return "Input_Button"
  case kIOHIDElementTypeInput_Axis:
    return "Input_Axis"
  case kIOHIDElementTypeInput_ScanCodes:
    return "Input_ScanCodes"
  case kIOHIDElementTypeOutput:
    return "Output"
  case kIOHIDElementTypeFeature:
    return "Feature"
  case kIOHIDElementTypeCollection:
    return "Collection"
  default:
    return "Other"
  }
}
