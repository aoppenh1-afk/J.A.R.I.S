import Foundation
import JarvisCore
import XCTest
@testable import JarvisApp

private final class UnexpectedModelRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Invalid model-discovery drafts must not send requests")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

@MainActor
final class SettingsModelTests: XCTestCase {
    func testInvalidDraftEndpointIsRejectedBeforeModelDiscovery() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedModelRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for endpoint in ["https://outside.invalid", "ftp://127.0.0.1", "", "http://secret@localhost:8643"] {
            let settings = SettingsModel(
                preferences: AppPreferences(hermesBaseURL: endpoint), deepgramAPIKey: "",
                modelSession: session, onApply: { _ in XCTFail("Discovery does not apply settings") }
            )
            await settings.loadModels(refresh: true)
            XCTAssertFalse(settings.isLoadingModels)
            XCTAssertNil(settings.catalog)
            XCTAssertFalse(settings.modelError.isEmpty)
        }
    }
}
