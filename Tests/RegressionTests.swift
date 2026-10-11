import Foundation
@testable import AIDock

// Command Line Tools do not ship XCTest. This entry point links the real app
// objects without main.swift, so it never launches the app or changes the Dock.
@main
@MainActor
struct RegressionTests {
    private static var failures = 0

    private static func expect(_ condition: Bool, _ description: String) {
        if condition { print("PASS: \(description)") }
        else { failures += 1; print("FAIL: \(description)") }
    }

    static func main() {
        testOutputSnapshot()
        testScanTimeOnly()
        testGeminiAccounts()
        print("\(failures) regression failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testOutputSnapshot() {
        let firstOutput = Date(timeIntervalSince1970: 1_800_000_001)
        let nextOutput = firstOutput.addingTimeInterval(40)
        let oldLive = LiveStatus(lastActive: firstOutput, lastOutput: firstOutput,
                                 sessions: 1, installed: true, running: true)
        let newLive = LiveStatus(lastActive: nextOutput, lastOutput: nextOutput,
                                 sessions: 1, installed: true, running: true)
        let old = ActivitySnapshot(live: [.claude: oldLive], states: [.claude: .working], scannedAt: firstOutput)
        let new = ActivitySnapshot(live: [.claude: newLive], states: [.claude: .working], scannedAt: nextOutput)
        // Both scans report one working session and unchanged chart columns.
        // Discarding the second scan makes a newly rendered widget use stale time.
        let renderTime = firstOutput.addingTimeInterval(61)
        expect(oldLive.state(now: renderTime) == .recent && newLive.state(now: renderTime) == .working,
               "recent output keeps the widget working after the previous output expires")
        expect(old != new, "new output within the same minute updates the activity snapshot")
    }

    private static func testScanTimeOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        let live = LiveStatus(installed: true, running: true)
        let old = ActivitySnapshot(live: [.claude: live], states: [.claude: .recent], scannedAt: now)
        let new = ActivitySnapshot(live: [.claude: live], states: [.claude: .recent], scannedAt: now.addingTimeInterval(30))
        expect(old == new, "scan time alone does not trigger an activity update")
    }

    private static func usages(geminiAccount: String?, antigravityAccount: String?) -> [Provider: ProviderUsage] {
        var gemini = ProviderUsage(provider: .gemini)
        gemini.quotaMoved = true
        gemini.account = geminiAccount
        var antigravity = ProviderUsage(provider: AntigravityProvider.provider)
        antigravity.account = antigravityAccount
        antigravity.windows = [UsageWindow(id: "Gemini-5h", label: "Gemini", short: "5h", usedPercent: 42)]
        return [.gemini: gemini, AntigravityProvider.provider: antigravity]
    }

    private static func testGeminiAccounts() {
        let cases: [(String?, String?)] = [(nil, "a@example.com"), ("a@example.com", nil),
                                          (nil, nil), ("", ""), (" ", " "), ("a@example.com", "b@example.com")]
        for (index, accounts) in cases.enumerated() {
            var values = usages(geminiAccount: accounts.0, antigravityAccount: accounts.1)
            UsageStore.borrowGeminiQuota(&values)
            expect(values[.gemini]!.windows.isEmpty, "unknown or different accounts do not share quota (case \(index + 1))")
        }
        var values = usages(geminiAccount: " A@example.com ", antigravityAccount: "a@example.com")
        UsageStore.borrowGeminiQuota(&values)
        expect(values[.gemini]!.windows.first?.usedPercent == 42
               && values[.gemini]!.windows.first?.id == "antigravity-Gemini-5h",
               "confirmed matching accounts can borrow Gemini quota")
    }
}
