import XCTest
@testable import JarvisCore

@MainActor
final class SettingsAutosaverTests: XCTestCase {
    func testRapidEditsApplyOnlyLatestValue() async {
        var applied: [Int] = []
        let saver = SettingsAutosaver<Int>(delay: .milliseconds(20), apply: { applied.append($0) })
        saver.schedule(1)
        saver.schedule(2)
        saver.schedule(3)
        await saver.waitUntilIdle()
        XCTAssertEqual(applied, [3])
    }

    func testEditsDuringApplicationAreSerializedAndNotLost() async {
        var applied: [Int] = []
        var activeApplications = 0
        var maximumApplications = 0
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let saver = SettingsAutosaver<Int>(delay: .zero, apply: { value in
            activeApplications += 1
            maximumApplications = max(maximumApplications, activeApplications)
            applied.append(value)
            if value == 1 {
                started?.resume()
                await withCheckedContinuation { release = $0 }
            }
            activeApplications -= 1
        })
        await withCheckedContinuation { continuation in
            started = continuation
            saver.schedule(1)
        }
        saver.schedule(2)
        saver.schedule(3)
        release?.resume()
        await saver.waitUntilIdle()
        XCTAssertEqual(applied, [1, 3])
        XCTAssertEqual(maximumApplications, 1)
    }

    func testInvalidChangeReportsFailureAndNextEditRecovers() async {
        enum Invalid: LocalizedError { case value; var errorDescription: String? { "Invalid value" } }
        var states: [SettingsSaveState] = []
        var applied: [Int] = []
        let saver = SettingsAutosaver<Int>(delay: .zero, apply: { value in
            if value < 0 { throw Invalid.value }
            applied.append(value)
        }, onState: { states.append($0) })
        saver.schedule(-1)
        await saver.waitUntilIdle()
        XCTAssertEqual(states.last, .failed("Invalid value"))
        saver.schedule(1)
        await saver.waitUntilIdle()
        XCTAssertEqual(states.last, .saved)
        XCTAssertEqual(applied, [1])
    }

    func testClosingSettingsFlushesPendingEdit() async {
        var applied: [Int] = []
        let saver = SettingsAutosaver<Int>(delay: .seconds(60), apply: { applied.append($0) })
        saver.schedule(42)
        saver.flush()
        await saver.waitUntilIdle()
        XCTAssertEqual(applied, [42])
    }
}
