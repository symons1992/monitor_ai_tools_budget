import Foundation

public final class SessionLogScanner {
    public let sessionsDirectory: URL
    private let maximumFilesToInspect: Int
    private let maximumTailBytes: Int

    public init(
        sessionsDirectory: URL = SessionLogScanner.defaultSessionsDirectory(),
        maximumFilesToInspect: Int = 32,
        maximumTailBytes: Int = 768 * 1024
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.maximumFilesToInspect = maximumFilesToInspect
        self.maximumTailBytes = maximumTailBytes
    }

    public static func defaultSessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let customHome = environment["CODEX_HOME"], !customHome.isEmpty {
            return URL(fileURLWithPath: customHome, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public func latestQuota() throws -> CodexQuota {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sessionsDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw QuotaReadError.sessionsDirectoryMissing(sessionsDirectory)
        }

        let files = try newestLogFiles()
        guard !files.isEmpty else {
            throw QuotaReadError.noSessionLogs(sessionsDirectory)
        }

        var latest: CodexQuota?
        for file in files {
            guard let quota = try? latestQuota(in: file) else { continue }
            if latest == nil || quota.observedAt > latest!.observedAt {
                latest = quota
            }
        }

        guard let latest else {
            throw QuotaReadError.noQuotaRecord(sessionsDirectory)
        }
        return latest
    }

    private func newestLogFiles() throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var datedFiles: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            datedFiles.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return datedFiles
            .sorted { $0.date > $1.date }
            .prefix(maximumFilesToInspect)
            .map(\.url)
    }

    private func latestQuota(in file: URL) throws -> CodexQuota? {
        let data = try tailData(of: file)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            if let quota = Self.parseLine(String(line), sourceFile: file) {
                return quota
            }
        }
        return nil
    }

    private func tailData(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let requested = UInt64(maximumTailBytes)
        let offset = size > requested ? size - requested : 0
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()

        // If the read starts halfway through a JSONL record, discard that fragment.
        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return data
    }

    static func parseLine(_ line: String, sourceFile: URL) -> CodexQuota? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = findRateLimits(in: root),
              hasUsefulQuota(in: limits) else {
            return nil
        }

        let observedAt = date(from: root["timestamp"])
            ?? fileModificationDate(sourceFile)
            ?? Date.distantPast

        return CodexQuota(
            limitID: string(limits["limit_id"]),
            limitName: string(limits["limit_name"]),
            planType: string(limits["plan_type"]),
            primary: quotaWindow(limits["primary"]),
            secondary: quotaWindow(limits["secondary"]),
            credits: creditStatus(limits["credits"]),
            spendControlReached: bool(limits["spend_control_reached"]),
            rateLimitReachedType: string(limits["rate_limit_reached_type"]),
            observedAt: observedAt,
            sourceFile: sourceFile
        )
    }

    private static func findRateLimits(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let rateLimits = dictionary["rate_limits"] as? [String: Any] {
                return rateLimits
            }
            for child in dictionary.values {
                if let found = findRateLimits(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findRateLimits(in: child) { return found }
            }
        }
        return nil
    }

    private static func hasUsefulQuota(in limits: [String: Any]) -> Bool {
        quotaWindow(limits["primary"]) != nil
            || quotaWindow(limits["secondary"]) != nil
            || creditStatus(limits["credits"]) != nil
    }

    private static func quotaWindow(_ value: Any?) -> QuotaWindow? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = double(dictionary["used_percent"]) else {
            return nil
        }
        return QuotaWindow(
            usedPercent: usedPercent,
            windowMinutes: int(dictionary["window_minutes"]),
            resetsAt: date(fromUnixSeconds: dictionary["resets_at"])
        )
    }

    private static func creditStatus(_ value: Any?) -> CreditStatus? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return CreditStatus(
            hasCredits: bool(dictionary["has_credits"]) ?? false,
            unlimited: bool(dictionary["unlimited"]) ?? false,
            balance: string(dictionary["balance"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        if value is NSNull || value == nil { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if value is NSNull || value == nil { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(fromUnixSeconds value: Any?) -> Date? {
        guard let seconds = double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func fileModificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}
