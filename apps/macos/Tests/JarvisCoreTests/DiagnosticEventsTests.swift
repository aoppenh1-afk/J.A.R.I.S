import Foundation
import XCTest
@testable import JarvisCore

final class DiagnosticEventsTests: XCTestCase {
    func testBufferRetainsOnlyNewestEvents() {
        var buffer = DiagnosticEventBuffer(capacity: 3)
        buffer.append(DiagnosticEvent(kind: .appStarted))
        buffer.append(DiagnosticEvent(kind: .networkUnavailable))
        buffer.append(DiagnosticEvent(kind: .recoveryStarted, attempt: 1))
        buffer.append(DiagnosticEvent(kind: .recoverySucceeded, attempt: 2))

        XCTAssertEqual(buffer.events.count, 3)
        XCTAssertEqual(buffer.events.map(\.kind), [
            .networkUnavailable,
            .recoveryStarted,
            .recoverySucceeded,
        ])
    }

    func testEventsContainOnlyTypedContentFreeFields() throws {
        let event = DiagnosticEvent(kind: .recoveryFailed, attempt: 3)
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["id", "timestamp", "kind", "attempt"])
        XCTAssertNil(object["transcript"])
        XCTAssertNil(object["error"])
        XCTAssertNil(object["apiKey"])
    }
}
