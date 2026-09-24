import XCTest
@testable import ClaudeUsageBar

final class DecodeTests: XCTestCase {
    func testDecodesSessionAndWeekly() throws {
        let json = #"""
        {
          "five_hour": {"utilization": 18.0, "resets_at": "2026-09-24T18:10:00.428610+00:00"},
          "seven_day": {"utilization": 12, "resets_at": "2026-09-28T23:00:00Z"},
          "seven_day_opus": null,
          "nimbus_quill": {"utilization": 0.0, "resets_at": null},
          "limits": [{"kind": "weekly_scoped", "percent": 8}]
        }
        """#
        let snap = try UsageAPI.decode(Data(json.utf8))
        XCTAssertEqual(snap.session?.utilization, 18)
        XCTAssertEqual(snap.weekly?.utilization, 12)
        let expected = ISO8601DateFormatter().date(from: "2026-09-24T18:10:00Z")!.timeIntervalSince1970
        XCTAssertEqual(try XCTUnwrap(snap.session?.resetsAt).timeIntervalSince1970, expected, accuracy: 1)
        XCTAssertEqual(snap.windows.map(\.kind), [.session, .weekly])
    }

    func testMissingWindowsAreNil() throws {
        let snap = try UsageAPI.decode(Data(#"{"five_hour": null}"#.utf8))
        XCTAssertNil(snap.session)
        XCTAssertNil(snap.weekly)
        XCTAssertTrue(snap.windows.isEmpty)
    }

    func testRejectsNonObject() {
        XCTAssertThrowsError(try UsageAPI.decode(Data("[]".utf8)))
    }
}

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A session window where `elapsed` of the 5 hours has passed.
    private func session(used: Double, elapsed: Double) -> LimitWindow {
        let remaining = (1 - elapsed) * LimitKind.session.duration
        return LimitWindow(kind: .session, utilization: used, resetsAt: now.addingTimeInterval(remaining))
    }

    func testPaceBands() {
        XCTAssertEqual(session(used: 10, elapsed: 0.5).pace(now: now), .under)   // projects 20%
        XCTAssertEqual(session(used: 45, elapsed: 0.5).pace(now: now), .onPace)  // projects 90%
        XCTAssertEqual(session(used: 50, elapsed: 0.5).pace(now: now), .onPace)  // exactly 100%
        if case .ahead = session(used: 60, elapsed: 0.5).pace(now: now) {} else { XCTFail("expected ahead") }
        if case .wayAhead = session(used: 90, elapsed: 0.5).pace(now: now) {} else { XCTFail("expected wayAhead") }
        XCTAssertEqual(session(used: 100, elapsed: 0.5).pace(now: now), .reached)
    }

    func testNoPaceTooEarlyOrWithoutReset() {
        XCTAssertNil(session(used: 5, elapsed: 0.01).pace(now: now))
        XCTAssertNil(LimitWindow(kind: .weekly, utilization: 5, resetsAt: nil).pace(now: now))
    }

    func testRunsOutEstimate() {
        // 60% used in 2.5h → 24%/h → remaining 40% lasts 1h40m.
        guard case .ahead(let t) = session(used: 60, elapsed: 0.5).pace(now: now) else { return XCTFail() }
        XCTAssertEqual(t, 100 * 60, accuracy: 1)
    }

    func testElapsedFractionIsClamped() {
        let past = LimitWindow(kind: .session, utilization: 0, resetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(past.elapsedFraction(now: now), 1)
    }

    func testSeverityOrdersForMenuBar() {
        let paces: [Pace] = [.onPace, .wayAhead(runsOutIn: 1), .under]
        XCTAssertEqual(paces.max { $0.severity < $1.severity }, .wayAhead(runsOutIn: 1))
    }
}

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(59), "0m")
        XCTAssertEqual(Format.duration(45 * 60), "45m")
        XCTAssertEqual(Format.duration(2 * 3600 + 13 * 60), "2h 13m")
        XCTAssertEqual(Format.duration(4 * 86400 + 7 * 3600), "4d 7h")
        XCTAssertEqual(Format.duration(-10), "0m")
    }

    func testPercent() {
        XCTAssertEqual(Format.percent(74), "74%")
        XCTAssertEqual(Format.percent(3.5), "3.5%")
        XCTAssertEqual(Format.percent(12.4), "12%")
    }

    func testPlanName() {
        XCTAssertEqual(Credentials(accessToken: "x", expiresAt: nil, subscriptionType: "max", rateLimitTier: "default_claude_max_5x").planName, "Max 5x")
        XCTAssertEqual(Credentials(accessToken: "x", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil).planName, "Pro")
        XCTAssertNil(Credentials(accessToken: "x", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil).planName)
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9.0", than: "1.0.0"))
    }

    func testParsesRelease() throws {
        let json = #"""
        {"tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://github.com/o/r/releases/tag/v1.2.0",
         "assets": [
           {"name": "ClaudeUsageBar-1.2.0.zip.sha256", "browser_download_url": "https://example.com/a.zip.sha256"},
           {"name": "ClaudeUsageBar-1.2.0.zip", "browser_download_url": "https://example.com/a.zip"}
         ]}
        """#
        let release = try XCTUnwrap(Updater.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.zipURL.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(release.checksumURL?.absoluteString, "https://example.com/a.zip.sha256")
    }

    func testIgnoresPrereleaseAndRequiresZip() throws {
        XCTAssertNil(try Updater.parseRelease(Data(#"{"tag_name": "v2.0.0", "prerelease": true}"#.utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data(#"{"tag_name": "v2.0.0", "assets": []}"#.utf8)))
    }
}
