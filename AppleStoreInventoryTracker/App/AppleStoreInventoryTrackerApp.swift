import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable {
    static let storageKey = "appAppearance"
    case system, light, dark

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct AppleStoreInventoryTrackerApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate
    @State private var store = TaskStore()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some Scene {
        Window("Apple 库存监控", id: "main") {
            ContentView(store: store)
                .onChange(of: appearance, initial: true) { _, value in
                    NSApp.appearance = value.appearance
                }
                .background(WindowRegistration { window in
                    delegate.mainWindow = window
                    delegate.store = store
                })
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Apple 库存监控") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?
    var store: TaskStore?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            item.button?.image = image
        } else { item.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "库存监控") }
        item.button?.toolTip = "显示或隐藏 Apple 库存监控"
        item.button?.target = self
        item.button?.action = #selector(toggleWindow)
        statusItem = item
    }

    @objc private func toggleWindow() {
        guard let mainWindow else { return }
        if mainWindow.isVisible && !mainWindow.isMiniaturized { mainWindow.orderOut(nil) }
        else { showWindow() }
    }

    private func showWindow() {
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let store, store.runningCount > 0, !QuitConfirmation.confirm(isTracking: true) { return .terminateCancel }
        store?.stopAll()
        return .terminateNow
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.register = register
        return view
    }
    func updateNSView(_ nsView: RegistrationView, context: Context) { nsView.register = register }

    final class RegistrationView: NSView {
        var register: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.isReleasedWhenClosed = false
                register?(window)
            }
        }
    }
}
