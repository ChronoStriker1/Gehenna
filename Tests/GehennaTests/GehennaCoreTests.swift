import XCTest
@testable import GehennaCore

final class GehennaCoreTests: XCTestCase {
  func testKeyboardReportDecoding() {
    let report: [UInt8] = [0x01, 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00]
    let decoded = HIDKeyboardReportDecoder.decode(report: report)

    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.modifiers, HIDKeyModifiers.leftControl)
    XCTAssertEqual(decoded?.keys, [0x1E])
  }

  func testHIDKeyMapPunctuationMappings() {
    XCTAssertEqual(HIDKeyMap.keyCode(forUsage: 0x33), 41)
    XCTAssertEqual(HIDKeyMap.keyCode(forUsage: 0x34), 39)
    XCTAssertEqual(HIDKeyMap.keyCode(forUsage: 0x39), 57)
    XCTAssertEqual(HIDKeyMap.usage(forKeyCode: 41), 0x33)
    XCTAssertEqual(HIDKeyMap.usage(forKeyCode: 39), 0x34)
    XCTAssertEqual(HIDKeyMap.usage(forKeyCode: 57), 0x39)
  }

  func testMappingLoader() throws {
    let json = """
    {
      "version": 1,
      "device": { "vendorId": 1, "productId": 2, "name": "Test" },
      "layout": {
        "name": "test",
        "rows": [["k1"]],
        "labels": { "k1": "A" }
      },
      "inputs": {
        "k1": {
          "kind": "button",
          "hid": { "interface": 0, "usagePage": 7, "usage": 4, "modifiers": ["L-Ctrl"] }
        }
      }
    }
    """

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mapping-test.json")
    try json.data(using: .utf8)?.write(to: url)

    let mapping = try MappingLoader().load(from: url)
    XCTAssertEqual(mapping.device.vendorId, 1)
    XCTAssertEqual(mapping.inputs["k1"]?.hid.modifiers?.first, .leftControl)
  }

  func testProfilesLoader() throws {
    let json = """
    {
      "version": 1,
      "activeProfileId": "00000000-0000-0000-0000-000000000000",
      "profiles": [
        {
          "id": "00000000-0000-0000-0000-000000000000",
          "name": "Default",
          "perAppBundleId": null,
          "layers": {
            "1": {
              "k1": { "type": "key", "keyCode": 4, "modifiers": [] }
            }
          }
        }
      ]
    }
    """

    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profiles-test.json")
    try json.data(using: .utf8)?.write(to: url)

    let config = try ProfilesLoader().load(from: url)
    XCTAssertEqual(config.version, 1)
    XCTAssertEqual(config.profiles.first?.layers["1"]?["k1"]?.type, .key)
  }

  func testTartarusStaticReportShape() {
    let color = TartarusProLightingColor(r: 0x12, g: 0x34, b: 0x56)
    let report = TartarusProLightingProtocol.staticEffectReport(color: color)

    XCTAssertEqual(report.count, TartarusProLightingProtocol.reportLength)
    XCTAssertEqual(report[1], TartarusProLightingProtocol.transactionId)
    XCTAssertEqual(report[5], 0x09)
    XCTAssertEqual(report[6], TartarusProLightingProtocol.commandClass)
    XCTAssertEqual(report[7], 0x02)
    XCTAssertEqual(report[8], TartarusProLightingProtocol.varStore)
    XCTAssertEqual(report[9], TartarusProLightingProtocol.sideStripeLed)
    XCTAssertEqual(report[10], 0x01)
    XCTAssertEqual(report[13], 0x01)
    XCTAssertEqual(report[14], 0x12)
    XCTAssertEqual(report[15], 0x34)
    XCTAssertEqual(report[16], 0x56)
    XCTAssertEqual(report[88], TartarusProLightingProtocol.calculateCRC(report))
  }

  func testTartarusLayerIndicatorColor() {
    XCTAssertEqual(TartarusProLightingColor.layerIndicator(layer: 1), TartarusProLightingColor(r: 0xFF, g: 0x00, b: 0x00))
    XCTAssertEqual(TartarusProLightingColor.layerIndicator(layer: 2), TartarusProLightingColor(r: 0x00, g: 0xFF, b: 0x00))
    XCTAssertEqual(TartarusProLightingColor.layerIndicator(layer: 3), TartarusProLightingColor(r: 0x00, g: 0x00, b: 0xFF))
  }

  func testTartarusSpectrumEffectReportShape() {
    let report = TartarusProLightingProtocol.matrixEffectReport(effect: .spectrum)

    XCTAssertEqual(report.count, TartarusProLightingProtocol.reportLength)
    XCTAssertEqual(report[5], 0x06)
    XCTAssertEqual(report[6], TartarusProLightingProtocol.commandClass)
    XCTAssertEqual(report[7], 0x02)
    XCTAssertEqual(report[8], TartarusProLightingProtocol.varStore)
    XCTAssertEqual(report[9], TartarusProLightingProtocol.zeroLed)
    XCTAssertEqual(report[10], 0x03)
  }

  func testTartarusWaveEffectReportShape() {
    let report = TartarusProLightingProtocol.matrixEffectReport(effect: .waveLeft)

    XCTAssertEqual(report.count, TartarusProLightingProtocol.reportLength)
    XCTAssertEqual(report[5], 0x06)
    XCTAssertEqual(report[6], TartarusProLightingProtocol.commandClass)
    XCTAssertEqual(report[7], 0x02)
    XCTAssertEqual(report[8], TartarusProLightingProtocol.varStore)
    XCTAssertEqual(report[9], TartarusProLightingProtocol.zeroLed)
    XCTAssertEqual(report[10], 0x04)
    XCTAssertEqual(report[11], 0x02)
    XCTAssertEqual(report[12], 0x28)
  }

  func testTartarusBreathingDualEffectReportShape() {
    let report = TartarusProLightingProtocol.matrixEffectReport(
      effect: .breathingDual,
      primaryColor: TartarusProLightingColor(r: 0xAA, g: 0xBB, b: 0xCC),
      secondaryColor: TartarusProLightingColor(r: 0x11, g: 0x22, b: 0x33),
      speed: 2
    )

    XCTAssertEqual(report.count, TartarusProLightingProtocol.reportLength)
    XCTAssertEqual(report[5], 0x0C)
    XCTAssertEqual(report[6], TartarusProLightingProtocol.commandClass)
    XCTAssertEqual(report[7], 0x02)
    XCTAssertEqual(report[8], TartarusProLightingProtocol.varStore)
    XCTAssertEqual(report[10], 0x02)
    XCTAssertEqual(report[11], 0x02)
    XCTAssertEqual(report[13], 0x02)
    XCTAssertEqual(report[14], 0xAA)
    XCTAssertEqual(report[15], 0xBB)
    XCTAssertEqual(report[16], 0xCC)
    XCTAssertEqual(report[17], 0x11)
    XCTAssertEqual(report[18], 0x22)
    XCTAssertEqual(report[19], 0x33)
  }

  func testTartarusReactiveEffectReportShape() {
    let report = TartarusProLightingProtocol.matrixEffectReport(
      effect: .reactive,
      primaryColor: TartarusProLightingColor(r: 0x10, g: 0x20, b: 0x30),
      secondaryColor: TartarusProLightingColor(r: 0x00, g: 0x00, b: 0x00),
      speed: 4
    )

    XCTAssertEqual(report.count, TartarusProLightingProtocol.reportLength)
    XCTAssertEqual(report[5], 0x09)
    XCTAssertEqual(report[6], TartarusProLightingProtocol.commandClass)
    XCTAssertEqual(report[7], 0x02)
    XCTAssertEqual(report[8], TartarusProLightingProtocol.varStore)
    XCTAssertEqual(report[10], 0x05)
    XCTAssertEqual(report[12], 0x04)
    XCTAssertEqual(report[13], 0x01)
    XCTAssertEqual(report[14], 0x10)
    XCTAssertEqual(report[15], 0x20)
    XCTAssertEqual(report[16], 0x30)
  }
}
