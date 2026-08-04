import XCTest
@testable import JarvisCore

final class AppConfigTests: XCTestCase {
    func testLocalModeRejectsCloudFallback() {
        var config = AppConfig()
        config.allowCloudFallback = true
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AppConfigError, .localModeCannotFallback)
        }
    }

    func testCloudModeRequiresDeepgramKey() {
        let config = AppConfig(speechMode: .cloud, deepgramAPIKey: nil)
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AppConfigError, .cloudModeRequiresDeepgramKey)
        }
    }

    func testAutoFallbackRequiresDeepgramKey() {
        let config = AppConfig(
            speechMode: .auto,
            allowCloudFallback: true,
            deepgramAPIKey: nil
        )
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AppConfigError, .cloudFallbackRequiresDeepgramKey)
        }
    }

    func testHermesDefaultsToDedicatedManagedEndpoint() throws {
        let config = AppConfig()

        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.hermesBaseURL, HermesRuntimeConfiguration.managedBaseURL)
        XCTAssertTrue(HermesRuntimeConfiguration.isManagedEndpoint(config.hermesBaseURL))
        XCTAssertFalse(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://127.0.0.1:9000")!))
    }
}
