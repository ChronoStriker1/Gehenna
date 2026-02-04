import Foundation

public struct HIDKeyModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let leftControl = HIDKeyModifiers(rawValue: 1 << 0)
  public static let leftShift = HIDKeyModifiers(rawValue: 1 << 1)
  public static let leftAlt = HIDKeyModifiers(rawValue: 1 << 2)
  public static let leftGUI = HIDKeyModifiers(rawValue: 1 << 3)
  public static let rightControl = HIDKeyModifiers(rawValue: 1 << 4)
  public static let rightShift = HIDKeyModifiers(rawValue: 1 << 5)
  public static let rightAlt = HIDKeyModifiers(rawValue: 1 << 6)
  public static let rightGUI = HIDKeyModifiers(rawValue: 1 << 7)
}

public struct HIDKeyReport: Sendable, Equatable {
  public let modifiers: HIDKeyModifiers
  public let keys: [UInt8]

  public init(modifiers: HIDKeyModifiers, keys: [UInt8]) {
    self.modifiers = modifiers
    self.keys = keys
  }
}

public enum HIDKeyboardReportDecoder {
  public static func decode(report: [UInt8]) -> HIDKeyReport? {
    guard report.count >= 3 else {
      return nil
    }

    let modifiers = HIDKeyModifiers(rawValue: report[0])
    let keys = report.dropFirst(2).filter { $0 != 0 }
    return HIDKeyReport(modifiers: modifiers, keys: Array(keys))
  }
}

public struct HIDModifierSet {
  public static func toModifiers(_ set: HIDKeyModifiers) -> [HIDModifier] {
    var result: [HIDModifier] = []
    if set.contains(.leftControl) { result.append(.leftControl) }
    if set.contains(.leftShift) { result.append(.leftShift) }
    if set.contains(.leftAlt) { result.append(.leftAlt) }
    if set.contains(.leftGUI) { result.append(.leftGUI) }
    if set.contains(.rightControl) { result.append(.rightControl) }
    if set.contains(.rightShift) { result.append(.rightShift) }
    if set.contains(.rightAlt) { result.append(.rightAlt) }
    if set.contains(.rightGUI) { result.append(.rightGUI) }
    return result
  }

  public static func fromModifiers(_ modifiers: [HIDModifier]) -> HIDKeyModifiers {
    modifiers.reduce(into: HIDKeyModifiers()) { partial, modifier in
      switch modifier {
      case .leftControl:
        partial.insert(.leftControl)
      case .leftShift:
        partial.insert(.leftShift)
      case .leftAlt:
        partial.insert(.leftAlt)
      case .leftGUI:
        partial.insert(.leftGUI)
      case .rightControl:
        partial.insert(.rightControl)
      case .rightShift:
        partial.insert(.rightShift)
      case .rightAlt:
        partial.insert(.rightAlt)
      case .rightGUI:
        partial.insert(.rightGUI)
      }
    }
  }
}
