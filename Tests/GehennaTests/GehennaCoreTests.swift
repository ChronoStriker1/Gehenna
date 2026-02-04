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
}
