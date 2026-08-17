import Foundation
import XCTest
@testable import CodexQuotaKit

final class SessionLogScannerTests: XCTestCase {
    func testParsesCurrentRateLimitShape() throws {
        let line = #"{"timestamp":"2026-08-17T07:46:51.654Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":23.5,"window_minutes":300,"resets_at":1787552209},"secondary":{"used_percent":51,"window_minutes":10080,"resets_at":1788000000},"credits":{"has_credits":true,"unlimited":false,"balance":"12.50"},"plan_type":"pro","spend_control_reached":false,"rate_limit_reached_type":null}}}"#
        let file = URL(fileURLWithPath: "/tmp/test.jsonl")

        let quota = try XCTUnwrap(SessionLogScanner.parseLine(line, sourceFile: file))

        XCTAssertEqual(quota.limitID, "codex")
        XCTAssertEqual(quota.planType, "pro")
        XCTAssertEqual(quota.primary?.usedPercent, 23.5)
        XCTAssertEqual(quota.primary?.remainingPercent, 76.5)
        XCTAssertEqual(quota.primary?.windowMinutes, 300)
        XCTAssertEqual(quota.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(quota.credits?.balance, "12.50")
        XCTAssertEqual(quota.spendControlReached, false)
    }

    func testSkipsEmptyAndMalformedRecords() {
        let file = URL(fileURLWithPath: "/tmp/test.jsonl")
        XCTAssertNil(SessionLogScanner.parseLine("not json", sourceFile: file))
        XCTAssertNil(SessionLogScanner.parseLine(#"{"payload":{"rate_limits":{"primary":null,"secondary":null,"credits":null}}}"#, sourceFile: file))
    }

    func testFindsNewestUsefulRecordAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = directory.appendingPathComponent("older.jsonl")
        let newer = directory.appendingPathComponent("newer.jsonl")
        let oldLine = #"{"timestamp":"2026-08-17T07:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1787552209}}}}"#
        let newLine = #"{"timestamp":"2026-08-17T08:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_at":1787552209}}}}"#
        try Data((oldLine + "\n").utf8).write(to: older)
        try Data((newLine + "\n").utf8).write(to: newer)

        let scanner = SessionLogScanner(sessionsDirectory: directory)
        XCTAssertEqual(try scanner.latestQuota().primary?.usedPercent, 20)
    }

    func testUsesCustomCodexHome() {
        let url = SessionLogScanner.defaultSessionsDirectory(
            environment: ["CODEX_HOME": "/tmp/custom-codex"],
            homeDirectory: URL(fileURLWithPath: "/ignored")
        )
        XCTAssertEqual(url.path, "/tmp/custom-codex/sessions")
    }
}
