import FengshuiKit
import XCTest
@testable import Fengshui

/// Phase 7 live smoke test — only when ANTHROPIC_API_KEY is set (scripts/claude_smoke_test.sh
/// passes it as TEST_RUNNER_FENGSHUI_ANTHROPIC_KEY). Asks the three preset questions against
/// the SYNTHETIC typical_week database (never real data) with the cheapest current model.
final class LiveClaudeTests: XCTestCase {
    func testPresetQuestionsLive() async throws {
        guard let key = ProcessInfo.processInfo.environment["FENGSHUI_ANTHROPIC_KEY"], !key.isEmpty else {
            throw XCTSkip("ANTHROPIC_API_KEY not set")
        }
        let src = repoRoot.appendingPathComponent("build/parity/mac.sqlite")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("live-claude-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        let db = try AppDatabase(path: dst.path)
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        let tz = TimeZone(identifier: sc.tz)!
        let a = ClaudeAssistant(db: db, tools: try ClaudeTools(dbPath: db.path, timeZone: tz), transport: AnthropicHTTP(apiKey: key),
                                clock: FixedClock(Date(timeIntervalSince1970: sc.now)), timeZone: tz,
                                model: ClaudeAssistant.smokeTestModel)
        var total = 0
        for q in AIQuestionStore.seeds {
            let ans = await a.ask(q)
            print("METRIC claude_smoke q=\"\(q)\" ok=\(ans.error == nil) tools=\(ans.toolCalls) in=\(ans.inputTokens) out=\(ans.outputTokens)")
            XCTAssertNil(ans.error, ans.text)
            XCTAssertFalse(ans.toolCalls.isEmpty, "answered without using tool data: \(q)")
            XCTAssertFalse(ans.text.isEmpty)
            total += ans.inputTokens + ans.outputTokens
        }
        print("METRIC claude_smoke_total_tokens=\(total)")
    }
}
