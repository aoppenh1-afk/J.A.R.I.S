import Foundation

public enum AnimationQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case energySaving
    case smooth

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .energySaving: "Save energy"
        case .smooth: "Smooth motion"
        }
    }

    public func framesPerSecond(isActive: Bool, lowPowerMode: Bool, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return 0 }
        if self == .energySaving || (self == .automatic && lowPowerMode) {
            return isActive ? 15 : 5
        }
        guard isActive else { return 10 }
        return self == .smooth ? 60 : 30
    }
}

public enum OrbVisibility: String, Codable, Sendable, CaseIterable {
    case always
    case duringRun
}

public enum AppAppearance: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public struct AppPreferences: Codable, Sendable, Equatable {
    public var speechMode: AppConfig.SpeechMode
    public var captureProfile: AppConfig.CaptureProfile
    public var hotkey: HotkeyConfiguration
    public var allowCloudFallback: Bool
    public var parakeetModelPath: String
    public var parakeetComputeUnits: String
    public var macVoiceIdentifier: String?
    public var deepgramSTTModel: String
    public var deepgramTTSModel: String
    public var hermesBaseURL: String
    public var persistTranscriptHistory: Bool
    public var speakTypedResponses: Bool
    public var appearance: AppAppearance
    public var orbVisibility: OrbVisibility
    public var automaticallySubmitOrbAfterSilence: Bool
    public var orbSilenceDuration: Double
    public var animationQuality: AnimationQuality
    public var agentModel: HermesModelSelection

    public init(
        speechMode: AppConfig.SpeechMode = .local,
        captureProfile: AppConfig.CaptureProfile = .normal,
        hotkey: HotkeyConfiguration = .commandShiftSpace,
        allowCloudFallback: Bool = false,
        parakeetModelPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.parakeet-tdt/hf-models/mweinbach1_parakeet-tdt-0.6b-v3-coreml").path,
        parakeetComputeUnits: String = "ane",
        macVoiceIdentifier: String? = MacSpeechVoice.jamiePremiumIdentifier,
        deepgramSTTModel: String = "nova-3",
        deepgramTTSModel: String = "aura-2-thalia-en",
        hermesBaseURL: String = HermesRuntimeConfiguration.managedBaseURL.absoluteString,
        persistTranscriptHistory: Bool = false,
        speakTypedResponses: Bool = false,
        appearance: AppAppearance = .system,
        orbVisibility: OrbVisibility = .duringRun,
        automaticallySubmitOrbAfterSilence: Bool = true,
        orbSilenceDuration: Double = 1.5,
        animationQuality: AnimationQuality = .automatic,
        agentModel: HermesModelSelection = .init()
    ) {
        self.speechMode = speechMode
        self.captureProfile = captureProfile
        self.hotkey = hotkey
        self.allowCloudFallback = allowCloudFallback
        self.parakeetModelPath = parakeetModelPath
        self.parakeetComputeUnits = parakeetComputeUnits
        self.macVoiceIdentifier = macVoiceIdentifier
        self.deepgramSTTModel = deepgramSTTModel
        self.deepgramTTSModel = deepgramTTSModel
        self.hermesBaseURL = hermesBaseURL
        self.persistTranscriptHistory = persistTranscriptHistory
        self.speakTypedResponses = speakTypedResponses
        self.appearance = appearance
        self.orbVisibility = orbVisibility
        self.automaticallySubmitOrbAfterSilence = automaticallySubmitOrbAfterSilence
        self.orbSilenceDuration = orbSilenceDuration
        self.animationQuality = animationQuality
        self.agentModel = agentModel
    }

    private enum CodingKeys: String, CodingKey {
        case speechMode
        case captureProfile
        case hotkey
        case allowCloudFallback
        case parakeetModelPath
        case parakeetComputeUnits
        case macVoiceIdentifier
        case deepgramSTTModel
        case deepgramTTSModel
        case hermesBaseURL
        case persistTranscriptHistory
        case speakTypedResponses
        case appearance
        case orbVisibility
        case automaticallySubmitOrbAfterSilence
        case orbSilenceDuration
        case animationQuality
        case agentModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speechMode = try container.decode(AppConfig.SpeechMode.self, forKey: .speechMode)
        captureProfile = try container.decodeIfPresent(AppConfig.CaptureProfile.self, forKey: .captureProfile) ?? .normal
        hotkey = try container.decodeIfPresent(HotkeyConfiguration.self, forKey: .hotkey) ?? .commandShiftSpace
        allowCloudFallback = try container.decode(Bool.self, forKey: .allowCloudFallback)
        parakeetModelPath = try container.decode(String.self, forKey: .parakeetModelPath)
        parakeetComputeUnits = try container.decode(String.self, forKey: .parakeetComputeUnits)
        macVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .macVoiceIdentifier)
            ?? MacSpeechVoice.jamiePremiumIdentifier
        deepgramSTTModel = try container.decode(String.self, forKey: .deepgramSTTModel)
        deepgramTTSModel = try container.decode(String.self, forKey: .deepgramTTSModel)
        let decodedHermesBaseURL = try container.decode(String.self, forKey: .hermesBaseURL)
        let isLegacy = decodedHermesBaseURL == HermesRuntimeConfiguration.legacyManagedBaseURL.absoluteString
            || URL(string: decodedHermesBaseURL).map(HermesRuntimeConfiguration.isLegacyManagedEndpoint) == true
        hermesBaseURL = isLegacy
            ? HermesRuntimeConfiguration.managedBaseURL.absoluteString
            : decodedHermesBaseURL
        persistTranscriptHistory = try container.decodeIfPresent(Bool.self, forKey: .persistTranscriptHistory) ?? false
        speakTypedResponses = try container.decodeIfPresent(Bool.self, forKey: .speakTypedResponses) ?? false
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        orbVisibility = try container.decodeIfPresent(OrbVisibility.self, forKey: .orbVisibility) ?? .duringRun
        automaticallySubmitOrbAfterSilence = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallySubmitOrbAfterSilence
        ) ?? true
        orbSilenceDuration = try container.decodeIfPresent(Double.self, forKey: .orbSilenceDuration) ?? 1.5
        animationQuality = try container.decodeIfPresent(AnimationQuality.self, forKey: .animationQuality) ?? .automatic
        agentModel = try container.decodeIfPresent(HermesModelSelection.self, forKey: .agentModel) ?? .init()
    }

    public func makeConfig() -> AppConfig {
        AppConfig(
            speechMode: speechMode,
            captureProfile: captureProfile,
            hotkey: hotkey,
            allowCloudFallback: speechMode == .local ? false : allowCloudFallback,
            parakeetModelPath: URL(fileURLWithPath: parakeetModelPath),
            parakeetComputeUnits: parakeetComputeUnits,
            macVoiceIdentifier: macVoiceIdentifier,
            deepgramAPIKey: InstallationIdentity.deepgramAPIKey(),
            deepgramSTTModel: deepgramSTTModel,
            deepgramTTSModel: deepgramTTSModel,
            hermesBaseURL: URL(string: hermesBaseURL) ?? HermesRuntimeConfiguration.managedBaseURL,
            agentModel: agentModel
        )
    }
}

public enum AppPreferencesStore {
    private static let key = "jarvis.appPreferences.v1"

    public static func load(defaults: UserDefaults = .standard) -> AppPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawURL = object["hermesBaseURL"] as? String {
            let isLegacy = rawURL == HermesRuntimeConfiguration.legacyManagedBaseURL.absoluteString
                || URL(string: rawURL).map(HermesRuntimeConfiguration.isLegacyManagedEndpoint) == true
            if isLegacy {
                _ = save(preferences, defaults: defaults)
            }
        }
        return preferences
    }

    @discardableResult
    public static func save(
        _ preferences: AppPreferences,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(preferences) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    @discardableResult
    public static func saveDeepgramAPIKey(_ value: String?) -> Bool {
        InstallationIdentity.setDeepgramAPIKey(value)
    }
}
