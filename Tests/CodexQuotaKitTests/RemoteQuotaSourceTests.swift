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
        XCTAssertThrowsError(try ClaudeQuotaSource.parseUsage(Data("{}".utf8), planType: nil))
    }

    func testDecodesAgyKeychainEntry() throws {
        let json = """
        {
          "token": {
            "access_token": "sample-access-token",
            "token_type": "Bearer",
            "refresh_token": "sample-refresh-token",
            "expiry": "2026-11-25T20:44:47.622986+08:00",
            "expires_in": 3599
          },
          "auth_method": "consumer",
          "id_token_email": "example@example.com"
        }
        """
        let entry = "go-keyring-base64:\(Data(json.utf8).base64EncodedString())\n"

        XCTAssertEqual(try AgyQuotaSource.decodeAccessToken(Data(entry.utf8)), "sample-access-token")
        XCTAssertThrowsError(try AgyQuotaSource.decodeAccessToken(Data(json.utf8)))
    }

    func testParsesAgyUsage() throws {
        let json = """
        {
          "groups": [
            {
              "buckets": [
                { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 1 },
                { "bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1 }
              ],
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"
            },
            {
              "buckets": [
                { "window": "daily", "remainingFraction": 0.625, "resetTime": "2026-11-25T20:44:47+08:00" }
              ],
              "displayName": "Other models"
            }
          ],
          "description": "..."
        }
        """
        let quota = try AgyQuotaSource.parseUsage(Data(json.utf8), planType: "Google AI Pro")

        XCTAssertEqual(quota.planType, "Google AI Pro")
        XCTAssertEqual(quota.groups.map(\.displayName), ["Claude and GPT models", "Other models"])
        let sampleBuckets = try XCTUnwrap(quota.groups.first?.buckets)
        XCTAssertEqual(sampleBuckets.map { $0.quotaWindow.windowMinutes }, [10_080, 300])
        XCTAssertEqual(sampleBuckets.map { $0.quotaWindow.remainingPercent }, [100, 100])
        XCTAssertTrue(sampleBuckets.allSatisfy { $0.resetTime == nil })
        let daily = try XCTUnwrap(quota.groups.last?.buckets.first)
        XCTAssertEqual(daily.window, "daily")
        XCTAssertNil(daily.quotaWindow.windowMinutes)
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T12:44:47Z"))
        XCTAssertEqual(daily.resetTime, reset)
        XCTAssertEqual(daily.quotaWindow.usedPercent, 37.5)
        XCTAssertEqual(quota.minimumRemainingPercent, 62.5)
    }

    func testParsesAgyGeminiQuota() throws {
        let json = """
        {
          "models": {
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": { "remainingFraction": 0.9775935, "resetTime": "2026-11-25T16:44:56Z" }
            },
            "gemini-3.5-flash-lite": {
              "displayName": "Gemini 3.5 Flash Lite",
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": { "remainingFraction": 0.9775935, "resetTime": "2026-11-25T16:44:56Z" }
            },
            "tab_flash_lite_preview": {
              "modelProvider": "MODEL_PROVIDER_GOOGLE",
              "quotaInfo": { "remainingFraction": 1 }
            },
            "claude-opus-5-5-high": {
              "displayName": "Claude Opus 5.5 (High)",
              "modelProvider": "MODEL_PROVIDER_ANTHROPIC",
              "quotaInfo": { "remainingFraction": 1, "resetTime": "2026-11-25T17:50:23Z" }
            },
            "gemini-without-quota": { "modelProvider": "MODEL_PROVIDER_GOOGLE" }
          }
        }
        """
        let group = try XCTUnwrap(AgyQuotaSource.parseGeminiGroup(Data(json.utf8)))
        let bucket = try XCTUnwrap(group.buckets.first)
        let reset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T16:44:56Z"))

        XCTAssertEqual(group.displayName, "Gemini 模型")
        XCTAssertEqual(group.buckets.count, 1)
        XCTAssertEqual(bucket.window, "额度")
        XCTAssertNil(bucket.quotaWindow.windowMinutes)
        XCTAssertEqual(bucket.remainingFraction, 0.9775935)
        XCTAssertEqual(bucket.resetTime, reset)
        let quota = AgyQuota(planType: nil, groups: [group], observedAt: Date())
        XCTAssertEqual(try XCTUnwrap(quota.minimumRemainingPercent), 97.75935, accuracy: 0.000001)
    }
}
