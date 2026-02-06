import Foundation

public struct TartarusProLightingColor: Sendable, Codable, Equatable {
  public let r: UInt8
  public let g: UInt8
  public let b: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8) {
    self.r = r
    self.g = g
    self.b = b
  }

  public static func fromHexString(_ value: String) -> TartarusProLightingColor? {
    let cleaned = value
      .replacingOccurrences(of: "#", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count == 6, let raw = Int(cleaned, radix: 16) else {
      return nil
    }
    let r = UInt8((raw >> 16) & 0xFF)
    let g = UInt8((raw >> 8) & 0xFF)
    let b = UInt8(raw & 0xFF)
    return TartarusProLightingColor(r: r, g: g, b: b)
  }

  public static func layerIndicator(layer: Int) -> TartarusProLightingColor {
    switch layer {
    case 1:
      return TartarusProLightingColor(r: 0xFF, g: 0x00, b: 0x00)
    case 2:
      return TartarusProLightingColor(r: 0x00, g: 0xFF, b: 0x00)
    default:
      return TartarusProLightingColor(r: 0x00, g: 0x00, b: 0xFF)
    }
  }
}

public enum TartarusProLightingEffect: String, CaseIterable, Codable, Sendable {
  case off = "off"
  case `static` = "static"
  case spectrum = "spectrum"
  case waveLeft = "wave-left"
  case waveRight = "wave-right"
  case breathingRandom = "breathing-random"
  case breathingSingle = "breathing-single"
  case breathingDual = "breathing-dual"
  case reactive = "reactive"
  case starlightRandom = "starlight-random"
  case starlightSingle = "starlight-single"
  case starlightDual = "starlight-dual"

  public static func fromString(_ value: String) -> TartarusProLightingEffect? {
    TartarusProLightingEffect(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}

public enum TartarusProLightingProtocol {
  public static let reportLength = 0x5A
  public static let commandClass: UInt8 = 0x0F
  public static let transactionId: UInt8 = 0x1F
  public static let varStore: UInt8 = 0x01
  public static let zeroLed: UInt8 = 0x00
  public static let sideStripeLed: UInt8 = 0x0B

  // Derived from OpenRazer Tartarus Pro support:
  // - https://github.com/openrazer/openrazer/commit/aae37f193e1da14bb8544e48f729a91d4344d0cf
  // - https://github.com/openrazer/openrazer/commit/24a18d85ba433f8c38976f45d1a3bddd1a751a27
  // - https://github.com/openrazer/openrazer/commit/e81b32df6b02631b804b149fd10278f32796e656
  public static func makeReport(
    commandId: UInt8,
    dataSize: UInt8,
    arguments: [UInt8]
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: reportLength)
    bytes[0] = 0x00 // status: new command
    bytes[1] = transactionId
    bytes[2] = 0x00 // remaining packets (BE)
    bytes[3] = 0x00
    bytes[4] = 0x00 // protocol type
    bytes[5] = dataSize
    bytes[6] = commandClass
    bytes[7] = commandId

    let argCount = min(arguments.count, 80)
    if argCount > 0 {
      for i in 0..<argCount {
        bytes[8 + i] = arguments[i]
      }
    }

    bytes[88] = calculateCRC(bytes)
    bytes[89] = 0x00
    return bytes
  }

  public static func staticEffectReport(
    color: TartarusProLightingColor,
    ledId: UInt8 = sideStripeLed
  ) -> [UInt8] {
    // Extended matrix static effect payload.
    var args = [UInt8](repeating: 0, count: 9)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x01 // static effect
    args[5] = 0x01 // required by static effect on this device
    args[6] = color.r
    args[7] = color.g
    args[8] = color.b
    return makeReport(commandId: 0x02, dataSize: 0x09, arguments: args)
  }

  public static func matrixEffectReport(
    effect: TartarusProLightingEffect,
    primaryColor: TartarusProLightingColor = TartarusProLightingColor(r: 0x00, g: 0xFF, b: 0x00),
    secondaryColor: TartarusProLightingColor = TartarusProLightingColor(r: 0x00, g: 0x00, b: 0xFF),
    speed: UInt8 = 0x02,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    switch effect {
    case .off:
      return matrixOffEffectReport(ledId: ledId)
    case .static:
      return staticEffectReport(color: primaryColor, ledId: ledId)
    case .spectrum:
      return matrixSpectrumEffectReport(ledId: ledId)
    case .waveLeft:
      // Tartarus Pro accepts 0x01/0x02 for wave direction.
      return matrixWaveEffectReport(direction: 0x02, ledId: ledId)
    case .waveRight:
      return matrixWaveEffectReport(direction: 0x01, ledId: ledId)
    case .breathingRandom:
      return matrixBreathingRandomEffectReport(ledId: ledId)
    case .breathingSingle:
      return matrixBreathingSingleEffectReport(color: primaryColor, ledId: ledId)
    case .breathingDual:
      return matrixBreathingDualEffectReport(primaryColor: primaryColor, secondaryColor: secondaryColor, ledId: ledId)
    case .reactive:
      return matrixReactiveEffectReport(color: primaryColor, speed: speed, ledId: ledId)
    case .starlightRandom:
      return matrixStarlightRandomEffectReport(speed: speed, ledId: ledId)
    case .starlightSingle:
      return matrixStarlightSingleEffectReport(color: primaryColor, speed: speed, ledId: ledId)
    case .starlightDual:
      return matrixStarlightDualEffectReport(primaryColor: primaryColor, secondaryColor: secondaryColor, speed: speed, ledId: ledId)
    }
  }

  public static func matrixOffEffectReport(ledId: UInt8 = zeroLed) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x06)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x00
    return makeReport(commandId: 0x02, dataSize: 0x06, arguments: args)
  }

  public static func matrixSpectrumEffectReport(ledId: UInt8 = zeroLed) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x06)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x03
    return makeReport(commandId: 0x02, dataSize: 0x06, arguments: args)
  }

  public static func matrixWaveEffectReport(
    direction: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x06)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x04
    args[3] = min(direction, 0x02)
    args[4] = 0x28
    return makeReport(commandId: 0x02, dataSize: 0x06, arguments: args)
  }

  public static func matrixBreathingRandomEffectReport(ledId: UInt8 = zeroLed) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x06)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x02
    return makeReport(commandId: 0x02, dataSize: 0x06, arguments: args)
  }

  public static func matrixBreathingSingleEffectReport(
    color: TartarusProLightingColor,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x09)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x02
    args[3] = 0x01
    args[5] = 0x01
    args[6] = color.r
    args[7] = color.g
    args[8] = color.b
    return makeReport(commandId: 0x02, dataSize: 0x09, arguments: args)
  }

  public static func matrixBreathingDualEffectReport(
    primaryColor: TartarusProLightingColor,
    secondaryColor: TartarusProLightingColor,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 0x0C)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x02
    args[3] = 0x02
    args[5] = 0x02
    args[6] = primaryColor.r
    args[7] = primaryColor.g
    args[8] = primaryColor.b
    args[9] = secondaryColor.r
    args[10] = secondaryColor.g
    args[11] = secondaryColor.b
    return makeReport(commandId: 0x02, dataSize: 0x0C, arguments: args)
  }

  public static func matrixReactiveEffectReport(
    color: TartarusProLightingColor,
    speed: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    let safeSpeed = max(UInt8(0x01), min(UInt8(0x04), speed))
    var args = [UInt8](repeating: 0, count: 0x09)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x05
    args[4] = safeSpeed
    args[5] = 0x01
    args[6] = color.r
    args[7] = color.g
    args[8] = color.b
    return makeReport(commandId: 0x02, dataSize: 0x09, arguments: args)
  }

  public static func matrixStarlightRandomEffectReport(
    speed: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    let safeSpeed = max(UInt8(0x01), min(UInt8(0x03), speed))
    var args = [UInt8](repeating: 0, count: 0x06)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x07
    args[4] = safeSpeed
    return makeReport(commandId: 0x02, dataSize: 0x06, arguments: args)
  }

  public static func matrixStarlightSingleEffectReport(
    color: TartarusProLightingColor,
    speed: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    let safeSpeed = max(UInt8(0x01), min(UInt8(0x03), speed))
    var args = [UInt8](repeating: 0, count: 0x09)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x07
    args[4] = safeSpeed
    args[5] = 0x01
    args[6] = color.r
    args[7] = color.g
    args[8] = color.b
    return makeReport(commandId: 0x02, dataSize: 0x09, arguments: args)
  }

  public static func matrixStarlightDualEffectReport(
    primaryColor: TartarusProLightingColor,
    secondaryColor: TartarusProLightingColor,
    speed: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    let safeSpeed = max(UInt8(0x01), min(UInt8(0x03), speed))
    var args = [UInt8](repeating: 0, count: 0x0C)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x07
    args[4] = safeSpeed
    args[5] = 0x02
    args[6] = primaryColor.r
    args[7] = primaryColor.g
    args[8] = primaryColor.b
    args[9] = secondaryColor.r
    args[10] = secondaryColor.g
    args[11] = secondaryColor.b
    return makeReport(commandId: 0x02, dataSize: 0x0C, arguments: args)
  }

  public static func getStaticEffectReport(ledId: UInt8 = sideStripeLed) -> [UInt8] {
    var args = [UInt8](repeating: 0, count: 9)
    args[0] = varStore
    args[1] = ledId
    args[2] = 0x01 // static effect
    args[5] = 0x01
    return makeReport(commandId: 0x82, dataSize: 0x09, arguments: args)
  }

  public static func brightnessReport(
    value: UInt8,
    ledId: UInt8 = zeroLed
  ) -> [UInt8] {
    let args: [UInt8] = [varStore, ledId, value]
    return makeReport(commandId: 0x04, dataSize: 0x03, arguments: args)
  }

  public static func profileIndicatorReport(layer: Int) -> [UInt8] {
    staticEffectReport(color: TartarusProLightingColor.layerIndicator(layer: layer))
  }

  public static func parseStaticColor(from response: [UInt8]) -> TartarusProLightingColor? {
    guard response.count >= reportLength else {
      return nil
    }
    guard response[6] == commandClass, response[7] == 0x82 else {
      return nil
    }
    let r = response[14]
    let g = response[15]
    let b = response[16]
    return TartarusProLightingColor(r: r, g: g, b: b)
  }

  public static func isSuccessfulResponse(_ response: [UInt8]) -> Bool {
    guard response.count >= reportLength else {
      return false
    }
    return response[0] == 0x02
  }

  public static func calculateCRC(_ report: [UInt8]) -> UInt8 {
    guard report.count >= reportLength else {
      return 0
    }
    var crc: UInt8 = 0
    for index in 2...87 {
      crc ^= report[index]
    }
    return crc
  }
}
