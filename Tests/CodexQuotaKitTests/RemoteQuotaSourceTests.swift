import Foundation
import XCTest
@testable import CodexQuotaKit

final class RemoteQuotaSourceTests: XCTestCase {
    func testParsesClaudeUsage() throws {
        let json = """
        {
          "five_hour": { "utilization": 4, "resets_at": "2026-10-27T18:30:00.866922+00:00" },
          "seven_day": { "utilization": 3, "resets_at": "2026-10-28T06:00:00.866945+00:00" }
        }
        """
        let formatter = ISO8601DateFormatter()
        let fiveHourBase = try XCTUnwrap(formatter.date(from: "2026-10-27T18:30:00Z"))
        let sevenDayBase = try XCTUnwrap(formatter.date(from: "2026-10-28T06:00:00Z"))
        let quota = try ClaudeQuotaSource.parseUsage(Data(json.utf8), planType: "pro")

        XCTAssertEqual(quota.planType, "pro")
        XCTAssertEqual(quota.fiveHour?.windowMinutes, 300)
        XCTAssertEqual(quota.fiveHour?.usedPercent, 4)
        XCTAssertEqual(quota.fiveHour?.remainingPercent, 96)
        XCTAssertEqual(quota.sevenDay?.windowMinutes, 10_080)
        XCTAssertEqual(quota.sevenDay?.usedPercent, 3)
        XCTAssertEqual(quota.sevenDay?.remainingPercent, 97)
        let fiveHourReset = try XCTUnwrap(quota.fiveHour?.resetsAt)
        let sevenDayReset = try XCTUnwrap(quota.sevenDay?.resetsAt)
        XCTAssertEqual(fiveHourReset.timeIntervalSince(fiveHourBase), 0.866922, accuracy: 0.000001)
        XCTAssertEqual(sevenDayReset.timeIntervalSince(sevenDayBase), 0.866945, accuracy: 0.000001)

        let empty = Data(#"{"five_hour":null,"seven_day":null}"#.utf8)
        let emptyQuota = try ClaudeQuotaSource.parseUsage(empty, planType: nil)
        XCTAssertNil(emptyQuota.fiveHour)
        XCTAssertNil(emptyQuota.sevenDay)
    }

    func testDecodesHexKeychainOutput() {
        let output = Data("  7b00Ff7D\n".utf8)
        XCTAssertEqual(QuotaKeychain.decodeOutput(output), Data([0x7B, 0x00, 0xFF, 0x7D]))

        let plainText = Data("{\"sample\":true}\n".utf8)
        XCTAssertEqual(QuotaKeychain.decodeOutput(plainText), plainText)
    }

    func testParsesAgyUsage() throws {
        let json = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "response": "…",
          "command": {
            "name": "usage",
            "data": {
              "description": "…",
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "…",
                  "buckets": [
                    { "id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remaining_fraction": 0.9118912816047668, "reset_time": "2026-12-02T11:44:56Z" },
                    { "id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remaining_fraction": 0.6775651574134827, "reset_time": "2026-11-25T16:44:56Z" }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    { "id": "3p-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z" },
                    { "id": "3p-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z" }
                  ]
                }
              ]
            }
          }
        }
        """
        let quota = try AgyQuotaSource.parseUsage(Data(json.utf8))

        XCTAssertEqual(quota.groups.map(\.displayName), ["Gemini Models", "Claude and GPT models"])
        let gemini = try XCTUnwrap(quota.groups.first)
        let thirdParty = try XCTUnwrap(quota.groups.last)
        XCTAssertEqual(gemini.buckets.map { $0.quotaWindow.windowMinutes }, [10_080, 300])
        XCTAssertEqual(thirdParty.buckets.map { $0.quotaWindow.windowMinutes }, [10_080, 300])
        let weekly = try XCTUnwrap(gemini.buckets.first)
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-02T11:44:56Z"))
        XCTAssertEqual(weekly.remainingFraction, 0.9118912816047668)
        XCTAssertEqual(weekly.quotaWindow.resetsAt, reset)
        XCTAssertEqual(thirdParty.buckets.map { $0.quotaWindow.remainingPercent }, [100, 100])
        XCTAssertTrue(thirdParty.buckets.allSatisfy { $0.quotaWindow.resetsAt == nil })
        XCTAssertEqual(try XCTUnwrap(quota.minimumRemainingPercent), 67.75651574134827, accuracy: 0.000001)
    }

    func testAgyDefaultsMissingRemainingFractionToZero() throws {
        let json = """
        {
          "status": "SUCCESS",
          "command": { "data": { "groups": [{
            "name": "Gemini Models",
            "buckets": [{ "window": "5h", "reset_time": "2026-11-25T16:44:56.125Z" }]
          }] } }
        }
        """
        let quota = try AgyQuotaSource.parseUsage(Data(json.utf8))
        let bucket = try XCTUnwrap(quota.groups.first?.buckets.first)
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T16:44:56Z"))

        XCTAssertEqual(bucket.remainingFraction, 0)
        XCTAssertEqual(bucket.resetTime, reset.addingTimeInterval(0.125))
        XCTAssertEqual(quota.minimumRemainingPercent, 0)
    }

    func testRejectsInvalidAgyUsage() {
        let invalidResponses = [
            #"{"status":"ERROR","error":"internal error"}"#,
            #"{"status":"ERROR","command":{"data":{"groups":[]}}}"#,
            #"{"status":"SUCCESS","command":{"data":{}}}"#,
            "not JSON"
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(try AgyQuotaSource.parseUsage(Data(response.utf8)), response) { error in
                XCTAssertEqual(error.localizedDescription, "无法读取 agy 额度：在终端运行一次 agy 确认已登录")
            }
        }
    }
}
