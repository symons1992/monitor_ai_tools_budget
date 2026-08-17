import AppKit
import CodexQuotaKit
import Foundation

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let scanner = SessionLogScanner()
    private let worker = DispatchQueue(label: "com.codexbar.quota-reader", qos: .utility)
    private var timer: Timer?
    private var latestQuota: CodexQuota?
    private var latestError: Error?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Codex 额度"
            )
            button.imagePosition = .imageLeading
            button.title = " --"
            button.toolTip = "Codex 使用额度"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refresh()

        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        worker.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.scanner.latestQuota() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let quota):
                    self.latestQuota = quota
                    self.latestError = nil
                case .failure(let error):
                    self.latestError = error
                }
                self.updateStatusItem()
                self.rebuildMenu()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        guard let window = latestQuota?.primary ?? latestQuota?.secondary else {
            button.title = " --"
            button.toolTip = latestError?.localizedDescription ?? "等待 Codex 额度数据"
            return
        }

        let remaining = Int(window.remainingPercent.rounded())
        button.title = " \(remaining)%"
        button.toolTip = "Codex 剩余额度 \(remaining)%"
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let heading = NSMenuItem(title: "Codex 使用额度", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        if let quota = latestQuota {
            if let plan = quota.planType, !plan.isEmpty {
                addDisabledItem("套餐：\(plan.uppercased())", to: menu)
            }
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
            addDisabledItem("更新：\(Self.relativeDateFormatter.localizedString(for: quota.observedAt, relativeTo: Date()))", to: menu)
        } else {
            addDisabledItem(latestError?.localizedDescription ?? "正在读取 Codex 数据…", to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: isRefreshing ? "正在刷新…" : "立即刷新",
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
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
        alert.informativeText = "CodexBar 每 5 秒只读扫描本机 Codex 任务日志中的 rate_limits 字段。它不会解析、显示或存储对话正文，不会读取登录凭据，也不会向网络发送任何数据。\n\n菜单栏显示的是主要统计窗口的剩余百分比。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
