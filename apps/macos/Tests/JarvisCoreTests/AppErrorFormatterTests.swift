import XCTest
@testable import JarvisCore

final class AppErrorFormatterTests: XCTestCase {
    func testFormatsNSURLErrorConnectionRefusedWithoutInternalDumps() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "http://127.0.0.1:8643/health",
                "_kCFStreamErrorCodeKey": 61
            ]
        )

        let message = AppErrorFormatter.displayMessage(for: error)
        XCTAssertFalse(message.contains("Error Domain="))
        XCTAssertFalse(message.contains("NSURLErrorDomain"))
        XCTAssertFalse(message.contains("_kCFStreamErrorCodeKey"))
        XCTAssertTrue(message.contains("Could not connect to Hermes at 127.0.0.1:8643"))
        XCTAssertTrue(message.contains("Ensure Hermes is running"))
    }

    func testFormatsURLErrorDirectly() {
        let url = URL(string: "http://localhost:8643/v1/capabilities")!
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])

        let message = AppErrorFormatter.displayMessage(for: error)
        XCTAssertFalse(message.contains("Error Domain="))
        XCTAssertTrue(message.contains("Connection to Hermes at localhost:8643 timed out"))
    }

    func testFormatsHermesServerErrors() {
        let error1 = HermesServerError.readinessTimedOut
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: error1), "Hermes did not become ready before the startup deadline.")

        let error2 = HermesServerError.managedEndpointOccupied
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: error2), "The managed J.A.R.V.I.S. Hermes endpoint is already occupied by an unverified process.")

        let error3 = HermesServerError.exitedBeforeReadyWithMessage(1, message: "Address already in use")
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: error3), "Hermes exited before its API became ready (status 1): Address already in use")
    }

    func testFormatsHermesClientErrors() {
        let authError = HermesClientError.http(status: 401, message: "Unauthorized")
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: authError), "Hermes authentication failed. Please check your Hermes API key.")

        let notFoundError = HermesClientError.http(status: 404, message: "Not Found")
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: notFoundError), "Hermes endpoint not found (HTTP 404).")

        let invalidResponse = HermesClientError.invalidResponse
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: invalidResponse), "Hermes returned an invalid or unreadable response.")
    }

    func testFormatsAppConfigErrors() {
        let configError = AppConfigError.hermesMustUseLoopback
        XCTAssertEqual(AppErrorFormatter.displayMessage(for: configError), "Hermes endpoint must use a local loopback address (127.0.0.1 or localhost).")
    }

    func testIsManagedEndpointAcceptsLoopbackVariants() {
        XCTAssertTrue(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://127.0.0.1:8643")!))
        XCTAssertTrue(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://127.0.0.1:8643/")!))
        XCTAssertTrue(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://localhost:8643")!))
        XCTAssertTrue(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://[::1]:8643")!))

        XCTAssertFalse(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://127.0.0.1:8642")!))
        XCTAssertFalse(HermesRuntimeConfiguration.isManagedEndpoint(URL(string: "http://example.com:8643")!))
    }

    func testIsLegacyManagedEndpointDetectsPort8642() {
        XCTAssertTrue(HermesRuntimeConfiguration.isLegacyManagedEndpoint(URL(string: "http://127.0.0.1:8642")!))
        XCTAssertTrue(HermesRuntimeConfiguration.isLegacyManagedEndpoint(URL(string: "http://localhost:8642")!))
        XCTAssertFalse(HermesRuntimeConfiguration.isLegacyManagedEndpoint(URL(string: "http://127.0.0.1:8643")!))
    }
}
