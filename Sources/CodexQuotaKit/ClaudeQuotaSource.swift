import Foundation

public struct ClaudeQuota: Sendable {
    public let planType: String?
    public let fiveHour: QuotaWindow?
    public let sevenDay: QuotaWindow?
    public let observedAt: Date
}

public struct ClaudeQuotaSource: Sendable {
    public init() {}

    public func latestQuota() async throws -> ClaudeQuota {
        let data = try QuotaKeychain.read(["-s", "Claude Code-credentials"], command: "claude")
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth,
              !credentials.accessToken.isEmpty else {
            throw RemoteQuotaError.loginRequired("claude")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let response = try await RemoteQuotaRequest.send(request, command: "claude")
        return try Self.parseUsage(response, planType: credentials.subscriptionType)
    }

    static func parseUsage(_ data: Data, planType: String?) throws -> ClaudeQuota {
        let usage = try RemoteQuotaRequest.decode(Usage.self, from: data)
        return ClaudeQuota(
            planType: planType,
            fiveHour: usage.fiveHour?.quotaWindow(minutes: 300),
            sevenDay: usage.sevenDay?.quotaWindow(minutes: 10_080),
            observedAt: Date()
        )
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let subscriptionType: String?
        }

        let claudeAiOauth: OAuth
    }

    private struct Usage: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resetsAt: Date?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }

            func quotaWindow(minutes: Int) -> QuotaWindow {
                QuotaWindow(usedPercent: utilization, windowMinutes: minutes, resetsAt: resetsAt)
            }
        }

        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }
}
