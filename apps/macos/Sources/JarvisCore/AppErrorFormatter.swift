import Foundation

public enum AppErrorFormatter {
    public static func displayMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return formatURLError(code: urlError.errorCode, userInfo: urlError.userInfo)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return formatURLError(code: nsError.code, userInfo: nsError.userInfo)
        }

        if let hermesServer = error as? HermesServerError {
            return hermesServer.description
        }

        if let hermesClient = error as? HermesClientError {
            return formatHermesClientError(hermesClient)
        }

        if let configError = error as? AppConfigError {
            switch configError {
            case .cloudFallbackRequiresDeepgramKey:
                return "Cloud fallback requires a Deepgram API key."
            case .cloudModeRequiresDeepgramKey:
                return "Cloud speech mode requires a Deepgram API key."
            case .localModeCannotFallback:
                return "Local speech mode does not support cloud fallback."
            case .hermesMustUseLoopback:
                return "Hermes endpoint must use a local loopback address (127.0.0.1 or localhost)."
            }
        }

        if let audioError = error as? AudioCaptureError {
            return audioError.errorDescription ?? audioError.localizedDescription
        }

        if let deepgramError = error as? DeepgramSpeechError {
            return deepgramError.description
        }

        if let parakeetError = error as? ParakeetRecognizerError {
            switch parakeetError {
            case .notPrepared:
                return "Parakeet speech model is not ready."
            }
        }

        if let hotkeyError = error as? GlobalHotkeyError {
            switch hotkeyError {
            case .registrationFailed(let code):
                return "Failed to register global hotkey (code \(code)). It may be in use by another app."
            }
        }

        if let localized = error as? LocalizedError, let desc = localized.errorDescription, !desc.isEmpty {
            return desc
        }

        let desc = error.localizedDescription
        if desc.contains("The operation couldn’t be completed") || desc.contains("Error Domain=") {
            let typeName = String(describing: type(of: error))
            return "An unexpected error occurred (\(typeName))."
        }
        return desc
    }

    private static func formatHermesClientError(_ error: HermesClientError) -> String {
        switch error {
        case .invalidResponse:
            return "Hermes returned an invalid or unreadable response."
        case .http(let status, let message):
            if status == 401 || status == 403 {
                return "Hermes authentication failed. Please check your Hermes API key."
            } else if status == 404 {
                return "Hermes endpoint not found (HTTP 404)."
            } else {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Hermes HTTP error (\(status))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        case .streamClosedWithoutTerminalEvent:
            return "Hermes connection closed unexpectedly before completing the turn."
        }
    }

    private static func formatURLError(code: Int, userInfo: [String: Any]) -> String {
        let failingURL = (userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? (userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        let endpointHint: String
        if let failingURL, let url = URL(string: failingURL), let host = url.host {
            let portStr = url.port.map { ":\($0)" } ?? ""
            endpointHint = " at \(host)\(portStr)"
        } else {
            endpointHint = ""
        }

        switch code {
        case NSURLErrorCannotConnectToHost, -1004: // -1004 = cannot connect to server (connection refused)
            return "Could not connect to Hermes\(endpointHint). Ensure Hermes is running."
        case NSURLErrorTimedOut, -1001:
            return "Connection to Hermes\(endpointHint) timed out."
        case NSURLErrorCannotFindHost, -1003:
            return "Could not resolve Hermes host\(endpointHint)."
        case NSURLErrorNetworkConnectionLost, -1005:
            return "Hermes connection was interrupted."
        case NSURLErrorNotConnectedToInternet, -1009:
            return "Network connection appears to be offline."
        default:
            return "Network connection error (\(code)) reaching Hermes\(endpointHint)."
        }
    }
}
