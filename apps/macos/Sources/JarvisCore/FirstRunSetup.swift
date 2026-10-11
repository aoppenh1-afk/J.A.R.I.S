import Foundation

public enum FirstRunSetupStore {
    private static let key = "jarvis.firstRunSetupComplete.v1"

    public static func isComplete(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func markComplete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}

/// File checks only. API compatibility and model loading are checked when setup starts the runtime.
public struct SetupReadiness: Sendable, Equatable {
    public struct Check: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            case endpoint, hermesExecutable, hermesProfile, localModel, cloudCredential
        }

        public let id: Kind
        public let title: String
        public let detail: String
        public let isReady: Bool
    }

    public let checks: [Check]
    public var canStart: Bool { checks.allSatisfy(\.isReady) }

    public static func inspect(
        preferences: AppPreferences,
        hasCloudCredential: Bool,
        executableURL: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SetupReadiness {
        let endpoint = URL(string: preferences.hermesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let endpointValid = endpoint.map { (try? HermesRuntimeConfiguration.validateEndpoint($0)) != nil } ?? false
        var checks = [Check(
            id: .endpoint, title: "Local Hermes endpoint",
            detail: endpointValid ? preferences.hermesBaseURL : "Enter an HTTP or HTTPS URL using 127.0.0.1, localhost, or ::1.",
            isReady: endpointValid
        )]

        if endpoint.map(HermesRuntimeConfiguration.isManagedEndpoint) == true {
            checks.append(Check(
                id: .hermesExecutable, title: "Hermes command-line app",
                detail: executableURL?.path ?? "Install Hermes CLI, then check again. The desktop app alone is not enough.",
                isReady: executableURL != nil
            ))
            let profile = homeDirectory.appending(path: ".hermes/profiles/jarvis/config.yaml")
            let profileReady = FileManager.default.isReadableFile(atPath: profile.path)
            checks.append(Check(
                id: .hermesProfile, title: "J.A.R.V.I.S. profile",
                detail: profileReady ? "Profile configuration found. Provider access is configured in Hermes."
                    : "Create the jarvis profile and configure its provider in Terminal using the commands below.",
                isReady: profileReady
            ))
        }

        if preferences.speechMode != .cloud {
            let path = (preferences.parakeetModelPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            let modelURL = URL(fileURLWithPath: path)
            let modelReady = (try? ParakeetModelCacheValidator.validate(at: modelURL)) != nil
            let canFallback = preferences.speechMode == .auto && preferences.allowCloudFallback && hasCloudCredential
            checks.append(Check(
                id: .localModel, title: "Local speech model",
                detail: modelReady ? "Encoder, decoder, joint model, and tokenizer files are present."
                    : canFallback ? "Local files are incomplete. Your enabled cloud fallback will be used."
                    : "Choose a complete Parakeet Core ML folder with encoder, decoder, joint, and tokenizer files.",
                isReady: modelReady || canFallback
            ))
        }

        if preferences.speechMode == .cloud || (preferences.speechMode == .auto && preferences.allowCloudFallback) {
            checks.append(Check(
                id: .cloudCredential, title: "Cloud speech credential",
                detail: hasCloudCredential ? "Deepgram key provided. Audio will be sent to Deepgram in your selected mode."
                    : "Enter a Deepgram API key, or choose Local speech.",
                isReady: hasCloudCredential
            ))
        }
        return SetupReadiness(checks: checks)
    }
}
