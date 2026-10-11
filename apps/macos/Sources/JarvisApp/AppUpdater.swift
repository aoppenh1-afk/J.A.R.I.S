import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var status = "Updates will be available in a release build."
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }
    private var controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        do {
            try controller.updater.start()
            isConfigured = true
            status = "Signed updates are delivered through GitHub Releases."
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .removeDuplicates()
                .sink { [weak self] value in
                    guard self?.automaticallyChecksForUpdates != value else { return }
                    self?.automaticallyChecksForUpdates = value
                }.store(in: &cancellables)
            controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
                .removeDuplicates()
                .sink { [weak self] value in
                    guard self?.automaticallyDownloadsUpdates != value else { return }
                    self?.automaticallyDownloadsUpdates = value
                }.store(in: &cancellables)
        } catch {
            status = "Could not start updates: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
