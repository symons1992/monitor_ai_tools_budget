import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct CreditStatus: Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexQuota: Equatable, Sendable {
    public let limitID: String?
    public let limitName: String?
    public let planType: String?
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public let credits: CreditStatus?
    public let spendControlReached: Bool?
    public let rateLimitReachedType: String?
    public let observedAt: Date
    public let sourceFile: URL

    public init(
        limitID: String?,
        limitName: String?,
        planType: String?,
        primary: QuotaWindow?,
        secondary: QuotaWindow?,
        credits: CreditStatus?,
        spendControlReached: Bool?,
        rateLimitReachedType: String?,
        observedAt: Date,
        sourceFile: URL
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.spendControlReached = spendControlReached
        self.rateLimitReachedType = rateLimitReachedType
        self.observedAt = observedAt
        self.sourceFile = sourceFile
    }
}

public enum QuotaReadError: LocalizedError, Equatable {
    case sessionsDirectoryMissing(URL)
    case noSessionLogs(URL)
    case noQuotaRecord(URL)

    public var errorDescription: String? {
        switch self {
        case .sessionsDirectoryMissing(let url):
            return "找不到 Codex 日志目录：\(url.path)"
        case .noSessionLogs(let url):
            return "Codex 日志目录中还没有任务记录：\(url.path)"
        case .noQuotaRecord:
            return "尚未捕获额度数据，请先在 Codex 中运行一次任务"
        }
    }
}
