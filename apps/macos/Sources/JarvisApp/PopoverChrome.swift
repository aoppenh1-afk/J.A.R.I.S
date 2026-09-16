import AppKit
import JarvisCore
import SwiftUI

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum JarvisTheme {
    /// Single owner for the appearance decision. On macOS 27 MenuBarExtra
    /// panels are WindowServer-composited and per-view SwiftUI state alone no
    /// longer reliably repaints them, so the explicit choice is pushed to the
    /// app, every window, and the SwiftUI environment together.
    @MainActor
    static func applyAppearance(_ appearance: AppAppearance) {
        let appKitAppearance = appearance.nsAppearance
        NSApp.appearance = appKitAppearance
        for window in NSApp.windows {
            window.appearance = appKitAppearance
            propagateAppearance(in: window.contentView, appearance: appKitAppearance)
        }
    }

    @MainActor
    static func applyMenuBarPanelChrome(to window: NSWindow, appearance: AppAppearance) {
        let appKitAppearance = appearance.nsAppearance
        // Keep the app-level override in sync so reopened or cached
        // MenuBarExtra panels inherit the correct appearance on macOS 27.
        NSApp.appearance = appKitAppearance

        window.appearance = appKitAppearance
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = appearance == .dark
        window.backgroundColor = appearance == .dark ? .black : .clear
        window.invalidateShadow()
        propagateAppearance(in: window.contentView, appearance: appKitAppearance)
        DispatchQueue.main.async {
            propagateAppearance(in: window.contentView, appearance: appKitAppearance)
        }
    }

    @MainActor
    private static func propagateAppearance(in view: NSView?, appearance: NSAppearance?) {
        guard let view else { return }
        view.appearance = appearance
        if #available(macOS 26.0, *) {
            // MenuBarExtra panels on macOS 26+ host Liquid Glass views. The
            // container merges nearby glass shapes and samples behind-window
            // content, so both it and the glass views must inherit the
            // explicit appearance or the panel falls back to a light tint.
            if view is NSGlassEffectView {
                view.appearance = appearance
            } else if view.className.contains("GlassEffectContainer") {
                view.appearance = appearance
            }
        }
        for subview in view.subviews {
            propagateAppearance(in: subview, appearance: appearance)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}

private struct JarvisMenuBarPanelStyleModifier: ViewModifier {
    let appearance: AppAppearance

    func body(content: Content) -> some View {
        content
            .background(appearance == .dark ? Color.black : Color.clear)
            .background(WindowAccessor { window in
                JarvisTheme.applyMenuBarPanelChrome(to: window, appearance: appearance)
            })
            .preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func jarvisMenuBarPanelStyle(appearance: AppAppearance) -> some View {
        modifier(JarvisMenuBarPanelStyleModifier(appearance: appearance))
    }
}
