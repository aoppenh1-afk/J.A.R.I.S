import XCTest
@testable import JarvisCore

final class SSEParserTests: XCTestCase {
    func testParsesHermesDataEvent() throws {
        var parser = SSEParser()
        XCTAssertNil(try parser.consume(line: ": keepalive"))
        XCTAssertNil(try parser.consume(line: "data: {\"event\":\"message.delta\",\"run_id\":\"run_1\",\"timestamp\":1,\"delta\":\"Hello\"}"))

        let event = try parser.consume(line: "")
        XCTAssertEqual(event?.event, "message.delta")
        XCTAssertEqual(event?.delta, "Hello")
        XCTAssertFalse(event?.isTerminal ?? true)
    }

    func testAcceptsBooleanToolErrorField() throws {
        var parser = SSEParser()
        _ = try parser.consume(line: "data: {\"event\":\"tool.completed\",\"run_id\":\"run_1\",\"timestamp\":2,\"tool\":\"terminal\",\"error\":false}")
        let event = try parser.finish()
        XCTAssertEqual(event?.event, "tool.completed")
        XCTAssertNil(event?.error)
    }

    func testTerminalEvent() throws {
        var parser = SSEParser()
        _ = try parser.consume(line: "data: {\"event\":\"run.completed\",\"run_id\":\"run_1\",\"timestamp\":2,\"output\":\"Done\"}")
        let event = try parser.finish()
        XCTAssertTrue(event?.isTerminal ?? false)
        XCTAssertEqual(event?.output, "Done")
    }
}
