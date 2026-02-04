import Foundation
import IOKit.hid

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

  func open() throws {
    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
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

  public var errorDescription: String? {
    switch self {
    case let .deviceOpenFailed(code):
      return "Failed to open HID device (IOReturn: \(code))."
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

  public func start(handler: @escaping ReportHandler) throws {
    if isRunning {
      return
    }

    self.handler = handler
    try device.open()

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
}

public final class HIDValueListener {
  public typealias ValueHandler = (HIDValueEvent) -> Void

  private let device: HIDDevice
  private var handler: ValueHandler?
  private var isRunning = false

  public init(device: HIDDevice) {
    self.device = device
  }

  public func start(handler: @escaping ValueHandler) throws {
    if isRunning {
      return
    }

    self.handler = handler
    try device.open()

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
