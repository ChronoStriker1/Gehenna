import XCTest
@testable import GehennaHID

final class GehennaHIDTests: XCTestCase {
  func testMatchDictionaryEmpty() {
    let match = HIDMatch()
    XCTAssertNil(match.toMatchingDictionary())
  }
}
