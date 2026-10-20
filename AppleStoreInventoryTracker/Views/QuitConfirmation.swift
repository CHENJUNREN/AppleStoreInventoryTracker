import AppKit

/// An app-modal alert remains interactive even if the menu-bar window loses focus.
@MainActor
enum QuitConfirmation {
    static func confirm(isTracking: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确定退出应用？"
        alert.informativeText = isTracking ? "退出后将停止库存监测和通知。" : "退出后将关闭菜单栏应用。"
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: "退出")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        NSApplication.shared.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
