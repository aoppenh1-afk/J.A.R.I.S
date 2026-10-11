import XCTest
@testable import JarvisCore

final class AppConfigTests: XCTestCase {
    func testEndpointValidationAcceptsOnlyLoopbackHTTPURLs() throws {
        for endpoint in ["http://127.0.0.1:8643", "https://localhost:9000", "http://[::1]:8643", "http://LOCALHOST:8643"] {
            XCTAssertNoThrow(try HermesRuntimeConfiguration.validateEndpoint(URL(string: endpoint)!))
        }
        for endpoint in ["https://outside.invalid", "http://localhost.outside.invalid", "http://127.0.0.1@outside.invalid",
                         "http://key@localhost:8643", "ftp://127.0.0.1", "file://localhost/tmp/api", "/api/models"] {
            XCTAssertThrowsError(try HermesRuntimeConfiguration.validateEndpoint(URL(string: endpoint)!)) { error in
                XCTAssertEqual(error as? AppConfigError, .hermesMustUseLoopback)
            }
        }
    }

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
