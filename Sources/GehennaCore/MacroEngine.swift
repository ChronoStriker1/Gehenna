import Foundation

public struct ScheduledAction: Sendable, Equatable {
  public let timeOffsetMs: Int
  public let action: Action

  public init(timeOffsetMs: Int, action: Action) {
    self.timeOffsetMs = timeOffsetMs
    self.action = action
  }
}

public enum MacroEngineError: Error, LocalizedError {
  case invalidStep

  public var errorDescription: String? {
    switch self {
    case .invalidStep:
      return "Macro contains an invalid step."
    }
  }
}

public struct MacroEngine {
  public init() {}

  public func schedule(macro: Macro) throws -> [ScheduledAction] {
    var timeline: [ScheduledAction] = []
    var offsetMs = 0

    for step in macro.steps {
      switch step.type {
      case .delay:
        guard let delayMs = step.delayMs else {
          throw MacroEngineError.invalidStep
        }
        offsetMs += max(0, delayMs)
      case .keyDown, .keyUp:
        guard let keyCode = step.keyCode else {
          throw MacroEngineError.invalidStep
        }
        let action = Action(
          type: .key,
          keyCode: keyCode,
          modifiers: step.modifiers
        )
        timeline.append(ScheduledAction(timeOffsetMs: offsetMs, action: action))
      }
    }

    return timeline
  }
}
