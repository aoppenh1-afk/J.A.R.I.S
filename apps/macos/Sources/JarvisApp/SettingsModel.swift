import Foundation
import JarvisCore
import SwiftUI

private struct SettingsDraft: Equatable, Sendable {
    var preferences: AppPreferences
    var apiKey: String
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var preferences: AppPreferences { didSet { scheduleSave() } }
    @Published var deepgramAPIKey: String { didSet { scheduleSave() } }
    @Published private(set) var saveState: SettingsSaveState = .saved
    @Published private(set) var catalog: HermesModelCatalog?
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelError = ""

    private var savedDraft: SettingsDraft
    private let modelSession: URLSession
    private let onApply: @MainActor (AppPreferences) async throws -> Void
    private lazy var autosaver = SettingsAutosaver<SettingsDraft>(
        apply: { [weak self] draft in try await self?.save(draft) },
        onState: { [weak self] state in self?.saveState = state }
    )

    init(
        preferences: AppPreferences = AppPreferencesStore.load(),
        deepgramAPIKey: String = InstallationIdentity.deepgramAPIKey() ?? "",
        modelSession: URLSession = .shared,
        onApply: @escaping @MainActor (AppPreferences) async throws -> Void
    ) {
        self.preferences = preferences
        self.deepgramAPIKey = deepgramAPIKey
        self.savedDraft = SettingsDraft(preferences: preferences, apiKey: deepgramAPIKey)
        self.modelSession = modelSession
        self.onApply = onApply
    }

    var statusText: String {
        switch saveState {
        case .saved: "Changes save automatically"
        case .pending: "Waiting to apply changes…"
        case .applying: "Applying changes…"
        case .failed(let message): message
        }
    }

    var selectableProviders: [HermesModelCatalog.Provider] {
        catalog?.providers.filter(\.isSelectable) ?? []
    }

    var selectedProvider: HermesModelCatalog.Provider? {
        let slug = preferences.agentModel.provider.isEmpty ? catalog?.provider : preferences.agentModel.provider
        return catalog?.providers.first { $0.slug == slug }
    }

    func flush() {
        autosaver.flush()
        // Keep the settings owner alive until the last edit reaches disk, even if its window closes.
        Task { [self] in await autosaver.waitUntilIdle() }
    }

    func loadModels(refresh: Bool = false) async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelError = ""
        defer { isLoadingModels = false }
        do {
            guard let endpoint = URL(string: preferences.hermesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SettingsError.invalidEndpoint
            }
            try HermesRuntimeConfiguration.validateEndpoint(endpoint)
            let config = preferences.makeConfig()
            let client = HermesClient(
                baseURL: endpoint,
                apiKey: config.hermesAPIKey,
                sessionKey: config.hermesSessionKey,
                session: modelSession
            )
            catalog = try await client.modelCatalog(refresh: refresh)
        } catch {
            modelError = "Could not load Hermes models: \(AppErrorFormatter.displayMessage(for: error)) You can still enter a provider and model ID below."
        }
    }

    private func scheduleSave() {
        autosaver.schedule(SettingsDraft(preferences: preferences, apiKey: deepgramAPIKey))
    }

    private func save(_ draft: SettingsDraft) async throws {
        var normalized = draft
        normalized.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.preferences.hermesBaseURL = draft.preferences.hermesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.preferences.parakeetModelPath = (draft.preferences.parakeetModelPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        normalized.preferences.agentModel.provider = draft.preferences.agentModel.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.preferences.agentModel.model = draft.preferences.agentModel.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != savedDraft else { return }
        var config = normalized.preferences.makeConfig()
        config.deepgramAPIKey = normalized.apiKey.isEmpty ? nil : normalized.apiKey
        guard let endpoint = URL(string: normalized.preferences.hermesBaseURL),
              endpoint.scheme == "http" || endpoint.scheme == "https" else {
            throw SettingsError.invalidEndpoint
        }
        config.hermesBaseURL = endpoint
        do { try config.validate() }
        catch { throw SettingsError.application(AppErrorFormatter.displayMessage(for: error)) }

        let previousKey = InstallationIdentity.deepgramAPIKey()
        let credentialChanged = previousKey != config.deepgramAPIKey
        if credentialChanged && !AppPreferencesStore.saveDeepgramAPIKey(config.deepgramAPIKey) {
            throw SettingsError.credential
        }
        do {
            try await onApply(normalized.preferences)
        } catch {
            if credentialChanged { _ = AppPreferencesStore.saveDeepgramAPIKey(previousKey) }
            throw SettingsError.application(AppErrorFormatter.displayMessage(for: error))
        }
        guard AppPreferencesStore.save(normalized.preferences) else { throw SettingsError.persistence }
        savedDraft = normalized
    }
}

private enum SettingsError: LocalizedError {
    case invalidEndpoint, credential, persistence
    case application(String)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a local Hermes URL beginning with http:// or https://."
        case .credential: "Could not save the Deepgram API key in Keychain."
        case .persistence: "Settings applied, but could not be saved."
        case .application(let message): "Could not apply changes: \(message)"
        }
    }
}
