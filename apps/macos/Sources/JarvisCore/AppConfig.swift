import Foundation

public enum HermesRuntimeConfiguration {
    public static let profileName = "jarvis"
    public static let legacyManagedBaseURL = URL(string: "http://127.0.0.1:8642")!
    public static let managedBaseURL = URL(string: "http://127.0.0.1:8643")!

    /// Apply this before attaching credentials, including to redirected requests.
    public static func validateEndpoint(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme == "http" || components.scheme == "https",
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil else {
            throw AppConfigError.hermesMustUseLoopback
        }
    }

    public static func locateExecutable(
        override: String? = ProcessInfo.processInfo.environment["JARVIS_HERMES_EXECUTABLE"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        [override, homeDirectory.appending(path: ".local/bin/hermes").path,
         "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            .compactMap { $0 }
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    public static func isManagedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let isLoopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(components.host?.lowercased() ?? "")
        return components.scheme == "http"
            && isLoopback
            && components.port == 8643
            && (components.path.isEmpty || components.path == "/")
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    public static func isLegacyManagedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let isLoopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(components.host?.lowercased() ?? "")
        return components.scheme == "http"
            && isLoopback
            && components.port == 8642
            && (components.path.isEmpty || components.path == "/")
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }
}

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
    public var agentModel: HermesModelSelection

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
        hermesBaseURL: URL = ProcessInfo.processInfo.environment["JARVIS_HERMES_BASE_URL"]
            .flatMap(URL.init(string:))
            ?? HermesRuntimeConfiguration.managedBaseURL,
        hermesAPIKey: String? = ProcessInfo.processInfo.environment["JARVIS_HERMES_API_KEY"]
            ?? InstallationIdentity.hermesAPIKey(),
        hermesSessionKey: String = InstallationIdentity.hermesSessionKey(),
        agentModel: HermesModelSelection = .init()
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
        self.agentModel = agentModel
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
        try HermesRuntimeConfiguration.validateEndpoint(hermesBaseURL)
    }

    /// Hotkey and agent model changes do not require reloading speech models.
    public func requiresRuntimeRebuild(comparedTo previous: AppConfig) -> Bool {
        var comparable = self
        comparable.hotkey = previous.hotkey
        comparable.agentModel = previous.agentModel
        return comparable != previous
    }
}

public enum AppConfigError: Error, Equatable {
    case cloudFallbackRequiresDeepgramKey
    case cloudModeRequiresDeepgramKey
    case localModeCannotFallback
    case hermesMustUseLoopback
}
