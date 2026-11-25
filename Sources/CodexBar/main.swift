import AppKit
import CodexQuotaKit
import Foundation

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let scanner = SessionLogScanner()
    private let claudeSource = ClaudeQuotaSource()
    private let agySource = AgyQuotaSource()
    private let worker = DispatchQueue(label: "com.codexbar.quota-reader", qos: .utility)
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private var agyTimer: Timer?
    private var latestQuota: CodexQuota?
    private var latestError: Error?
    private var claudeResult: Result<ClaudeQuota, Error>?
    private var agyResult: Result<AgyQuota, Error>?
    private var isRefreshingCodex = false
    private var isRefreshingClaude = false
    private var isRefreshingAgy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Codex、Claude 和 agy 额度"
            )
            button.imagePosition = .imageLeading
            button.toolTip = "Codex、Claude 和 agy 剩余额度（%）"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateDisplay()
        refresh()

        let codexTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refreshCodex),
            userInfo: nil,
            repeats: true
        )
        let claudeTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(refreshClaude),
            userInfo: nil,
            repeats: true
        )
        let agyTimer = Timer.scheduledTimer(
            timeInterval: 5 * 60,
            target: self,
            selector: #selector(refreshAgy),
            userInfo: nil,
            repeats: true
        )
        self.codexTimer = codexTimer
        self.claudeTimer = claudeTimer
        self.agyTimer = agyTimer
        RunLoop.main.add(codexTimer, forMode: .common)
        RunLoop.main.add(claudeTimer, forMode: .common)
        RunLoop.main.add(agyTimer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexTimer?.invalidate()
        claudeTimer?.invalidate()
        agyTimer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshCodex()
    }

    @objc private func refresh() {
        refreshCodex()
        refreshClaude()
        refreshAgy()
    }

    @objc private func refreshCodex() {
        guard !isRefreshingCodex else { return }
        isRefreshingCodex = true
        worker.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.scanner.latestQuota() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshingCodex = false
                switch result {
                case .success(let quota):
                    self.latestQuota = quota
                    self.latestError = nil
                case .failure(let error):
                    self.latestError = error
                }
                self.updateDisplay()
            }
        }
    }

    @objc private func refreshClaude() {
        guard !isRefreshingClaude else { return }
        isRefreshingClaude = true
        Task { @MainActor in
            do {
                claudeResult = .success(try await claudeSource.latestQuota())
            } catch {
                claudeResult = .failure(error)
            }
            isRefreshingClaude = false
            updateDisplay()
        }
    }

    @objc private func refreshAgy() {
        guard !isRefreshingAgy else { return }
        isRefreshingAgy = true
        Task { @MainActor in
            do {
                agyResult = .success(try await agySource.latestQuota())
            } catch {
                agyResult = .failure(error)
            }
            isRefreshingAgy = false
            updateDisplay()
        }
    }

    private func updateDisplay() {
        let codex = latestQuota?.primary ?? latestQuota?.secondary
        let claude = try? claudeResult?.get()
        let claudeWindow = claude?.fiveHour ?? claude?.sevenDay
        let agy = try? agyResult?.get()
        let codexPercent = Self.titlePercentage(codex?.remainingPercent)
        let claudePercent = Self.titlePercentage(claudeWindow?.remainingPercent)
        let agyPercent = Self.titlePercentage(agy?.minimumRemainingPercent)
        statusItem.button?.title = "Cx \(codexPercent) · Cl \(claudePercent) · Ag \(agyPercent)"
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        addHeading("Codex", to: menu)
        addCodexDetails(to: menu)
        menu.addItem(.separator())
        addHeading("Claude", to: menu)
        addClaudeDetails(to: menu)
        menu.addItem(.separator())
        addHeading("agy", to: menu)
        addAgyDetails(to: menu)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let logsItem = NSMenuItem(
            title: "在 Finder 中查看日志",
            action: #selector(openLogs),
            keyEquivalent: ""
        )
        logsItem.target = self
        menu.addItem(logsItem)

        let aboutItem = NSMenuItem(
            title: "数据说明",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 CodexBar",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addCodexDetails(to menu: NSMenu) {
        if let quota = latestQuota {
            addPlan(quota.planType?.uppercased(), to: menu)
            if let primary = quota.primary {
                addWindow(primary, fallbackName: "主要额度", to: menu)
            }
            if let secondary = quota.secondary {
                addWindow(secondary, fallbackName: "次要额度", to: menu)
            }
            if let credits = quota.credits {
                let creditText: String
                if credits.unlimited {
                    creditText = "额外点数：不限量"
                } else if credits.hasCredits {
                    creditText = "额外点数：\(credits.balance ?? "可用")"
                } else {
                    creditText = "额外点数：无"
                }
                addDisabledItem(creditText, to: menu)
            }
            if quota.spendControlReached == true {
                addDisabledItem("⚠︎ 已达到支出上限", to: menu)
            }
            if let reached = quota.rateLimitReachedType {
                addDisabledItem("⚠︎ 已触发额度限制：\(reached)", to: menu)
            }
            addUpdate(quota.observedAt, to: menu)
        }
        if let latestError {
            addDisabledItem(latestError.localizedDescription, to: menu)
        } else if latestQuota == nil {
            addDisabledItem("正在读取 Codex 数据…", to: menu)
        }
    }

    private func addClaudeDetails(to menu: NSMenu) {
        switch claudeResult {
        case .success(let quota):
            addPlan(quota.planType?.uppercased(), to: menu)
            if let window = quota.fiveHour {
                addWindow(window, fallbackName: "5 小时额度", to: menu)
            }
            if let window = quota.sevenDay {
                addWindow(window, fallbackName: "每周额度", to: menu)
            }
            if quota.fiveHour == nil && quota.sevenDay == nil {
                addDisabledItem("暂无额度数据", to: menu)
            }
            addUpdate(quota.observedAt, to: menu)
        case .failure(let error):
            addDisabledItem(error.localizedDescription, to: menu)
        case nil:
            addDisabledItem("正在读取 Claude 数据…", to: menu)
        }
    }

    private func addAgyDetails(to menu: NSMenu) {
        switch agyResult {
        case .success(let quota):
            for group in quota.groups {
                addHeading(group.displayName, fontSize: NSFont.smallSystemFontSize, to: menu)
                for bucket in group.buckets {
                    addWindow(bucket.quotaWindow, fallbackName: bucket.window, to: menu)
                }
            }
            if quota.minimumRemainingPercent == nil {
                addDisabledItem("暂无额度数据", to: menu)
            }
            addUpdate(quota.observedAt, to: menu)
        case .failure(let error):
            addDisabledItem(error.localizedDescription, to: menu)
        case nil:
            addDisabledItem("正在读取 agy 数据…", to: menu)
        }
    }

    private func addPlan(_ plan: String?, to menu: NSMenu) {
        let name = plan.flatMap { $0.isEmpty ? nil : $0 } ?? "未知"
        addDisabledItem("套餐：\(name)", to: menu)
    }

    private func addUpdate(_ date: Date, to menu: NSMenu) {
        addDisabledItem("更新：\(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))", to: menu)
    }

    private func addHeading(_ title: String, fontSize: CGFloat = NSFont.systemFontSize, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: fontSize)]
        )
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addWindow(_ window: QuotaWindow, fallbackName: String, to menu: NSMenu) {
        let label = Self.windowLabel(minutes: window.windowMinutes) ?? fallbackName
        let used = Self.percentage(window.usedPercent)
        let remaining = Self.percentage(window.remainingPercent)
        addDisabledItem("\(label)：已用 \(used)% · 剩余 \(remaining)%", to: menu)
        if let reset = window.resetsAt {
            addDisabledItem("    重置：\(Self.absoluteDateFormatter.string(from: reset))", to: menu)
        }
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(scanner.sessionsDirectory)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "CodexBar 的数据从哪里来？"
        alert.informativeText = """
        Codex 的额度每 5 秒从本机任务日志的 rate_limits 字段读取。

        Claude 的额度每 60 秒查询一次。CodexBar 从钥匙串读取 Claude Code 的登录令牌，仅发送给 Claude 的额度接口。令牌不落盘、不写日志。

        agy 的额度每 5 分钟通过本机 agy 命令的 /usage 获取。CodexBar 不读取 agy 的登录凭据。点击“立即刷新”可手动查询。

        菜单栏显示剩余百分比。Codex 取主要额度，Claude 优先取 5 小时额度，agy 取所有窗口中剩余比例最低的一项。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func titlePercentage(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(Int(value.rounded()))
    }

    private static func percentage(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private static func windowLabel(minutes: Int?) -> String? {
        guard let minutes else { return nil }
        switch minutes {
        case 60: return "每小时额度"
        case 300: return "5 小时额度"
        case 1_440: return "每日额度"
        case 10_080: return "每周额度"
        default:
            if minutes.isMultiple(of: 1_440) {
                return "\(minutes / 1_440) 天额度"
            }
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60) 小时额度"
            }
            return "\(minutes) 分钟额度"
        }
    }

    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
withExtendedLifetime(delegate) {}
