import Foundation
import XCTest
@testable import JarvisCore

private actor StubRecognizer: SpeechRecognizing {
    func prepare() {}

    func transcribe(samples: [Float]) -> SpeechTranscript {
        SpeechTranscript(
            text: "Test request",
            audioDuration: .seconds(1),
            inferenceDuration: .milliseconds(10)
        )
    }
}

private actor UnavailableRecognizer: SpeechRecognizing {
    struct UnexpectedTranscription: Error {}

    func prepare() {}

    func transcribe(samples: [Float]) throws -> SpeechTranscript {
        throw UnexpectedTranscription()
    }
}

private actor ControlledHermes: HermesServicing {
    private var continuation: AsyncThrowingStream<HermesEvent, Error>.Continuation?
    private var inputs: [String] = []
    private var streamsStarted = 0

    func health() -> [String: String] { ["status": "ok"] }
    func capabilities() -> Data { Data() }

    func createRun(input: String, sessionID: String?) -> HermesRun {
        inputs.append(input)
        return HermesRun(runID: "run-1", status: "running", sessionID: sessionID, output: nil, error: nil, lastEvent: nil)
    }

    func streamEvents(runID: String) -> AsyncThrowingStream<HermesEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: HermesEvent.self)
        self.continuation = continuation
        streamsStarted += 1
        return stream
    }

    func getRun(runID: String) -> HermesRun {
        HermesRun(runID: runID, status: "completed", sessionID: nil, output: nil, error: nil, lastEvent: "run.completed")
    }

    func stopRun(runID: String) {}
    func respondToApproval(runID: String, choice: HermesApprovalChoice) {}

    func send(_ event: HermesEvent) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
    }

    func isStreaming() -> Bool {
        continuation != nil
    }

    func recordedInputs() -> [String] {
        inputs
    }

    func inputCount() -> Int {
        inputs.count
    }

    func streamCount() -> Int {
        streamsStarted
    }
}

private actor ReconcilingHermes: HermesServicing {
    private let onReconciliation: @Sendable () -> Void
    private var pending: CheckedContinuation<HermesRun, Never>?
    private var runCount = 0

    init(onReconciliation: @escaping @Sendable () -> Void = {}) {
        self.onReconciliation = onReconciliation
    }

    func health() -> [String: String] { ["status": "ok"] }
    func capabilities() -> Data { Data() }
    func createRun(input: String, sessionID: String?) -> HermesRun {
        runCount += 1
        return HermesRun(runID: "run-\(runCount)", status: "running", sessionID: sessionID, output: nil, error: nil, lastEvent: nil)
    }
    func streamEvents(runID: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func getRun(runID: String) async -> HermesRun {
        if runID == "run-1" {
            return await withCheckedContinuation { continuation in
                pending = continuation
                onReconciliation()
            }
        }
        return HermesRun(runID: runID, status: "completed", sessionID: nil, output: "Current answer.", error: nil, lastEvent: "run.completed")
    }
    func stopRun(runID: String) {}
    func respondToApproval(runID: String, choice: HermesApprovalChoice) {}
    func resolve(status: String = "completed") {
        pending?.resume(returning: HermesRun(runID: "run-1", status: status, sessionID: nil, output: "Stale prior answer.", error: nil, lastEvent: nil))
        pending = nil
    }
}

private actor ContextRecorder {
    private var updates: [[ConversationTurn]] = []
    func record(_ turns: [ConversationTurn]) { updates.append(turns) }
    func recordedUpdates() -> [[ConversationTurn]] { updates }
}

private actor RecordingHermes: HermesServicing {
    private var sessionIDs: [String?] = []

    func health() -> [String: String] { ["status": "ok"] }
    func capabilities() -> Data { Data() }

    func createRun(input: String, sessionID: String?) -> HermesRun {
        sessionIDs.append(sessionID)
        return HermesRun(
            runID: "run-\(sessionIDs.count)",
            status: "running",
            sessionID: sessionID,
            output: nil,
            error: nil,
            lastEvent: nil
        )
    }

    func streamEvents(runID: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(HermesEvent(
                event: "run.completed",
                runID: runID,
                timestamp: 1,
                delta: nil,
                output: nil,
                error: nil,
                tool: nil,
                preview: nil,
                command: nil,
                choices: nil,
                choice: nil,
                resolved: nil,
                approvalID: nil
            ))
            continuation.finish()
        }
    }

    func getRun(runID: String) -> HermesRun {
        HermesRun(runID: runID, status: "completed", sessionID: nil, output: nil, error: nil, lastEvent: "run.completed")
    }

    func stopRun(runID: String) {}
    func respondToApproval(runID: String, choice: HermesApprovalChoice) {}

    func recordedSessionIDs() -> [String?] {
        sessionIDs
    }
}

private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

private actor ResetCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor SnapshotRecorder {
    private var snapshots: [VoiceSnapshot] = []
    func count() -> Int { snapshots.count }

    func record(_ snapshot: VoiceSnapshot) {
        snapshots.append(snapshot)
    }

    func latest() -> VoiceSnapshot? {
        snapshots.last
    }
}

@MainActor
private final class RecordingSynthesizer: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stoppedContexts: [UUID?] = []
    func speak(_ text: String, contextID: UUID) async throws {
        spoken.append(text)
    }

    func stop(contextID: UUID?) {
        stoppedContexts.append(contextID)
    }
}

@MainActor
private final class SlowSynthesizer: SpeechSynthesizing {
    private(set) var started = false
    private(set) var wasCancelled = false
    private(set) var finishedContexts: [UUID] = []
    func speak(_ text: String, contextID: UUID) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(10)) }
        catch { wasCancelled = true; throw error }
    }
    func stop(contextID: UUID?) {}
    func finish(contextID: UUID) { finishedContexts.append(contextID) }
}

final class VoicePipelineTests: XCTestCase {
    @MainActor
    func testLateReconciliationCannotPublishSpeakOrPersistIntoListeningTurn() async {
        for status in ["completed", "failed"] {
            let requested = expectation(description: "Reconciliation started")
            let hermes = ReconcilingHermes(onReconciliation: { requested.fulfill() })
            let snapshots = SnapshotRecorder()
            let contexts = ContextRecorder()
            let synthesizer = RecordingSynthesizer()
            let pipeline = VoicePipeline(
                recognizer: StubRecognizer(), hermes: hermes, synthesizer: synthesizer,
                onConversationContextChanged: { await contexts.record($0) },
                onSnapshot: { await snapshots.record($0) }
            )
            let oldTurn = Task { await pipeline.submit(text: "Old request", speakResponse: true) }
            await fulfillment(of: [requested], timeout: 1)
            await pipeline.beginListening()
            let listening = await snapshots.latest()
            await hermes.resolve(status: status)
            await oldTurn.value
            let after = await snapshots.latest()
            let updates = await contexts.recordedUpdates()
            XCTAssertEqual(after, listening)
            XCTAssertEqual(after?.state, .listening)
            XCTAssertEqual(after?.assistantText, "")
            XCTAssertTrue(updates.isEmpty)
            XCTAssertTrue(synthesizer.spoken.isEmpty)
        }
    }

    @MainActor
    func testLateReconciliationCannotOverwriteCompletedNewTurnOrItsContext() async {
        let requested = expectation(description: "Old reconciliation started")
        let hermes = ReconcilingHermes(onReconciliation: { requested.fulfill() })
        let snapshots = SnapshotRecorder()
        let contexts = ContextRecorder()
        let synthesizer = RecordingSynthesizer()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: synthesizer,
            onConversationContextChanged: { await contexts.record($0) },
            onSnapshot: { await snapshots.record($0) }
        )
        let oldTurn = Task { await pipeline.submit(text: "Old request", speakResponse: true) }
        await fulfillment(of: [requested], timeout: 1)
        await pipeline.submit(text: "New request", speakResponse: true)
        let current = await snapshots.latest()
        await hermes.resolve()
        await oldTurn.value
        let after = await snapshots.latest()
        let updates = await contexts.recordedUpdates()
        XCTAssertEqual(after, current)
        XCTAssertEqual(after?.assistantText, "Current answer.")
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.last?.map(\.userText), ["New request"])
        XCTAssertEqual(updates.last?.map(\.assistantText), ["Current answer."])
        XCTAssertEqual(synthesizer.spoken, ["Current answer."])
    }

    @MainActor
    func testCurrentReconciliationStillCompletesAndRecordsItsResponse() async {
        let requested = expectation(description: "Reconciliation started")
        let hermes = ReconcilingHermes(onReconciliation: { requested.fulfill() })
        let snapshots = SnapshotRecorder()
        let contexts = ContextRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: RecordingSynthesizer(),
            onConversationContextChanged: { await contexts.record($0) },
            onSnapshot: { await snapshots.record($0) }
        )
        let turn = Task { await pipeline.submit(text: "Current request", speakResponse: false) }
        await fulfillment(of: [requested], timeout: 1)
        await hermes.resolve()
        await turn.value
        let latest = await snapshots.latest()
        let updates = await contexts.recordedUpdates()
        XCTAssertEqual(latest?.state, .idle)
        XCTAssertEqual(latest?.assistantText, "Stale prior answer.")
        XCTAssertEqual(updates.last?.map(\.userText), ["Current request"])
    }

    @MainActor
    func testSpeaksCompleteSentenceBeforeRunCompletes() async throws {
        let hermes = ControlledHermes()
        let synthesizer = RecordingSynthesizer()

        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: synthesizer,
            onSnapshot: { _ in }
        )

        await pipeline.prepare()
        await pipeline.beginListening()
        let submission = Task { await pipeline.submit(samples: [0.1]) }

        while !(await hermes.isStreaming()) {
            await Task.yield()
        }
        await hermes.send(HermesEvent(
            event: "message.delta",
            runID: "run-1",
            timestamp: 1,
            delta: "First sentence. Remaining fragment",
            output: nil,
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))

        for _ in 0..<1_000 where synthesizer.spoken.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(synthesizer.spoken, ["First sentence."])

        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 2,
            delta: nil,
            output: "First sentence. Remaining fragment",
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))
        await hermes.finish()
        await submission.value

        XCTAssertEqual(synthesizer.spoken, ["First sentence.", "Remaining fragment"])
    }

    @MainActor
    func testResponseMetadataCreatesSourcesAndFollowUpsWithoutBeingSpoken() async throws {
        let hermes = ControlledHermes()
        let synthesizer = RecordingSynthesizer()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: synthesizer,
            onSnapshot: { snapshot in await recorder.record(snapshot) }
        )

        await pipeline.prepare()
        await pipeline.beginListening()
        let submission = Task { await pipeline.submit(samples: [0.1]) }
        while !(await hermes.isStreaming()) {
            await Task.yield()
        }

        let output = """
        Fixed it.
        <jarvis_ui>{"follow_up_prompts":["Run the tests"],"sources":[{"path":"Sources/VoicePipeline.swift","line":184,"label":"Streaming fix"}]}</jarvis_ui>
        """
        await hermes.send(HermesEvent(
            event: "message.delta",
            runID: "run-1",
            timestamp: 1,
            delta: "Fixed it.\n<jar",
            output: nil,
            error: nil
        ))
        await hermes.send(HermesEvent(
            event: "message.delta",
            runID: "run-1",
            timestamp: 2,
            delta: "vis_ui>{\"follow_up_prompts\":[\"Run the tests\"],\"sources\":[{\"path\":\"Sources/VoicePipeline.swift\",\"line\":184,\"label\":\"Streaming fix\"}]}</jarvis_ui>",
            output: nil,
            error: nil
        ))
        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 3,
            output: output,
            error: nil
        ))
        await hermes.finish()
        await submission.value

        let latest = await recorder.latest()
        let snapshot = try XCTUnwrap(latest)
        XCTAssertEqual(snapshot.assistantText, "Fixed it.")
        XCTAssertEqual(snapshot.followUpPrompts, ["Run the tests"])
        XCTAssertEqual(snapshot.sources, [
            ResponseSource(path: "Sources/VoicePipeline.swift", line: 184, label: "Streaming fix")
        ])
        XCTAssertEqual(synthesizer.spoken, ["Fixed it."])
    }

    @MainActor
    func testTypedFollowUpIncludesCompletedConversationContext() async {
        let hermes = ControlledHermes()
        let pipeline = VoicePipeline(
            recognizer: UnavailableRecognizer(),
            hermes: hermes,
            synthesizer: RecordingSynthesizer(),
            onSnapshot: { _ in }
        )

        let first = Task { await pipeline.submit(text: "What is 5 + 5?", speakResponse: false) }
        while await hermes.streamCount() < 1 {
            await Task.yield()
        }
        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 1,
            output: "10",
            error: nil
        ))
        await hermes.finish()
        await first.value

        let second = Task { await pipeline.submit(text: "Now add 2.", speakResponse: false) }
        while await hermes.streamCount() < 2 {
            await Task.yield()
        }
        let inputs = await hermes.recordedInputs()
        XCTAssertTrue(inputs[1].contains("<user>What is 5 + 5?</user>"))
        XCTAssertTrue(inputs[1].contains("<assistant>10</assistant>"))
        XCTAssertTrue(inputs[1].contains("<current_user_request>\nNow add 2.\n</current_user_request>"))

        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 2,
            output: "12",
            error: nil
        ))
        await hermes.finish()
        await second.value
    }

    @MainActor
    func testTypedSubmissionBypassesTranscriptionAndStaysQuiet() async {
        let hermes = ControlledHermes()
        let synthesizer = RecordingSynthesizer()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: UnavailableRecognizer(),
            hermes: hermes,
            synthesizer: synthesizer,
            onSnapshot: { snapshot in await recorder.record(snapshot) }
        )

        let submission = Task {
            await pipeline.submit(text: "  Typed request  ", speakResponse: false)
        }
        while !(await hermes.isStreaming()) {
            await Task.yield()
        }
        await hermes.send(HermesEvent(
            event: "message.delta",
            runID: "run-1",
            timestamp: 1,
            delta: "Quiet response.",
            output: nil,
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))
        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 2,
            delta: nil,
            output: "Quiet response.",
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))
        await hermes.finish()
        await submission.value

        let snapshot = await recorder.latest()
        let inputs = await hermes.recordedInputs()
        XCTAssertEqual(inputs, ["Typed request"])
        XCTAssertEqual(snapshot?.userText, "Typed request")
        XCTAssertEqual(snapshot?.assistantText, "Quiet response.")
        XCTAssertNil(snapshot?.speechProvider)
        XCTAssertNil(snapshot?.metrics.sttMilliseconds)
        XCTAssertEqual(snapshot?.state, .idle)
        XCTAssertTrue(synthesizer.spoken.isEmpty)
    }

    @MainActor
    func testTypedSubmissionSpeaksWhenEnabled() async {
        let hermes = ControlledHermes()
        let synthesizer = RecordingSynthesizer()
        let pipeline = VoicePipeline(
            recognizer: UnavailableRecognizer(),
            hermes: hermes,
            synthesizer: synthesizer,
            onSnapshot: { _ in }
        )

        let submission = Task {
            await pipeline.submit(text: "Typed request", speakResponse: true)
        }
        while !(await hermes.isStreaming()) {
            await Task.yield()
        }
        await hermes.send(HermesEvent(
            event: "message.delta",
            runID: "run-1",
            timestamp: 1,
            delta: "Spoken response.",
            output: nil,
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))
        await hermes.send(HermesEvent(
            event: "run.completed",
            runID: "run-1",
            timestamp: 2,
            delta: nil,
            output: "Spoken response.",
            error: nil,
            tool: nil,
            preview: nil,
            command: nil,
            choices: nil,
            choice: nil,
            resolved: nil,
            approvalID: nil
        ))
        await hermes.finish()
        await submission.value

        XCTAssertEqual(synthesizer.spoken, ["Spoken response."])
    }

    @MainActor
    func testBargeInRecordsContentFreeInterruptionLatency() async {
        let hermes = ControlledHermes()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: RecordingSynthesizer(),
            onSnapshot: { snapshot in await recorder.record(snapshot) }
        )

        await pipeline.beginListening()
        let submission = Task { await pipeline.submit(samples: [0.1]) }
        while !(await hermes.isStreaming()) {
            await Task.yield()
        }

        await pipeline.beginListening()
        let snapshot = await recorder.latest()
        await hermes.finish()
        await submission.value

        XCTAssertNotNil(snapshot?.metrics.interruptionMilliseconds)
        XCTAssertEqual(snapshot?.userText, "")
        XCTAssertEqual(snapshot?.assistantText, "")
    }

    @MainActor
    func testSessionExpiresFiveMinutesAfterLatestPrompt() async {
        let hermes = RecordingHermes()
        let uptime = TestUptime()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: RecordingSynthesizer(),
            sessionID: "initial-session",
            conversationTimeout: 300,
            uptime: { uptime.now() },
            onSnapshot: { _ in }
        )

        await pipeline.submit(samples: [0.1])
        uptime.advance(by: 250)
        await pipeline.submit(samples: [0.1])
        uptime.advance(by: 250)
        await pipeline.submit(samples: [0.1])
        uptime.advance(by: 301)
        await pipeline.submit(samples: [0.1])

        let sessionIDs = await hermes.recordedSessionIDs()
        XCTAssertEqual(sessionIDs.count, 4)
        XCTAssertEqual(sessionIDs[0], "initial-session")
        XCTAssertEqual(sessionIDs[1], "initial-session")
        XCTAssertEqual(sessionIDs[2], "initial-session")
        XCTAssertNotEqual(sessionIDs[3], "initial-session")
    }

    @MainActor
    func testSessionExpiryNotifiesConversationSessionReset() async {
        let hermes = RecordingHermes()
        let uptime = TestUptime()
        let resetCount = ResetCounter()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: RecordingSynthesizer(),
            sessionID: "initial-session",
            conversationTimeout: 300,
            uptime: { uptime.now() },
            onConversationSessionReset: {
                await resetCount.increment()
            },
            onSnapshot: { _ in }
        )

        await pipeline.submit(samples: [0.1])
        let beforeExpiry = await resetCount.value()
        XCTAssertEqual(beforeExpiry, 0)

        uptime.advance(by: 301)
        await pipeline.submit(samples: [0.1])
        let afterExpiry = await resetCount.value()
        XCTAssertEqual(afterExpiry, 1)
    }

    @MainActor
    func testNewConversationImmediatelyRotatesSession() async {
        let hermes = RecordingHermes()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: hermes,
            synthesizer: RecordingSynthesizer(),
            sessionID: "initial-session",
            onSnapshot: { _ in }
        )

        await pipeline.submit(samples: [0.1])
        await pipeline.newConversation()
        await pipeline.submit(samples: [0.1])

        let sessionIDs = await hermes.recordedSessionIDs()
        XCTAssertEqual(sessionIDs.count, 2)
        XCTAssertEqual(sessionIDs[0], "initial-session")
        XCTAssertNotEqual(sessionIDs[1], "initial-session")
    }

    @MainActor
    func testInterruptionCancelsSilentEventStreamWithoutWaitingForServer() async {
        let hermes = ControlledHermes()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: RecordingSynthesizer(),
            onSnapshot: { await recorder.record($0) }
        )
        let finished = expectation(description: "Interrupted submission returns")
        let submission = Task {
            await pipeline.submit(text: "Wait for tools", speakResponse: false)
            finished.fulfill()
        }
        while !(await hermes.isStreaming()) { await Task.yield() }
        await pipeline.beginListening()
        await fulfillment(of: [finished], timeout: 1)
        let latest = await recorder.latest()
        XCTAssertEqual(latest?.state, .listening)
        XCTAssertNil(latest?.activeRunID)
        submission.cancel()
        await hermes.finish()
        await submission.value
    }

    @MainActor
    func testBurstOfTextIsCoalescedAndToolEventsStayImmediate() async {
        let hermes = ControlledHermes()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: RecordingSynthesizer(),
            onSnapshot: { await recorder.record($0) }
        )
        let submission = Task { await pipeline.submit(text: "Request", speakResponse: false) }
        while !(await hermes.isStreaming()) { await Task.yield() }
        for index in 0..<100 {
            await hermes.send(HermesEvent(event: "message.delta", runID: "run-1", timestamp: Double(index), delta: "x"))
        }
        await hermes.send(HermesEvent(event: "tool.started", runID: "run-1", timestamp: 101, tool: "search"))
        for _ in 0..<1_000 {
            if await recorder.latest()?.state == .tool { break }
            await Task.yield()
        }
        let toolSnapshot = await recorder.latest()
        XCTAssertEqual(toolSnapshot?.state, .tool)
        XCTAssertFalse(toolSnapshot?.assistantText.isEmpty ?? true)
        XCTAssertTrue(String(repeating: "x", count: 100).hasPrefix(toolSnapshot?.assistantText ?? ""))
        XCTAssertEqual(toolSnapshot?.toolActivities.first?.name, "search")
        await hermes.send(HermesEvent(event: "run.completed", runID: "run-1", timestamp: 102,
                                     output: String(repeating: "x", count: 100)))
        await hermes.finish()
        await submission.value
        let count = await recorder.count()
        let latest = await recorder.latest()
        XCTAssertLessThan(count, 30)
        XCTAssertEqual(latest?.assistantText, String(repeating: "x", count: 100))
        XCTAssertEqual(latest?.state, .idle)
    }

    @MainActor
    func testBeginListeningStopsCurrentSpeechContext() async {
        let synthesizer = RecordingSynthesizer()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(),
            hermes: ControlledHermes(),
            synthesizer: synthesizer,
            onSnapshot: { _ in }
        )

        await pipeline.beginListening()

        XCTAssertEqual(synthesizer.stoppedContexts.count, 1)
    }

    @MainActor
    func testStopCancelsSpeechAfterHermesHasCompleted() async {
        let hermes = ControlledHermes()
        let synthesizer = SlowSynthesizer()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: synthesizer,
            onSnapshot: { await recorder.record($0) }
        )
        let returned = expectation(description: "Playback submission cancels")
        let submission = Task {
            await pipeline.submit(text: "Speak a reply", speakResponse: true)
            returned.fulfill()
        }
        while !(await hermes.isStreaming()) { await Task.yield() }
        await hermes.send(HermesEvent(event: "run.completed", runID: "run-1", timestamp: 1, output: "Speaking."))
        for _ in 0..<1_000 where !synthesizer.started { await Task.yield() }
        XCTAssertTrue(synthesizer.started)
        await pipeline.cancelCurrentTurn()
        await fulfillment(of: [returned], timeout: 1)
        let latest = await recorder.latest()
        XCTAssertEqual(latest?.statusText, "Stopped")
        XCTAssertTrue(synthesizer.wasCancelled)
        XCTAssertTrue(synthesizer.finishedContexts.isEmpty)
        submission.cancel()
        await submission.value
    }

    @MainActor
    func testStopCancelsToolAndPreservesPartialResponseWithoutRecordingIt() async {
        let hermes = ControlledHermes()
        let recorder = SnapshotRecorder()
        let pipeline = VoicePipeline(
            recognizer: StubRecognizer(), hermes: hermes, synthesizer: RecordingSynthesizer(),
            onSnapshot: { await recorder.record($0) }
        )
        let submission = Task { await pipeline.submit(text: "Run tools", speakResponse: false) }
        while !(await hermes.isStreaming()) { await Task.yield() }
        await hermes.send(HermesEvent(event: "message.delta", runID: "run-1", timestamp: 1,
                                     delta: "Partial answer that remains visible."))
        await hermes.send(HermesEvent(event: "tool.started", runID: "run-1", timestamp: 2, tool: "search"))
        for _ in 0..<1_000 {
            if await recorder.latest()?.state == .tool { break }
            await Task.yield()
        }
        await pipeline.cancelCurrentTurn()
        await submission.value
        let stopped = await recorder.latest()
        XCTAssertEqual(stopped?.state, .idle)
        XCTAssertEqual(stopped?.statusText, "Stopped")
        XCTAssertNil(stopped?.activeRunID)
        XCTAssertNil(stopped?.approval)
        XCTAssertFalse(stopped?.assistantText.isEmpty ?? true)
        XCTAssertEqual(stopped?.toolActivities.first?.state, .cancelled)

        let followUp = Task { await pipeline.submit(text: "Next request", speakResponse: false) }
        while await hermes.streamCount() < 2 { await Task.yield() }
        let inputs = await hermes.recordedInputs()
        XCTAssertEqual(inputs.last, "Next request")
        await pipeline.cancelCurrentTurn()
        await followUp.value
    }
}
