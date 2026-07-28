import XCTest
@testable import JarvisCore

final class GenerationGateTests: XCTestCase {
    func testInvalidationRejectsLateRunEvents() {
        var gate = GenerationGate()
        let turn = gate.beginTurn()
        let active = gate.activate(runID: "run_old")

        XCTAssertEqual(turn, active.value)
        XCTAssertTrue(gate.accepts(runID: "run_old", generation: active.value))

        XCTAssertEqual(gate.invalidate(), active)
        XCTAssertFalse(gate.accepts(runID: "run_old", generation: active.value))

        let replacementTurn = gate.beginTurn()
        let replacement = gate.activate(runID: "run_new")
        XCTAssertEqual(replacementTurn, replacement.value)
        XCTAssertTrue(gate.accepts(runID: "run_new", generation: replacement.value))
    }
}
