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
  public let steps: [MacroStep]

  public init(id: UUID, name: String, steps: [MacroStep]) {
    self.id = id
    self.name = name
    self.steps = steps
  }
}

public enum ActionType: String, Codable, Sendable {
  case key
  case macro
  case disabled
}

public struct Action: Sendable, Codable, Equatable {
  public let type: ActionType
  public let keyCode: Int?
  public let modifiers: [HIDModifier]?
  public let macroId: UUID?

  public init(type: ActionType, keyCode: Int? = nil, modifiers: [HIDModifier]? = nil, macroId: UUID? = nil) {
    self.type = type
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.macroId = macroId
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
