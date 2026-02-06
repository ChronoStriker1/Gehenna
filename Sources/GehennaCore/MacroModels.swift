import Foundation

public enum MacroStepType: String, Codable, Sendable {
  case keyDown
  case keyUp
  case delay
}

public struct MacroStep: Sendable, Codable, Equatable {
  public let type: MacroStepType
  public let keyCode: Int?
  public let modifiers: [HIDModifier]?
  public let delayMs: Int?

  public init(type: MacroStepType, keyCode: Int? = nil, modifiers: [HIDModifier]? = nil, delayMs: Int? = nil) {
    self.type = type
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.delayMs = delayMs
  }
}

public struct Macro: Sendable, Codable, Equatable {
  public let id: UUID
  public let name: String
  public let group: String?
  public let splitKeyEvents: Bool
  public let steps: [MacroStep]

  public init(
    id: UUID,
    name: String,
    group: String? = nil,
    splitKeyEvents: Bool = false,
    steps: [MacroStep]
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.splitKeyEvents = splitKeyEvents
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case group
    case splitKeyEvents
    case steps
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    group = try container.decodeIfPresent(String.self, forKey: .group)
    splitKeyEvents = try container.decodeIfPresent(Bool.self, forKey: .splitKeyEvents) ?? false
    steps = try container.decode([MacroStep].self, forKey: .steps)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(group, forKey: .group)
    try container.encode(splitKeyEvents, forKey: .splitKeyEvents)
    try container.encode(steps, forKey: .steps)
  }
}

public struct MacroLibrary: Sendable, Codable, Equatable {
  public let macros: [Macro]
  public let groups: [String]

  public init(macros: [Macro], groups: [String] = []) {
    self.macros = macros
    self.groups = groups
  }

  private enum CodingKeys: String, CodingKey {
    case macros
    case groups
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    macros = try container.decode([Macro].self, forKey: .macros)
    groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(macros, forKey: .macros)
    try container.encode(groups, forKey: .groups)
  }
}

public enum ActionType: String, Codable, Sendable {
  case key
  case macro
  case scroll
  case disabled
}

public struct Action: Sendable, Codable, Equatable {
  public let type: ActionType
  public let keyCode: Int?
  public let modifiers: [HIDModifier]?
  public let macroId: UUID?
  public let scrollMultiplier: Int?

  public init(
    type: ActionType,
    keyCode: Int? = nil,
    modifiers: [HIDModifier]? = nil,
    macroId: UUID? = nil,
    scrollMultiplier: Int? = nil
  ) {
    self.type = type
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.macroId = macroId
    self.scrollMultiplier = scrollMultiplier
  }
}

public struct Profile: Sendable, Codable, Equatable {
  public let id: UUID
  public let name: String
  public let perAppBundleId: String?
  public let bindings: [String: Action]

  public init(id: UUID, name: String, perAppBundleId: String? = nil, bindings: [String: Action]) {
    self.id = id
    self.name = name
    self.perAppBundleId = perAppBundleId
    self.bindings = bindings
  }
}
