import Foundation

public struct LayeredProfile: Sendable, Codable, Equatable {
  public let id: UUID
  public let name: String
  public let perAppBundleId: String?
  public let dpadMode: DPadMode?
  public let layers: [String: [String: Action]]

  public init(
    id: UUID,
    name: String,
    perAppBundleId: String? = nil,
    dpadMode: DPadMode? = nil,
    layers: [String: [String: Action]]
  ) {
    self.id = id
    self.name = name
    self.perAppBundleId = perAppBundleId
    self.dpadMode = dpadMode
    self.layers = layers
  }
}

public enum DPadMode: String, Codable, Sendable, CaseIterable {
  case fourWay = "fourWay"
  case eightWay = "eightWay"
}

public struct ProfilesConfig: Sendable, Codable, Equatable {
  public let version: Int
  public let activeProfileId: UUID?
  public let profiles: [LayeredProfile]

  public init(version: Int, activeProfileId: UUID? = nil, profiles: [LayeredProfile]) {
    self.version = version
    self.activeProfileId = activeProfileId
    self.profiles = profiles
  }
}

public enum ProfilesError: Error, LocalizedError {
  case fileNotFound
  case decodeFailed

  public var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "Profiles file not found."
    case .decodeFailed:
      return "Failed to decode profiles file."
    }
  }
}

public struct ProfilesLoader {
  public init() {}

  public func load(from url: URL) throws -> ProfilesConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ProfilesError.fileNotFound
    }

    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(ProfilesConfig.self, from: data)
    } catch {
      throw ProfilesError.decodeFailed
    }
  }
}

public enum MacroLibraryError: Error, LocalizedError {
  case fileNotFound
  case decodeFailed

  public var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "Macros file not found."
    case .decodeFailed:
      return "Failed to decode macros file."
    }
  }
}

public struct MacroLibraryLoader {
  public init() {}

  public func load(from url: URL) throws -> MacroLibrary {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MacroLibraryError.fileNotFound
    }

    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(MacroLibrary.self, from: data)
    } catch {
      throw MacroLibraryError.decodeFailed
    }
  }
}
