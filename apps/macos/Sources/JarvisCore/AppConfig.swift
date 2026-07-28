import Foundation

public struct AppConfig: Sendable, Equatable {
    public enum SpeechMode: String, Sendable, Codable {
        case local
        case cloud
        case auto
    }

    public enum CaptureProfile: String, Sendable, Codable, CaseIterable {
        case quiet
        case normal
        case noisy

        public var silenceRMSThreshold: Double {
            switch self {
            case .quiet: 0.001
            case .normal: 0.002
            case .noisy: 0.006
            }
        }
    }

    public var speechMode: SpeechMode
    public var captureProfile: CaptureProfile
    public var hotkey: HotkeyConfiguration
    public var allowCloudFallback: Bool
    public var parakeetModelPath: URL
    public var parakeetComputeUnits: String
    public var macVoiceIdentifier: String?
    public var deepgramAPIKey: String?
    public var deepgramSTTModel: String
    public var deepgramTTSModel: String
    public var hermesBaseURL: URL
    public var hermesAPIKey: String?
    public var hermesSessionKey: String

    public init(
        speechMode: SpeechMode = .local,
        captureProfile: CaptureProfile = .normal,
        hotkey: HotkeyConfiguration = .commandShiftSpace,
        allowCloudFallback: Bool = false,
        parakeetModelPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.parakeet-tdt/hf-models/mweinbach1_parakeet-tdt-0.6b-v3-coreml"),
        parakeetComputeUnits: String = "ane",
        macVoiceIdentifier: String? = MacSpeechVoice.jamiePremiumIdentifier,
        deepgramAPIKey: String? = InstallationIdentity.deepgramAPIKey(),
        deepgramSTTModel: String = "nova-3",
        deepgramTTSModel: String = "aura-2-thalia-en",
        hermesBaseURL: URL = URL(
            string: ProcessInfo.processInfo.environment["JARVIS_HERMES_BASE_URL"] ?? "http://127.0.0.1:8642"
        )!,
        hermesAPIKey: String? = ProcessInfo.processInfo.environment["JARVIS_HERMES_API_KEY"]
            ?? InstallationIdentity.hermesAPIKey(),
        hermesSessionKey: String = InstallationIdentity.hermesSessionKey()
    ) {
        self.speechMode = speechMode
        self.captureProfile = captureProfile
        self.hotkey = hotkey
        self.allowCloudFallback = allowCloudFallback
        self.parakeetModelPath = parakeetModelPath
        self.parakeetComputeUnits = parakeetComputeUnits
        self.macVoiceIdentifier = macVoiceIdentifier
        self.deepgramAPIKey = deepgramAPIKey
        self.deepgramSTTModel = deepgramSTTModel
        self.deepgramTTSModel = deepgramTTSModel
        self.hermesBaseURL = hermesBaseURL
        self.hermesAPIKey = hermesAPIKey
        self.hermesSessionKey = hermesSessionKey
    }

    public func validate() throws {
        if speechMode == .local && allowCloudFallback {
            throw AppConfigError.localModeCannotFallback
        }
        if speechMode == .cloud && deepgramAPIKey?.isEmpty != false {
            throw AppConfigError.cloudModeRequiresDeepgramKey
        }
        if speechMode == .auto && allowCloudFallback && deepgramAPIKey?.isEmpty != false {
            throw AppConfigError.cloudFallbackRequiresDeepgramKey
        }
        guard hermesBaseURL.host == "127.0.0.1" || hermesBaseURL.host == "localhost" || hermesBaseURL.host == "::1" else {
            throw AppConfigError.hermesMustUseLoopback
        }
    }
}

public enum AppConfigError: Error, Equatable {
    case cloudFallbackRequiresDeepgramKey
    case cloudModeRequiresDeepgramKey
    case localModeCannotFallback
    case hermesMustUseLoopback
}
