import Foundation
import Observation

/// Owns the single browser checkout. Profiles never enter task snapshots or process arguments.
@MainActor @Observable
final class PurchaseAssistant {
    private(set) var profile = PickupProfile()
    private(set) var profileError: String?
    private(set) var messages: [UUID: String] = [:]
    private(set) var activeTask: UUID?
    private(set) var preparing = false
    private(set) var environmentMessage: String?
    @ObservationIgnored var onFeedback: ((String, Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var attempted = Set<UUID>()
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "AppleStoreInventoryTracker") + "/PurchaseAssistant", isDirectory: true)
        let url = self.directory.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { profile = try JSONDecoder().decode(PickupProfile.self, from: Data(contentsOf: url)) }
            catch { profileError = "无法读取取货资料，请重新填写并保存。" }
        }
    }

    var ready: Bool {
        node != nil && FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") &&
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules/playwright-core/package.json").path)
    }
    private var node: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/opt/homebrew/opt/node@24/bin/node"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    @discardableResult func saveProfile(_ value: PickupProfile) -> Bool {
        guard value.isEmpty || value.validationError == nil else { profileError = value.validationError; return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("profile.json")
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            profile = value
            profileError = nil
            return true
        } catch { profileError = "取货资料保存失败，请检查本机存储权限。"; return false }
    }

    private func feedback(_ text: String, error: Bool = true) {
        environmentMessage = text
        onFeedback?(text, error)
    }

    private func failure(_ text: String, taskID: UUID) {
        attempted.insert(taskID)
        messages[taskID] = "购买辅助已暂停"
        onFeedback?(text, true)
    }

    func prepare() {
        guard !preparing, let node else { feedback("请先安装 Node.js 和 Google Chrome。"); return }
        guard FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") else { feedback("请先安装 Google Chrome。"); return }
        let npm = URL(fileURLWithPath: node).deletingLastPathComponent().appendingPathComponent("npm").path
        guard FileManager.default.isExecutableFile(atPath: npm) else { feedback("请安装包含 npm 的 Node.js。"); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let child = Process()
            child.executableURL = URL(fileURLWithPath: npm)
            child.arguments = ["install", "--prefix", directory.path, "--ignore-scripts", "--no-audit", "--no-fund", "playwright-core@1.64.1"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin"
            child.environment = env
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            preparing = true
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in
                    self?.preparing = false
                    self?.feedback(child.terminationStatus == 0 ? "购买辅助已就绪。" : "准备失败，请检查网络后重试。", error: child.terminationStatus != 0)
                }
            }
            try child.run()
        } catch { preparing = false; feedback("无法准备购买辅助。") }
    }

    func shutdown() { process?.terminate(); process = nil }

    func openLogin() {
        guard activeTask == nil else { feedback("请先处理当前购买流程。"); return }
        launch(payload: ["mode": "login"], taskID: nil)
    }

    func consider(task: ScanTask, result: CachedScanResult) {
        guard let settings = task.purchase, settings.enabled, activeTask == nil,
              !attempted.contains(task.id), let inventory = result.inventories.first(where: { $0.id == task.normalizedProduct }),
              !settings.availableStores(in: inventory).isEmpty else { return }
        guard profile.validationError == nil else { failure("请先在配置页填写取货资料。", taskID: task.id); return }
        attempted.insert(task.id)
        activeTask = task.id
        messages[task.id] = "正在打开购买页面…"
        launch(payload: ["mode": "purchase", "product": task.normalizedProduct, "expectedName": inventory.stores.first?.productName ?? "",
                         "region": ["province": task.region?.province ?? "", "city": task.region?.city ?? "", "district": task.region?.district ?? ""], "appleCare": settings.appleCare,
                         "stores": settings.stores.map(\.id)], taskID: task.id)
    }

    /// Explicit user action re-arms a paused flow; successful review is never retried by polling.
    func reset(_ id: UUID) {
        guard activeTask == nil || activeTask == id else { return }
        if activeTask == id {
            process?.terminate()
            process = nil
            activeTask = nil
        }
        attempted.remove(id)
        messages.removeValue(forKey: id)
    }

    func disable(_ id: UUID) {
        // Keep the browser lock when a checkout is open, until the user explicitly releases it.
        if activeTask == id { process?.terminate(); process = nil; messages[id] = "已暂停，请在浏览器处理当前购物袋。" }
        else { attempted.remove(id); messages.removeValue(forKey: id) }
    }

    private func launch(payload: [String: Any], taskID: UUID?) {
        guard ready, let node, let script = Bundle.main.url(forResource: "PurchaseAssistant", withExtension: nil)?.appendingPathComponent("checkout.cjs") else {
            if let taskID { failure("请先在配置页准备购买辅助。", taskID: taskID); activeTask = nil }
            else { feedback("请先准备购买辅助。") }
            return
        }
        do {
            var request = payload
            request["directory"] = directory.path
            let child = Process(), input = Pipe()
            child.executableURL = URL(fileURLWithPath: node)
            child.arguments = [script.path]
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] child in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let taskID {
                        guard self.activeTask == taskID, self.process === child else { return }
                        self.process = nil
                        if child.terminationStatus == 0 {
                            self.messages[taskID] = Self.message(for: 0)
                        } else { self.failure(Self.message(for: child.terminationStatus), taskID: taskID) }
                    } else { self.feedback(child.terminationStatus == 0 ? "请在 Chrome 中完成登录；结账时会再次检查。" : Self.message(for: child.terminationStatus), error: child.terminationStatus != 0) }
                }
            }
            try child.run()
            if taskID != nil { process = child }
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
        } catch {
            if let taskID { failure("无法启动购买辅助，请重试。", taskID: taskID); activeTask = nil }
            else { feedback("无法打开登录窗口。") }
        }
    }

    private static func message(for code: Int32) -> String {
        switch code {
        case 0: "已到检查订单页，请在 Chrome 中确认并付款。"
        case 10: "请在 Chrome 中登录，完成后重新启用辅助。"
        case 11: "购物袋已有商品，请在 Chrome 中处理后重试。"
        case 12: "所选门店暂无可用取货时段，请稍后重试。"
        case 13: "AppleCare+ 选项不可用，请检查购买设置。"
        default: "购买辅助已暂停，请检查 Chrome 页面后重试。"
        }
    }
}
