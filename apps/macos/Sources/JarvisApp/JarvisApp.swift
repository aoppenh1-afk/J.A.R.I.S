import AppKit
import JarvisCore
import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var model: AppModel
    @State private var appearance: AppAppearance
    private let orbWindowController: FloatingOrbWindowController

    private static var resources: Bundle {
#if SWIFT_PACKAGE
        .module
#else
        .main
#endif
    }

    private static let menuBarIcon: NSImage = {
        let url = resources.url(forResource: "MenuBarIconTemplate", withExtension: "tiff")
            ?? resources.url(forResource: "MenuBarIconTemplate", withExtension: "png")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "J.A.R.V.I.S.")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    init() {
        let preferences = AppPreferencesStore.load()
        let model = AppModel(config: preferences.makeConfig())
        let orbWindowController = FloatingOrbWindowController(model: model)
        _model = StateObject(wrappedValue: model)
        _appearance = State(initialValue: preferences.appearance)
        self.orbWindowController = orbWindowController
        DispatchQueue.main.async {
            orbWindowController.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AssistantPopover(model: model)
                .jarvisMenuBarPanelStyle(appearance: appearance)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView { preferences in
                appearance = preferences.appearance
                try await model.apply(preferences: preferences)
            }
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}
