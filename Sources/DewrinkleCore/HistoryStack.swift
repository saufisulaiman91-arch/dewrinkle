import Foundation

public struct HistoryEntry<State: Equatable>: Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var state: State

    public init(id: UUID = UUID(), name: String, state: State) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// Photoshop-style history. Jumping backward keeps later steps until a new edit truncates them.
public struct HistoryStack<State: Equatable>: Equatable {
    public private(set) var entries: [HistoryEntry<State>]
    public private(set) var index: Int

    public init() {
        entries = []
        index = 0
    }

    public var canUndo: Bool { index > 0 && !entries.isEmpty }
    public var canRedo: Bool { index < entries.count - 1 }

    public mutating func reset(name: String, state: State) {
        entries = [HistoryEntry(name: name, state: state)]
        index = 0
    }

    public mutating func commit(name: String, state: State) {
        guard !entries.isEmpty else {
            reset(name: name, state: state)
            return
        }
        if entries[index].state == state { return }
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)..<entries.count)
        }
        entries.append(HistoryEntry(name: name, state: state))
        index = entries.count - 1
    }

    @discardableResult
    public mutating func undo() -> State? {
        guard canUndo else { return nil }
        index -= 1
        return entries[index].state
    }

    @discardableResult
    public mutating func redo() -> State? {
        guard canRedo else { return nil }
        index += 1
        return entries[index].state
    }

    @discardableResult
    public mutating func jump(to newIndex: Int) -> State? {
        guard entries.indices.contains(newIndex) else { return nil }
        index = newIndex
        return entries[index].state
    }
}
