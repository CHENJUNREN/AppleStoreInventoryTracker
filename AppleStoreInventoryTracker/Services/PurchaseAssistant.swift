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
    private(set) var openingLogin = false
    private(set) var awaitingLoginCompletion = false
    private(set) var loginVerified = false
    private(set) var verifyingLogin = false
    private(set) var environmentMessage: String?
    @ObservationIgnored var onFeedback: ((String, Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pendingResumes: [UUID: [String: Any]] = [:]
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var attempted = Set<UUID>()
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "AppleStoreInventoryTracker") + "/PurchaseAssistant", isDirectory: true)
        refreshLoginState()
        let url = self.directory.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { profile = try JSONDecoder().decode(PickupProfile.self, from: Data(contentsOf: url)) }
            catch { profileError = "无法读取取货资料，请重新填写并保存。" }
        }
    }

    func refreshLoginState() {
        let marker = directory.appendingPathComponent("manual-login.json")
        let selected = directory.appendingPathComponent("browser-profile.json")
        let name = (try? JSONDecoder().decode(String.self, from: Data(contentsOf: selected))) ?? "chrome-profile"
        awaitingLoginCompletion = (try? JSONDecoder().decode(String.self, from: Data(contentsOf: marker))) == name
        let verified = directory.appendingPathComponent("verified-login.json")
        loginVerified = !awaitingLoginCompletion && (try? JSONDecoder().decode(String.self, from: Data(contentsOf: verified))) == name
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
        messages[taskID] = text
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
                    if child.terminationStatus == 0, self?.ready == true { self?.openLogin() }
                    else { self?.feedback("暂时无法准备登录，请检查网络后重试。") }
                }
            }
            try child.run()
        } catch { preparing = false; feedback("无法准备辅助购买。") }
    }

    func shutdown() { retryTask?.cancel(); retryTask = nil; process?.terminate(); process = nil }

    func openLogin() {
        guard !openingLogin, !preparing else { return }
        guard activeTask == nil else { feedback("请先处理当前购买流程。"); return }
        guard ready else { prepare(); return }
        launch(payload: ["mode": "login"], taskID: nil)
    }

    func finishLogin() {
        guard !openingLogin, activeTask == nil else { return }
        launch(payload: ["mode": "finish-login"], taskID: nil)
    }

    func consider(task: ScanTask, result: CachedScanResult) {
        guard let settings = task.purchase, settings.enabled, activeTask == nil, !openingLogin, !awaitingLoginCompletion,
              !attempted.contains(task.id), let inventory = result.inventories.first(where: { $0.id == task.normalizedProduct }),
              !settings.availableStores(in: inventory).isEmpty else { return }
        guard profile.validationError == nil else { failure("请先在「设置 → 辅助购买」填写取货资料。", taskID: task.id); return }
        attempted.insert(task.id)
        activeTask = task.id
        retryCount = 0
        messages[task.id] = "正在打开购买页面…"
        launch(payload: ["mode": "purchase", "product": task.normalizedProduct, "expectedName": inventory.stores.first?.productName ?? "",
                         "region": ["province": task.region?.province ?? "", "city": task.region?.city ?? "", "district": task.region?.district ?? ""], "appleCare": settings.appleCare,
                         "stores": settings.stores.map(\.id)], taskID: task.id)
    }

    func canResume(_ id: UUID) -> Bool { pendingResumes[id] != nil && activeTask == nil && !openingLogin }

    func resume(_ id: UUID) {
        guard canResume(id), let payload = pendingResumes.removeValue(forKey: id) else { return }
        activeTask = id
        messages[id] = "正在继续辅助购买…"
        launch(payload: payload, taskID: id)
    }

    /// Explicit user action re-arms a paused flow; successful review is never retried by polling.
    func reset(_ id: UUID) {
        guard activeTask == nil || activeTask == id else { return }
        if activeTask == id {
            retryTask?.cancel(); retryTask = nil
            process?.terminate()
            process = nil
            activeTask = nil
        }
        pendingResumes.removeValue(forKey: id)
        attempted.remove(id)
        messages.removeValue(forKey: id)
    }

    func disable(_ id: UUID) {
        pendingResumes.removeValue(forKey: id)
        // Keep the browser lock when a checkout is open, until the user explicitly releases it.
        if activeTask == id { retryTask?.cancel(); retryTask = nil; process?.terminate(); process = nil; messages[id] = "已暂停，请在浏览器处理当前购物袋。" }
        else { attempted.remove(id); messages.removeValue(forKey: id) }
    }

    private func launch(payload: [String: Any], taskID: UUID?) {
        guard ready, let node, let script = Bundle.main.url(forResource: "PurchaseAssistant", withExtension: nil)?.appendingPathComponent("checkout.cjs") else {
            if let taskID { failure("请先在「设置 → 辅助购买」完成浏览器设置。", taskID: taskID); activeTask = nil }
            else { feedback("请先准备辅助购买。") }
            return
        }
        do {
            var request = payload
            request["directory"] = directory.path
            let diagnosticID = UUID().uuidString
            request["diagnosticID"] = diagnosticID
            let diagnosticURL = directory.appendingPathComponent("Diagnostics/\(diagnosticID).json")
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
                        self.refreshLoginState()
                        if child.terminationStatus == 0 {
                            self.messages[taskID] = Self.message(for: 0)
                        } else if let delay = Self.retryDelay(for: child.terminationStatus, attempt: self.retryCount) {
                            self.retryCount = min(self.retryCount + 1, 4)
                            let reason = child.terminationStatus == 12 ? "暂无可用取货时段" : "连接暂时中断"
                            self.messages[taskID] = "\(reason)，\(delay) 秒后自动重试。"
                            self.retryTask = Task { @MainActor [weak self] in
                                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                                guard let self, !Task.isCancelled, self.activeTask == taskID else { return }
                                self.retryTask = nil
                                self.messages[taskID] = "正在重试辅助购买…"
                                self.launch(payload: payload, taskID: taskID)
                            }
                        } else {
                            self.failure(Self.failureMessage(for: child.terminationStatus, diagnosticURL: diagnosticURL), taskID: taskID)
                            // Allow login recovery, while keeping this task disarmed until explicitly restarted.
                            if [10, 25, 26].contains(child.terminationStatus) {
                                if child.terminationStatus == 10 {
                                    var resumePayload = payload
                                    resumePayload["mode"] = "resume-purchase"
                                    self.pendingResumes[taskID] = resumePayload
                                }
                                self.activeTask = nil
                            }
                        }
                    } else {
                        self.openingLogin = false
                        self.verifyingLogin = false
                        self.refreshLoginState()
                        let success = payload["mode"] as? String == "finish-login" ? "登录成功" : "请在 Chrome 中登录，然后返回点击「我已登录」。"
                        self.feedback(child.terminationStatus == 0 ? success : Self.message(for: child.terminationStatus), error: child.terminationStatus != 0)
                    }
                }
            }
            if taskID == nil { openingLogin = true; verifyingLogin = payload["mode"] as? String == "finish-login" }
            try child.run()
            if taskID != nil { process = child }
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
        } catch {
            if let taskID { failure("无法启动辅助购买，请重试。", taskID: taskID); activeTask = nil }
            else { openingLogin = false; verifyingLogin = false; refreshLoginState(); feedback("无法打开登录窗口，请重试。") }
        }
    }

    static func retryDelay(for code: Int32, attempt: Int) -> Int? {
        if code == 12 { return 60 }
        guard code == 21 else { return nil }
        return min(60, 10 * (1 << min(max(attempt, 0), 3)))
    }

    private struct Diagnostic: Decodable {
        let stage: String
        let category: String
    }

    private static func failureMessage(for code: Int32, diagnosticURL: URL) -> String {
        let message = Self.message(for: code)
        guard let data = try? Data(contentsOf: diagnosticURL),
              let diagnostic = try? JSONDecoder().decode(Diagnostic.self, from: data) else { return message }
        let reason = diagnostic.category == "timeout" ? "等待超时" : "已暂停"
        return "\(diagnostic.stage)：\(reason)。\(message)"
    }

    private static func message(for code: Int32) -> String {
        switch code {
        case 0: "已到检查订单页，请在 Chrome 中确认并付款。"
        case 10: "请在 Chrome 中完成结账登录，然后点击“继续辅助购买”。"
        case 11: "购物袋校验未通过，请检查 Chrome 页面。"
        case 21: "连接暂时中断，将自动重试。"
        case 27: "浏览器已有待确认订单，请先在 Chrome 中处理。"
        case 28: "官网产品名称与任务不一致，请检查所选规格。"
        case 29: "官网未保持“不折抵换购”选项，请检查购买页面。"
        case 31: "Apple 拒绝了此次请求（541），已停止自动重试。请稍后在 Chrome 中手动确认。"
        case 32: "Apple 跳转到了错误页面，已停止自动重试。请检查 Chrome 页面。"
        case 12: "所选门店暂无可用取货时段，请稍后重试。"
        case 13: "AppleCare+ 选项不可用，请检查购买设置。"
        case 24: "暂时无法打开登录窗口，请退出此应用的 Chrome 后重试。"
        case 25: "请先登录，然后在设置中点击「我已登录」。"
        case 26: "登录尚未完成，请选择「重新登录」再试一次。"
        default: "辅助购买已暂停，请检查 Chrome 页面后重试。"
        }
    }
}
