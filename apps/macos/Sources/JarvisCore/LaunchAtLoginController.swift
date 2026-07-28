import Foundation
import ServiceManagement

@MainActor
public enum LaunchAtLoginController {
    public static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        guard isSupported else { throw LaunchAtLoginError.requiresApplicationBundle }
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

public enum LaunchAtLoginError: LocalizedError, Equatable {
    case requiresApplicationBundle

    public var errorDescription: String? {
        switch self {
        case .requiresApplicationBundle:
            return "Launch at login is available after J.A.R.V.I.S. is packaged as a macOS application."
        }
    }
}
