import CryptoKit
import Foundation

public struct AgyQuota: Sendable {
    public struct Group: Decodable, Sendable {
        public let displayName: String
        public let buckets: [Bucket]
    }

    public struct Bucket: Decodable, Sendable {
        public let window: String
        public let remainingFraction: Double
        public let resetTime: Date?

        public var quotaWindow: QuotaWindow {
            let minutes: Int?
            switch window {
            case "5h": minutes = 300
            case "weekly": minutes = 10_080
            default: minutes = nil
            }
            return QuotaWindow(usedPercent: (1 - remainingFraction) * 100, windowMinutes: minutes, resetsAt: resetTime)
        }
    }

    public let planType: String?
    public let groups: [Group]
    public let observedAt: Date

    public var minimumRemainingPercent: Double? {
        groups.flatMap(\.buckets).map(\.remainingFraction).min().map { $0 * 100 }
    }
}

public actor AgyQuotaSource {
    private var cachedProject: (tokenDigest: SHA256.Digest, project: Project)?

    public init() {}

    public func latestQuota() async throws -> AgyQuota {
        let credentials = try QuotaKeychain.read(["-s", "gemini", "-a", "antigravity"], command: "agy")
        let accessToken = try Self.decodeAccessToken(credentials)
        let tokenDigest = SHA256.hash(data: Data(accessToken.utf8))
        let project: Project
        if let cachedProject, cachedProject.tokenDigest == tokenDigest {
            project = cachedProject.project
        } else {
            let body = #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
            let response = try await Self.post("loadCodeAssist", body: Data(body.utf8), accessToken: accessToken)
            project = try RemoteQuotaRequest.decode(Project.self, from: response)
            guard !project.cloudaicompanionProject.isEmpty else { throw RemoteQuotaError.invalidResponse }
            cachedProject = (tokenDigest, project)
        }

        let body = try JSONEncoder().encode(QuotaRequest(project: project.cloudaicompanionProject))
        let planType = project.paidTier?.name ?? project.currentTier?.name
        async let summaryResponse = Self.post("retrieveUserQuotaSummary", body: body, accessToken: accessToken)
        async let modelsResponse = Self.post(
            "fetchAvailableModels", body: body, accessToken: accessToken, userAgent: "antigravity"
        )

        let summary: Result<AgyQuota, Error>
        do {
            summary = .success(try Self.parseUsage(await summaryResponse, planType: planType))
        } catch {
            if case RemoteQuotaError.loginRequired = error { throw error }
            summary = .failure(error)
        }

        let geminiGroup: AgyQuota.Group?
        do {
            geminiGroup = try Self.parseGeminiGroup(await modelsResponse)
        } catch {
            if case RemoteQuotaError.loginRequired = error { throw error }
            return try summary.get()
        }

        let groups = (geminiGroup.map { [$0] } ?? []) + ((try? summary.get().groups) ?? [])
        return AgyQuota(planType: planType, groups: groups, observedAt: Date())
    }

    static func decodeAccessToken(_ data: Data) throws -> String {
        let prefix = "go-keyring-base64:"
        guard let entry = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              entry.hasPrefix(prefix),
              let json = Data(base64Encoded: String(entry.dropFirst(prefix.count))),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: json),
              !credentials.token.accessToken.isEmpty else {
            throw RemoteQuotaError.loginRequired("agy")
        }
        return credentials.token.accessToken
    }

    static func parseUsage(_ data: Data, planType: String?) throws -> AgyQuota {
        let usage = try RemoteQuotaRequest.decode(Usage.self, from: data)
        guard usage.groups.allSatisfy({ group in
            group.buckets.allSatisfy { (0...1).contains($0.remainingFraction) }
        }) else {
            throw RemoteQuotaError.invalidResponse
        }
        return AgyQuota(planType: planType, groups: usage.groups, observedAt: Date())
    }

    static func parseGeminiGroup(_ data: Data) throws -> AgyQuota.Group? {
        let models = try RemoteQuotaRequest.decode(AvailableModels.self, from: data).models
        let quotas = models.values.compactMap(\.quotaInfo).filter { $0.resetTime != nil }
        guard quotas.allSatisfy({ (0...1).contains($0.remainingFraction) }) else {
            throw RemoteQuotaError.invalidResponse
        }
        guard let quota = quotas.min(by: { $0.remainingFraction < $1.remainingFraction }) else {
            return nil
        }
        let bucket = AgyQuota.Bucket(window: "额度", remainingFraction: quota.remainingFraction, resetTime: quota.resetTime)
        return AgyQuota.Group(displayName: "Gemini 模型", buckets: [bucket])
    }

    private static func post(
        _ endpoint: String, body: Data, accessToken: String, userAgent: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = body
        return try await RemoteQuotaRequest.send(request, command: "agy")
    }

    private struct Credentials: Decodable {
        struct Token: Decodable {
            let accessToken: String

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }

        let token: Token
    }

    private struct Project: Decodable {
        struct Tier: Decodable {
            let name: String?
        }

        let cloudaicompanionProject: String
        let paidTier: Tier?
        let currentTier: Tier?
    }

    private struct QuotaRequest: Encodable {
        let project: String
    }

    private struct Usage: Decodable {
        let groups: [AgyQuota.Group]
    }

    private struct AvailableModels: Decodable {
        struct Model: Decodable {
            struct QuotaInfo: Decodable {
                let remainingFraction: Double
                let resetTime: Date?
            }

            let quotaInfo: QuotaInfo?

            enum CodingKeys: String, CodingKey {
                case modelProvider
                case quotaInfo
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if try values.decodeIfPresent(String.self, forKey: .modelProvider) == "MODEL_PROVIDER_GOOGLE" {
                    quotaInfo = try values.decodeIfPresent(QuotaInfo.self, forKey: .quotaInfo)
                } else {
                    quotaInfo = nil
                }
            }
        }

        let models: [String: Model]
    }
}
