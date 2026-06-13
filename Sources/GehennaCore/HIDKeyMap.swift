import Foundation

public enum HIDKeyMap {
  public static let usageToKeyCode: [Int: Int] = [
    0x04: 0,   // A
    0x05: 11,  // B
    0x06: 8,   // C
    0x07: 2,   // D
    0x08: 14,  // E
    0x09: 3,   // F
    0x0A: 5,   // G
    0x0B: 4,   // H
    0x0C: 34,  // I
    0x0D: 38,  // J
    0x0E: 40,  // K
    0x0F: 37,  // L
    0x10: 46,  // M
    0x11: 45,  // N
    0x12: 31,  // O
    0x13: 35,  // P
    0x14: 12,  // Q
    0x15: 15,  // R
    0x16: 1,   // S
    0x17: 17,  // T
    0x18: 32,  // U
    0x19: 9,   // V
    0x1A: 13,  // W
    0x1B: 7,   // X
    0x1C: 16,  // Y
    0x1D: 6,   // Z
    0x1E: 18,  // 1
    0x1F: 19,  // 2
    0x20: 20,  // 3
    0x21: 21,  // 4
    0x22: 23,  // 5
    0x23: 22,  // 6
    0x24: 26,  // 7
    0x25: 28,  // 8
    0x26: 25,  // 9
    0x27: 29,  // 0
    0x28: 36,  // Return
    0x29: 53,  // Escape
    0x2A: 51,  // Delete (Backspace)
    0x2B: 48,  // Tab
    0x2C: 49,  // Space
    0x2D: 27,  // -
    0x2E: 24,  // =
    0x2F: 33,  // [
    0x30: 30,  // ]
    0x31: 42,  // \\
    0x33: 41,  // ;
    0x34: 39,  // '
    0x35: 50,  // `
    0x36: 43,  // ,
    0x37: 47,  // .
    0x38: 44,  // /
    0x39: 57,  // CapsLock
    0x3A: 122, // F1
    0x3B: 120, // F2
    0x3C: 99,  // F3
    0x3D: 118, // F4
    0x3E: 96,  // F5
    0x3F: 97,  // F6
    0x40: 98,  // F7
    0x41: 100, // F8
    0x42: 101, // F9
    0x43: 109, // F10
    0x44: 103, // F11
    0x45: 111, // F12
    0x4F: 124, // Right
    0x50: 123, // Left
    0x51: 125, // Down
    0x52: 126, // Up
    0xE0: 59,  // L-Ctrl
    0xE1: 56,  // L-Shift
    0xE2: 58,  // L-Alt
    0xE3: 55,  // L-GUI
    0xE4: 62,  // R-Ctrl
    0xE5: 60,  // R-Shift
    0xE6: 61,  // R-Alt
    0xE7: 54   // R-GUI
  ]

  public static func keyCode(forUsage usage: Int) -> Int? {
    usageToKeyCode[usage]
  }

  public static func usage(forKeyCode keyCode: Int) -> Int? {
    keyCodeToUsage[keyCode]
  }

  private static let keyCodeToUsage: [Int: Int] = {
    var map: [Int: Int] = [:]
    for (usage, keyCode) in usageToKeyCode {
      map[keyCode] = usage
    }
    return map
  }()
}
