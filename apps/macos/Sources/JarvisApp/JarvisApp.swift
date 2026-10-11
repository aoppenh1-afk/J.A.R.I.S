import AppKit
import Darwin
import JarvisCore
import SwiftUI

enum JarvisResources {
    static let bundle: Bundle = {
#if SWIFT_PACKAGE
        // SwiftPM's generated accessor can search the app root or an absolute
        // build path. Packaged apps keep their bundle in Contents/Resources.
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "JarvisMac_JarvisApp", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                fatalError("The application's embedded Jarvis resource bundle is missing.")
            }
            return bundle
        }
        return .module
#else
        return .main
#endif
    }()

    static func validatePackagedResources() throws {
        let application = Bundle.main.bundleURL.standardizedFileURL.path
        let resources = bundle.bundleURL.standardizedFileURL.path
        guard resources == application || resources.hasPrefix(application + "/") else {
            throw NSError(domain: "JarvisResources", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Resources resolved outside the application: \(resources)",
            ])
        }
        for path in [
            "MenuBarIconTemplate.png", "MenuBarIconTemplate@2x.png",
            "GlassVoiceOrbStudy/embed.html", "GlassVoiceOrbStudy/bridge.js",
            "GlassVoiceOrbStudy/src/renderer.js", "GlassVoiceOrbStudy/src/state.js",
            "GlassVoiceOrbStudy/shader-sources.js",
        ] {
            guard let url = bundle.resourceURL?.appendingPathComponent(path),
                  !(try Data(contentsOf: url)).isEmpty else {
                throw NSError(domain: "JarvisResources", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled resource is missing or empty: \(path)",
                ])
            }
            if url.pathExtension == "png", NSImage(contentsOf: url) == nil {
                throw NSError(domain: "JarvisResources", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled image cannot be decoded: \(path)",
                ])
            }
        }
    }
}

@main
struct JarvisApp: App {
    @StateObject private var model: AppModel
    @StateObject private var updater = AppUpdater()
    @State private var appearance: AppAppearance
    private let orbWindowController: FloatingOrbWindowController
    private let setupWindowController: SetupWindowController

    private static let menuBarIcon: NSImage = {
        let url = JarvisResources.bundle.url(forResource: "MenuBarIconTemplate", withExtension: "tiff")
            ?? JarvisResources.bundle.url(forResource: "MenuBarIconTemplate", withExtension: "png")
        let image = url.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "J.A.R.V.I.S.")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    init() {
        if CommandLine.arguments.contains("--validate-resources") {
            do {
                try JarvisResources.validatePackagedResources()
                print("✓ packaged menu icon and Liquid Glass resources load from the application")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        }
        let preferences = AppPreferencesStore.load()
        let model = AppModel(config: preferences.makeConfig())
        let orbWindowController = FloatingOrbWindowController(model: model)
        let setupWindowController = SetupWindowController(model: model)
        _model = StateObject(wrappedValue: model)
        _appearance = State(initialValue: preferences.appearance)
        self.orbWindowController = orbWindowController
        self.setupWindowController = setupWindowController
        let initialAppearance = preferences.appearance
        DispatchQueue.main.async {
            JarvisTheme.applyAppearance(initialAppearance)
            orbWindowController.start()
            setupWindowController.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AssistantPopover(model: model, updater: updater)
                .jarvisMenuBarPanelStyle(appearance: appearance)
                .onAppear { JarvisTheme.applyAppearance(appearance) }
                .onChange(of: appearance) { _, next in
                    JarvisTheme.applyAppearance(next)
                }
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(updater: updater) { preferences in
                try await model.apply(preferences: preferences)
                appearance = preferences.appearance
                JarvisTheme.applyAppearance(preferences.appearance)
            }
            .preferredColorScheme(appearance.colorScheme)
            .onAppear { JarvisTheme.applyAppearance(appearance) }
            .onChange(of: appearance) { _, next in
                JarvisTheme.applyAppearance(next)
            }
        }
    }
}
