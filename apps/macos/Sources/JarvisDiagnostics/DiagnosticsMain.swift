import AVFoundation
import Foundation
import JarvisCore
import ParakeetTDT

@main
struct JarvisDiagnostics {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else {
                printUsage()
                return
            }

            switch command {
            case "parakeet":
                guard arguments.count == 2 else { throw DiagnosticError.missingAudioPath }
                try runParakeetBenchmark(audioURL: URL(fileURLWithPath: arguments[1]))
            case "parakeet-reuse":
                guard arguments.count == 2 else { throw DiagnosticError.missingAudioPath }
                try runParakeetReuse(audioURL: URL(fileURLWithPath: arguments[1]))
            case "hermes":
                let prompt = arguments.dropFirst().joined(separator: " ")
                try await runHermes(prompt: prompt.isEmpty ? "Reply with one short sentence confirming that J.A.R.V.I.S. is connected." : prompt)
            case "hermes-autostart":
                try await runHermesAutoStart()
            case "hermes-stop":
                try await runHermesStop()
            case "hermes-session":
                try await runHermesSessionContinuity()
            case "hermes-tool":
                try await runHermesToolEventCheck()
            case "hermes-approval-deny":
                try await runHermesApprovalDenial()
            case "tts-voices":
                listVoices()
            case "tts-cancel":
                try await runTTSCancellation(voiceIdentifier: arguments.dropFirst().first)
            case "deepgram-stt":
                guard arguments.count == 2 else { throw DiagnosticError.missingAudioPath }
                try await runDeepgramSTT(audioURL: URL(fileURLWithPath: arguments[1]))
            case "deepgram-tts":
                let text = arguments.dropFirst().joined(separator: " ")
                guard !text.isEmpty else { throw DiagnosticError.missingText }
                try await runDeepgramTTS(text: text)
            default:
                throw DiagnosticError.unknownCommand(command)
            }
        } catch {
            fputs("Diagnostic failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func runParakeetBenchmark(audioURL: URL) throws {
        let samples = try AudioLoader.loadMono16k(at: audioURL)
        let config = AppConfig()
        print("audio=\(audioURL.path) samples=\(samples.count) duration_seconds=\(format(Double(samples.count) / 16_000))")

        for computeUnits in [ParakeetComputeUnits.cpu, .gpu, .ane, .all] {
            let result = try transcribe(samples: samples, modelURL: config.parakeetModelPath, computeUnits: computeUnits)
            printResult(label: computeUnits.rawValue, result: result)
        }

        let shortSamples = Array(samples.prefix(min(samples.count, 32_000)))
        let noisySamples = addDeterministicNoise(to: shortSamples, amplitude: 0.025)
        let silentSamples = [Float](repeating: 0, count: 16_000)
        let validator = try ParakeetTranscriber(modelsRoot: config.parakeetModelPath, computeUnits: .gpu)

        printResult(label: "quality-short", result: try validator.transcribe(samples: shortSamples))
        printResult(label: "quality-noisy", result: try validator.transcribe(samples: noisySamples))
        if AudioSignal.isLikelySilent(silentSamples) {
            print("case=quality-silent inference_seconds=0.0000 rtfx=0.0000 text= rejected_by=silence-gate")
        } else {
            printResult(label: "quality-silent", result: try validator.transcribe(samples: silentSamples))
        }
    }

    private static func runParakeetReuse(audioURL: URL) throws {
        let samples = try AudioLoader.loadMono16k(at: audioURL)
        let transcriber = try ParakeetTranscriber(
            modelsRoot: AppConfig().parakeetModelPath,
            computeUnits: .ane
        )
        var totalInference = 0.0
        for turn in 1...10 {
            let result = try transcriber.transcribe(samples: samples)
            totalInference += result.inferenceDurationSeconds
            print("turn=\(turn) inference_seconds=\(format(result.inferenceDurationSeconds)) text=\(result.text)")
        }
        print("turns=10 average_inference_seconds=\(format(totalInference / 10)) model_instances=1")
    }

    private static func transcribe(
        samples: [Float],
        modelURL: URL,
        computeUnits: ParakeetComputeUnits
    ) throws -> Transcription {
        let clock = ContinuousClock()
        let loadStart = clock.now
        let transcriber = try ParakeetTranscriber(modelsRoot: modelURL, computeUnits: computeUnits)
        let loadDuration = loadStart.duration(to: clock.now)
        let result = try transcriber.transcribe(samples: samples)
        print("compute=\(computeUnits.rawValue) model_load_seconds=\(format(seconds(loadDuration)))")
        return result
    }

    private static func printResult(label: String, result: Transcription) {
        let escapedText = result.text.replacingOccurrences(of: "\n", with: " ")
        print("case=\(label) inference_seconds=\(format(result.inferenceDurationSeconds)) rtfx=\(format(result.rtfx)) text=\(escapedText)")
    }

    private static func addDeterministicNoise(to samples: [Float], amplitude: Float) -> [Float] {
        var state: UInt64 = 0x4A_41_52_56_49_53
        return samples.map { sample in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let normalized = Float(state >> 40) / Float(1 << 24)
            let noise = (normalized * 2 - 1) * amplitude
            return min(1, max(-1, sample + noise))
        }
    }

    private static func runHermesAutoStart() async throws {
        let config = AppConfig()
        guard let apiKey = config.hermesAPIKey else {
            throw DiagnosticError.missingHermesAPIKey
        }
        let controller = HermesServerController(baseURL: config.hermesBaseURL, apiKey: apiKey)
        try await controller.ensureAvailable()
        let reconnect = HermesServerController(baseURL: config.hermesBaseURL, apiKey: apiKey)
        do {
            let health = try await makeHermesClient(config: config).health()
            // A new controller has no in-memory ownership of the existing process.
            try await reconnect.ensureAvailable()
            let status = await reconnect.processStatus()
            guard status.totalStartCount == 0 else {
                throw HermesServerError.managedEndpointOccupied
            }
            print("autostart=passed reconnect=passed health=\(health)")
        } catch {
            await reconnect.shutdown()
            await controller.shutdown()
            throw error
        }
        await reconnect.shutdown()
        await controller.shutdown()
    }

    private static func runHermes(prompt: String) async throws {
        let config = AppConfig()
        let client = HermesClient(
            baseURL: config.hermesBaseURL,
            apiKey: config.hermesAPIKey,
            sessionKey: config.hermesSessionKey
        )
        let health = try await client.health()
        print("health=\(health)")
        let capabilities = try await client.capabilities()
        print("capabilities_bytes=\(capabilities.count)")

        let sessionID = "jarvis-diagnostics"
        let run = try await client.createRun(input: prompt, sessionID: sessionID)
        print("run_id=\(run.runID) status=\(run.status) session_id=\(run.sessionID ?? sessionID)")

        let stream = try await client.streamEvents(runID: run.runID)
        var terminal = false
        for try await event in stream {
            print("event=\(event.event) tool=\(event.tool ?? "-") approval=\(event.approvalID ?? "-")")
            if let delta = event.delta { print(delta, terminator: "") }
            if event.isTerminal {
                terminal = true
                if event.delta != nil { print() }
                break
            }
        }

        if !terminal {
            let reconciled = try await client.getRun(runID: run.runID)
            print("reconciled_status=\(reconciled.status) last_event=\(reconciled.lastEvent ?? "-")")
        }
    }

    private static func runHermesSessionContinuity() async throws {
        let config = AppConfig()
        let sessionID = "jarvis-diagnostics-continuity"
        let firstClient = makeHermesClient(config: config)
        let first = try await collectHermesRun(
            client: firstClient,
            input: "Remember this exact phrase for the next turn: cobalt falcon 7391. Reply only with remembered.",
            sessionID: sessionID
        )
        print("first_response=\(first.output)")

        let secondClient = makeHermesClient(config: config)
        let second = try await collectHermesRun(
            client: secondClient,
            input: "What exact phrase did I ask you to remember in the previous turn? Reply only with the phrase.",
            sessionID: sessionID
        )
        print("second_response=\(second.output)")
        guard second.output.lowercased().contains("cobalt falcon 7391") else {
            throw DiagnosticError.sessionContinuityFailed
        }
        print("session_continuity=passed")
    }

    private static func runHermesToolEventCheck() async throws {
        let config = AppConfig()
        let result = try await collectHermesRun(
            client: makeHermesClient(config: config),
            input: "Use the terminal tool to run pwd, then reply with the directory path.",
            sessionID: "jarvis-diagnostics-tool"
        )
        print("events=\(result.events.joined(separator: ","))")
        guard result.events.contains("tool.started"), result.events.contains("tool.completed") else {
            throw DiagnosticError.toolEventsNotObserved
        }
        print("tool_events=passed")
    }

    private static func runHermesApprovalDenial() async throws {
        let config = AppConfig()
        let client = makeHermesClient(config: config)
        let run = try await client.createRun(
            input: "Use the terminal tool to run exactly: rm -rf /tmp/jarvis-approval-diagnostic-target. Do not use another method.",
            sessionID: "jarvis-diagnostics-approval"
        )
        let stream = try await client.streamEvents(runID: run.runID)
        var observed = false
        for try await event in stream {
            print("event=\(event.event)")
            if event.event == "approval.request" {
                observed = true
                try await client.respondToApproval(runID: run.runID, choice: .deny)
            }
            if event.isTerminal { break }
        }
        guard observed else { throw DiagnosticError.approvalNotObserved }
        print("approval_denial=passed")
    }

    private static func collectHermesRun(
        client: HermesClient,
        input: String,
        sessionID: String
    ) async throws -> (output: String, events: [String]) {
        let run = try await client.createRun(input: input, sessionID: sessionID)
        let stream = try await client.streamEvents(runID: run.runID)
        var output = ""
        var events: [String] = []
        for try await event in stream {
            events.append(event.event)
            if let delta = event.delta { output += delta }
            if let final = event.output, !final.isEmpty { output = final }
            if event.isTerminal { break }
        }
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), events)
    }

    private static func makeHermesClient(config: AppConfig) -> HermesClient {
        HermesClient(
            baseURL: config.hermesBaseURL,
            apiKey: config.hermesAPIKey,
            sessionKey: config.hermesSessionKey
        )
    }

    private static func runHermesStop() async throws {
        let config = AppConfig()
        let client = HermesClient(
            baseURL: config.hermesBaseURL,
            apiKey: config.hermesAPIKey,
            sessionKey: config.hermesSessionKey
        )
        let run = try await client.createRun(
            input: "Count from one to one hundred slowly, one number per sentence.",
            sessionID: "jarvis-diagnostics-stop"
        )
        let clock = ContinuousClock()
        let start = clock.now
        try await client.stopRun(runID: run.runID)
        let elapsed = start.duration(to: clock.now)
        let reconciled = try await client.getRun(runID: run.runID)
        print("run_id=\(run.runID) stop_seconds=\(format(seconds(elapsed))) status=\(reconciled.status)")
    }

    private static func listVoices() {
        for voice in AVSpeechSynthesisVoice.speechVoices().sorted(by: { $0.name < $1.name }) {
            print("identifier=\(voice.identifier) name=\(voice.name) language=\(voice.language) quality=\(voice.quality.rawValue)")
        }
    }

    @MainActor
    private static func runTTSCancellation(voiceIdentifier: String?) async throws {
        if let voiceIdentifier, AVSpeechSynthesisVoice(identifier: voiceIdentifier) == nil {
            throw MacSpeechSynthesizerError.voiceNotFound(voiceIdentifier)
        }

        let synthesizer = MacSpeechSynthesizer(voiceIdentifier: voiceIdentifier)
        let contextID = UUID()
        let speech = Task {
            try await synthesizer.speak(
                "This is a deliberately long cancellation diagnostic. It should still be speaking when the stop request arrives. " +
                String(repeating: "J.A.R.V.I.S. cancellation remains responsive. ", count: 20),
                contextID: contextID
            )
        }
        try await Task.sleep(for: .milliseconds(500))

        let clock = ContinuousClock()
        let start = clock.now
        synthesizer.stop(contextID: contextID)
        _ = await speech.result
        let elapsed = start.duration(to: clock.now)
        print("voice=\(voiceIdentifier ?? "system-default") cancellation_seconds=\(format(seconds(elapsed)))")
    }

    private static func runDeepgramSTT(audioURL: URL) async throws {
        guard let apiKey = InstallationIdentity.deepgramAPIKey(), !apiKey.isEmpty else {
            throw DiagnosticError.missingDeepgramAPIKey
        }
        let samples = try AudioLoader.loadMono16k(at: audioURL)
        let preferences = AppPreferencesStore.load()
        let recognizer = DeepgramRecognizer(
            apiKey: apiKey,
            model: preferences.deepgramSTTModel,
            silenceRMSThreshold: preferences.captureProfile.silenceRMSThreshold
        )
        let result = try await recognizer.transcribe(samples: samples)
        print("provider=deepgram audio_seconds=\(format(Double(samples.count) / 16_000)) latency_seconds=\(format(seconds(result.inferenceDuration)))")
        print("transcript=\(result.text.replacingOccurrences(of: "\n", with: " "))")
    }

    @MainActor
    private static func runDeepgramTTS(text: String) async throws {
        guard let apiKey = InstallationIdentity.deepgramAPIKey(), !apiKey.isEmpty else {
            throw DiagnosticError.missingDeepgramAPIKey
        }
        let preferences = AppPreferencesStore.load()
        let synthesizer = DeepgramSynthesizer(apiKey: apiKey, model: preferences.deepgramTTSModel)
        let clock = ContinuousClock()
        let start = clock.now
        let contextID = UUID()
        try await synthesizer.speak(text, contextID: contextID)
        try await synthesizer.finish(contextID: contextID)
        print("provider=deepgram completion_seconds=\(format(seconds(start.duration(to: clock.now))))")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func printUsage() {
        print("""
        Usage:
          swift run JarvisDiagnostics parakeet /path/to/audio.wav
          swift run JarvisDiagnostics parakeet-reuse /path/to/audio.wav
          swift run JarvisDiagnostics hermes [prompt]
          swift run JarvisDiagnostics hermes-autostart
          swift run JarvisDiagnostics hermes-stop
          swift run JarvisDiagnostics hermes-session
          swift run JarvisDiagnostics hermes-tool
          swift run JarvisDiagnostics hermes-approval-deny
          swift run JarvisDiagnostics tts-voices
          swift run JarvisDiagnostics tts-cancel [voice-identifier]
          swift run JarvisDiagnostics deepgram-stt /path/to/audio.wav
          swift run JarvisDiagnostics deepgram-tts <text>
        """)
    }
}

private enum DiagnosticError: Error, CustomStringConvertible {
    case approvalNotObserved
    case missingAudioPath
    case missingDeepgramAPIKey
    case missingHermesAPIKey
    case missingText
    case sessionContinuityFailed
    case toolEventsNotObserved
    case unknownCommand(String)

    var description: String {
        switch self {
        case .approvalNotObserved:
            return "Hermes did not emit an approval request."
        case .missingAudioPath:
            return "The parakeet command requires an audio file path."
        case .missingDeepgramAPIKey:
            return "No Deepgram API key is configured in Keychain."
        case .missingHermesAPIKey:
            return "No Hermes API key is configured."
        case .missingText:
            return "The deepgram-tts command requires text to speak."
        case .sessionContinuityFailed:
            return "Hermes did not preserve the diagnostic phrase across turns."
        case .toolEventsNotObserved:
            return "Hermes did not emit both tool.started and tool.completed."
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        }
    }
}
