import Foundation
import XCTest
@testable import JarvisCore

final class FirstRunSetupTests: XCTestCase {
    func testSavingPreferencesDoesNotCompleteSetup() throws {
        let name = "jarvis-setup-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(FirstRunSetupStore.isComplete(defaults: defaults))
        XCTAssertTrue(AppPreferencesStore.save(AppPreferences(), defaults: defaults))
        XCTAssertFalse(FirstRunSetupStore.isComplete(defaults: defaults))
        FirstRunSetupStore.markComplete(defaults: defaults)
        XCTAssertTrue(FirstRunSetupStore.isComplete(defaults: defaults))
    }

    func testManagedSetupRequiresHermesAndProfile() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let readiness = SetupReadiness.inspect(
            preferences: AppPreferences(speechMode: .cloud), hasCloudCredential: true,
            executableURL: nil, homeDirectory: home
        )
        XCTAssertFalse(readiness.canStart)
        XCTAssertEqual(readiness.checks.filter { !$0.isReady }.map(\.id), [.hermesExecutable, .hermesProfile])
    }

    func testExistingFolderWithIncompleteModelBlocksLocalSetup() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let readiness = SetupReadiness.inspect(
            preferences: AppPreferences(parakeetModelPath: home.path, hermesBaseURL: "http://127.0.0.1:9999"),
            hasCloudCredential: false, executableURL: nil, homeDirectory: home
        )
        XCTAssertFalse(readiness.canStart)
        XCTAssertEqual(readiness.checks.filter { !$0.isReady }.map(\.id), [.localModel])
    }

    func testCompleteLocalPrerequisitesPermitRuntimePreparation() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = home.appending(path: "model")
        for path in ParakeetModelCacheValidator.requiredRelativePaths {
            try writeFixture(at: model.appending(path: path))
        }
        try writeFixture(at: home.appending(path: ".hermes/profiles/jarvis/config.yaml"))
        let readiness = SetupReadiness.inspect(
            preferences: AppPreferences(parakeetModelPath: model.path), hasCloudCredential: false,
            executableURL: home.appending(path: ".local/bin/hermes"), homeDirectory: home
        )
        XCTAssertTrue(readiness.canStart)
        XCTAssertEqual(readiness.checks.map(\.id), [.endpoint, .hermesExecutable, .hermesProfile, .localModel])
    }

    func testCustomCloudEndpointNeedsNeitherManagedCLIProfileNorLocalModel() {
        let readiness = SetupReadiness.inspect(
            preferences: AppPreferences(speechMode: .cloud, hermesBaseURL: "http://localhost:9999"),
            hasCloudCredential: true, executableURL: nil
        )
        XCTAssertTrue(readiness.canStart)
        XCTAssertEqual(readiness.checks.map(\.id), [.endpoint, .cloudCredential])
    }

    func testAutoRequiresConsentAndCredentialToBypassMissingLocalModel() {
        var preferences = AppPreferences(speechMode: .auto, parakeetModelPath: "/missing-model", hermesBaseURL: "http://localhost:9999")
        func inspect(hasKey: Bool) -> SetupReadiness {
            SetupReadiness.inspect(preferences: preferences, hasCloudCredential: hasKey, executableURL: nil)
        }
        XCTAssertFalse(inspect(hasKey: true).canStart)
        preferences.allowCloudFallback = true
        XCTAssertFalse(inspect(hasKey: false).canStart)
        XCTAssertTrue(inspect(hasKey: true).canStart)
    }

    func testRemoteEndpointBlocksSetupEvenWithCloudCredential() {
        let readiness = SetupReadiness.inspect(
            preferences: AppPreferences(speechMode: .cloud, hermesBaseURL: "https://outside.invalid"),
            hasCloudCredential: true, executableURL: nil
        )
        XCTAssertFalse(readiness.canStart)
        XCTAssertEqual(readiness.checks.filter { !$0.isReady }.map(\.id), [.endpoint])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "jarvis-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFixture(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }
}
