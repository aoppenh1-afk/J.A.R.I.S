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

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum JarvisTheme {
    @MainActor
    static func applyMenuBarPanelChrome(to window: NSWindow, appearance: AppAppearance) {
        let appKitAppearance: NSAppearance?
        switch appearance {
        case .system:
            appKitAppearance = nil
        case .light:
            appKitAppearance = NSAppearance(named: .aqua)
        case .dark:
            appKitAppearance = NSAppearance(named: .darkAqua)
        }

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
            if let glass = view as? NSGlassEffectView {
                glass.appearance = appearance
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
