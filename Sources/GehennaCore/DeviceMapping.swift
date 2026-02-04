import Foundation

public struct DeviceIdentity: Sendable, Codable, Equatable {
  public let vendorId: Int
  public let productId: Int
  public let name: String

  public init(vendorId: Int, productId: Int, name: String) {
    self.vendorId = vendorId
    self.productId = productId
    self.name = name
  }
}

public struct DeviceLayout: Sendable, Codable, Equatable {
  public let name: String
  public let rows: [[String]]
  public let labels: [String: String]

  public init(name: String, rows: [[String]], labels: [String: String]) {
    self.name = name
    self.rows = rows
    self.labels = labels
  }
}

public enum InputKind: String, Codable, Sendable {
  case button
  case axis
}

public enum HIDModifier: String, Codable, Sendable, CaseIterable, Hashable {
  case leftControl = "L-Ctrl"
  case leftShift = "L-Shift"
  case leftAlt = "L-Alt"
  case leftGUI = "L-GUI"
  case rightControl = "R-Ctrl"
  case rightShift = "R-Shift"
  case rightAlt = "R-Alt"
  case rightGUI = "R-GUI"
}

public struct HIDInputIdentifier: Sendable, Codable, Hashable {
  public let interface: Int
  public let usagePage: Int
  public let usage: Int
  public let modifiers: [HIDModifier]?

  public init(
    interface: Int,
    usagePage: Int,
    usage: Int,
    modifiers: [HIDModifier]? = nil
  ) {
    self.interface = interface
    self.usagePage = usagePage
    self.usage = usage
    self.modifiers = modifiers
  }
}

public struct InputDefinition: Sendable, Codable, Equatable {
  public let kind: InputKind
  public let hid: HIDInputIdentifier

  public init(kind: InputKind, hid: HIDInputIdentifier) {
    self.kind = kind
    self.hid = hid
  }
}

public struct DeviceMapping: Sendable, Codable, Equatable {
  public let version: Int
  public let device: DeviceIdentity
  public let layout: DeviceLayout
  public let inputs: [String: InputDefinition]

  public init(
    version: Int,
    device: DeviceIdentity,
    layout: DeviceLayout,
    inputs: [String: InputDefinition]
  ) {
    self.version = version
    self.device = device
    self.layout = layout
    self.inputs = inputs
  }
}

public enum MappingError: Error, LocalizedError {
  case fileNotFound
  case decodeFailed

  public var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "Mapping file not found."
    case .decodeFailed:
      return "Failed to decode mapping file."
    }
  }
}

public struct MappingLoader {
  public init() {}

  public func load(from url: URL) throws -> DeviceMapping {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MappingError.fileNotFound
    }

    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(DeviceMapping.self, from: data)
    } catch {
      throw MappingError.decodeFailed
    }
  }
}
