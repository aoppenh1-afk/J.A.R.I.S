import Foundation

public struct ActiveGeneration: Sendable, Equatable {
    public let runID: String
    public let value: Int
}

public struct GenerationGate: Sendable {
    public private(set) var value = 0
    public private(set) var active: ActiveGeneration?

    public init() {}

    @discardableResult
    public mutating func beginTurn() -> Int {
        value += 1
        active = nil
        return value
    }

    @discardableResult
    public mutating func activate(runID: String) -> ActiveGeneration {
        let active = ActiveGeneration(runID: runID, value: value)
        self.active = active
        return active
    }

    @discardableResult
    public mutating func invalidate() -> ActiveGeneration? {
        let previous = active
        value += 1
        active = nil
        return previous
    }

    public func accepts(runID: String, generation: Int) -> Bool {
        active == ActiveGeneration(runID: runID, value: generation) && value == generation
    }

    public mutating func complete(runID: String, generation: Int) {
        if accepts(runID: runID, generation: generation) {
            active = nil
        }
    }
}
