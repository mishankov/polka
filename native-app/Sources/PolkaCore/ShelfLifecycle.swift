import Foundation

public enum ShelfDestination: String, Codable, CaseIterable {
  case apps, clipboard, snippets, emoji, files, settings, about
}

public struct ShelfEntry: Equatable {
  public var revision: Int
  public var sessionID: Int
  public var destination: ShelfDestination
  public var resumes: Bool
  public var searchQuery: String
}

/// The same revision and one-use session rules as the released shelf.
public final class ShelfLifecycle {
  public enum Phase { case hidden, preparing, open, closing }
  public private(set) var phase: Phase = .hidden
  public private(set) var revision = 0
  public private(set) var sessionID = 0
  private var destination: ShelfDestination = .apps
  private var committed = false
  private var remembered: (destination: ShelfDestination, closedAt: Double)?
  private var preparing: ShelfEntry?
  public init() {}
  public var requested: Bool { phase == .preparing || phase == .open }
  public func begin(_ explicit: ShelfDestination?, now: Double, query: String = "") -> (
    ShelfEntry, Bool
  ) {
    let newSession = !requested
    if newSession { sessionID += 1 }
    let restorable: Set<ShelfDestination> = [.apps, .clipboard, .snippets, .emoji, .files]
    let previous: ShelfDestination? =
      committed
      ? destination
      : remembered.flatMap {
        now >= $0.closedAt && now - $0.closedAt < 60_000 ? $0.destination : nil
      }
    let resume = explicit == nil && previous.map(restorable.contains) == true
    revision += 1
    let entry = ShelfEntry(
      revision: revision, sessionID: sessionID,
      destination: explicit ?? (resume ? previous ?? .apps : .apps), resumes: resume,
      searchQuery: query)
    preparing = entry
    phase = .preparing
    return (entry, newSession)
  }
  @discardableResult public func commit(_ value: Int) -> Bool {
    guard phase == .preparing, let entry = preparing, entry.revision == value else { return false }
    destination = entry.destination
    committed = true
    phase = .open
    return true
  }
  @discardableResult public func close(now: Double) -> Bool {
    guard requested else { return false }
    if committed { remembered = (destination, now) }
    committed = false
    preparing = nil
    revision += 1
    phase = .closing
    return true
  }
  @discardableResult public func finishClose(_ value: Int) -> Bool {
    guard phase == .closing, revision == value else { return false }
    phase = .hidden
    return true
  }
}

public final class ShelfHover {
  private var enteredAt: Double?
  private var leftAt: Double?
  private var suppressed = false
  public init() {}
  public func dismiss() {
    suppressed = true
    enteredAt = nil
    leftAt = nil
  }
  public func step(now: Double, inTarget: Bool, inCorridor: Bool, visible: Bool) -> Bool? {
    if !inTarget {
      suppressed = false
      enteredAt = nil
    }
    if visible {
      enteredAt = nil
      if inCorridor {
        leftAt = nil
      } else {
        if leftAt == nil { leftAt = now }
        if now - leftAt! >= 150 {
          leftAt = nil
          return false
        }
      }
    } else {
      leftAt = nil
      if inTarget && !suppressed {
        if enteredAt == nil { enteredAt = now }
        if now - enteredAt! >= 350 {
          enteredAt = nil
          return true
        }
      }
    }
    return nil
  }
}
