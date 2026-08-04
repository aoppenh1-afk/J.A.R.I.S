import XCTest
@testable import JarvisCore

final class AppPreferencesTests: XCTestCase {
    func testPersistsNonSecretSettings() throws {
        let suiteName = "JarvisCoreTests.AppPreferences"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var preferences = AppPreferences()
        preferences.speechMode = .auto
        preferences.allowCloudFallback = true
        preferences.deepgramSTTModel = "nova-3-test"
        preferences.deepgramTTSModel = "aura-2-luna-en"
        preferences.speakTypedResponses = true
        preferences.appearance = .dark
        preferences.orbVisibility = .always
        preferences.voiceOrbStyle = .glass
        preferences.shuffleVoiceOrbs = true
        preferences.shuffledVoiceOrbStyles = [.radial, .glass]
        preferences.automaticallySubmitOrbAfterSilence = false
        preferences.orbSilenceDuration = 2.25

        XCTAssertTrue(AppPreferencesStore.save(preferences, defaults: defaults))
        let loaded = AppPreferencesStore.load(defaults: defaults)
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(loaded.makeConfig().deepgramTTSModel, "aura-2-luna-en")
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToDedicatedHermesEndpoint() {
        XCTAssertEqual(
            AppPreferences().hermesBaseURL,
            HermesRuntimeConfiguration.managedBaseURL.absoluteString
        )
        XCTAssertEqual(
            AppPreferences().makeConfig().hermesBaseURL,
            HermesRuntimeConfiguration.managedBaseURL
        )
    }

    func testDefaultsToJamiePremiumVoice() {
        XCTAssertEqual(
            AppPreferences().macVoiceIdentifier,
            MacSpeechVoice.jamiePremiumIdentifier
        )
        XCTAssertEqual(
            AppPreferences().makeConfig().macVoiceIdentifier,
            MacSpeechVoice.jamiePremiumIdentifier
        )
    }

    func testMigratesExactLegacyHermesEndpoint() throws {
        let encoded = try JSONEncoder().encode(AppPreferences(
            hermesBaseURL: HermesRuntimeConfiguration.legacyManagedBaseURL.absoluteString
        ))

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        XCTAssertEqual(decoded.hermesBaseURL, HermesRuntimeConfiguration.managedBaseURL.absoluteString)
    }

    func testPersistsLegacyHermesEndpointMigration() throws {
        let suiteName = "JarvisCoreTests.LegacyHermesEndpoint"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let legacy = AppPreferences(
            hermesBaseURL: HermesRuntimeConfiguration.legacyManagedBaseURL.absoluteString
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: "jarvis.appPreferences.v1")

        let loaded = AppPreferencesStore.load(defaults: defaults)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "jarvis.appPreferences.v1"))
        let persisted = try JSONDecoder().decode(AppPreferences.self, from: persistedData)

        XCTAssertEqual(loaded.hermesBaseURL, HermesRuntimeConfiguration.managedBaseURL.absoluteString)
        XCTAssertEqual(persisted.hermesBaseURL, HermesRuntimeConfiguration.managedBaseURL.absoluteString)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPreservesCustomHermesEndpoint() throws {
        let customURL = "http://127.0.0.1:9000"
        let encoded = try JSONEncoder().encode(AppPreferences(hermesBaseURL: customURL))

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        XCTAssertEqual(decoded.hermesBaseURL, customURL)
    }

    func testMigratesMissingVoiceToJamiePremium() throws {
        let suiteName = "JarvisCoreTests.LegacyVoicePreferences"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let legacyPreferences = AppPreferences(macVoiceIdentifier: nil)
        defaults.set(try JSONEncoder().encode(legacyPreferences), forKey: "jarvis.appPreferences.v1")

        XCTAssertEqual(
            AppPreferencesStore.load(defaults: defaults).macVoiceIdentifier,
            MacSpeechVoice.jamiePremiumIdentifier
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMissingAppearanceDefaultsToSystem() throws {
        let encoded = try JSONEncoder().encode(AppPreferences(appearance: .dark))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appearance")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        XCTAssertEqual(decoded.appearance, .system)
    }

    func testMissingOrbVisibilityDefaultsToDuringRun() throws {
        let encoded = try JSONEncoder().encode(AppPreferences(orbVisibility: .always))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "orbVisibility")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        XCTAssertEqual(decoded.orbVisibility, .duringRun)
    }

    func testMissingVoiceOrbPreferencesUseDefaults() throws {
        let encoded = try JSONEncoder().encode(AppPreferences(
            voiceOrbStyle: .glass,
            shuffleVoiceOrbs: true,
            shuffledVoiceOrbStyles: [.radial, .glass]
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "voiceOrbStyle")
        object.removeValue(forKey: "shuffleVoiceOrbs")
        object.removeValue(forKey: "shuffledVoiceOrbStyles")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        XCTAssertEqual(decoded.voiceOrbStyle, .thinking)
        XCTAssertFalse(decoded.shuffleVoiceOrbs)
        XCTAssertEqual(decoded.shuffledVoiceOrbStyles, Set(VoiceOrbStyle.allCases))
    }

    func testEmptyShuffledVoiceOrbStylesFallBackToAllStyles() throws {
        let encoded = try JSONEncoder().encode(AppPreferences())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["shuffledVoiceOrbStyles"] = []
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded.shuffledVoiceOrbStyles, Set(VoiceOrbStyle.allCases))
    }

    func testMissingTypedSpeechPreferenceDefaultsToDisabled() throws {
        var preferences = AppPreferences()
        preferences.speakTypedResponses = true
        let encoded = try JSONEncoder().encode(preferences)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "speakTypedResponses")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        XCTAssertFalse(decoded.speakTypedResponses)
    }

    func testMissingOrbSilencePreferencesUseDefaults() throws {
        var preferences = AppPreferences(
            automaticallySubmitOrbAfterSilence: false,
            orbSilenceDuration: 3
        )
        let encoded = try JSONEncoder().encode(preferences)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automaticallySubmitOrbAfterSilence")
        object.removeValue(forKey: "orbSilenceDuration")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        preferences = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        XCTAssertTrue(preferences.automaticallySubmitOrbAfterSilence)
        XCTAssertEqual(preferences.orbSilenceDuration, 1.5)
    }

    func testLocalPreferencesDisableFallbackWhenBuildingConfig() {
        var preferences = AppPreferences()
        preferences.speechMode = .local
        preferences.allowCloudFallback = true

        XCTAssertFalse(preferences.makeConfig().allowCloudFallback)
    }
}
