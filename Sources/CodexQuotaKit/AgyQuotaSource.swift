import Foundation

public struct AgyQuota: Sendable {
    public struct Group: Decodable, Sendable {
        public let displayName: String
        public let buckets: [Bucket]

        private enum CodingKeys: String, CodingKey {
            case displayName = "name"
            case buckets
        }
    }

    public struct Bucket: Decodable, Sendable {
        public let window: String
        public let remainingFraction: Double
        public let resetTime: Date?

        private enum CodingKeys: String, CodingKey {
            case window, remainingFraction, resetTime
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            window = try values.decode(String.self, forKey: .window)
            remainingFraction = try values.decodeIfPresent(Double.self, forKey: .remainingFraction) ?? 0
            let reset = try values.decodeIfPresent(Date.self, forKey: .resetTime)
            resetTime = reset == Date(timeIntervalSince1970: 0) ? nil : reset
        }

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

    public let groups: [Group]
    public let observedAt: Date

    public var minimumRemainingPercent: Double? {
        groups.flatMap(\.buckets).map(\.remainingFraction).min().map { $0 * 100 }
    }
}

public struct AgyQuotaSource: Sendable {
    public init() {}

    public func latestQuota() async throws -> AgyQuota {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try Self.readQuota() })
            }
        }
    }

    private static func readQuota() throws -> AgyQuota {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        let executable = candidates.first { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
        }
        guard let executable else {
            throw UsageError.commandNotFound
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        process.currentDirectoryURL = home
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UsageError.unreadableUsage
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError.unreadableUsage
        }
        return try parseUsage(data)
    }

    static func parseUsage(_ data: Data) throws -> AgyQuota {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            return try Date.ISO8601FormatStyle().parse(value)
        }
        guard let usage = try? decoder.decode(Usage.self, from: data), usage.status == "SUCCESS" else {
            throw UsageError.unreadableUsage
        }
        return AgyQuota(groups: usage.command.data.groups, observedAt: Date())
    }

    private struct Usage: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                let groups: [AgyQuota.Group]
            }

            let data: Payload
        }

        let status: String
        let command: Command
    }

    private enum UsageError: LocalizedError {
        case commandNotFound
        case unreadableUsage

        var errorDescription: String? {
            switch self {
            case .commandNotFound:
                return "找不到 agy 命令"
            case .unreadableUsage:
                return "无法读取 agy 额度：在终端运行一次 agy 确认已登录"
            }
        }
    }
}
