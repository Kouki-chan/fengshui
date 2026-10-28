import XCTest
@testable import Fengshui

/// A Claude stand-in that answers after a short pause, recording the order of questions.
private actor SlowAssistant: Assistant {
    private(set) var asked: [String] = []
    let delay: Duration

    init(delay: Duration = .milliseconds(200)) { self.delay = delay }

    func ask(_ question: String) async -> ClaudeAssistant.Answer {
        asked.append(question)
        try? await Task.sleep(for: delay)
        return ClaudeAssistant.Answer(text: "Answer to \(question)", error: Task.isCancelled ? "cancelled" : nil,
                                      answeredBy: "Fake")
    }
}

/// Phase 10 (DECISIONS D-23): the Ask conversation outlives the Ask tab, queues questions and
/// badges the tab when an answer lands elsewhere.
@MainActor
final class AskSessionTests: XCTestCase {
    func env() throws -> AppEnvironment { try AppEnvironment.make(arguments: ["x", "-FengshuiTestMode", "typical_week"]) }

    func testAnswerArrivesWhileOnAnotherTabAndBadgesAsk() async throws {
        let fake = SlowAssistant()
        let session = AskSession(env: try env(), assistant: { fake })
        session.isVisible = true
        session.send("How did I sleep?")
        XCTAssertTrue(session.isWorking)
        session.isVisible = false                       // user switches to the Data tab mid-answer
        await session.idle()
        XCTAssertEqual(session.turns.map(\.state), [.done])
        XCTAssertEqual(session.turns.first?.answer?.text, "Answer to How did I sleep?")
        XCTAssertEqual(session.unseen, 1)
        session.isVisible = true                        // back on Ask: the badge clears
        XCTAssertEqual(session.unseen, 0)
    }

    func testQuestionsQueueInOrder() async throws {
        let fake = SlowAssistant(delay: .milliseconds(50))
        let session = AskSession(env: try env(), assistant: { fake })
        session.isVisible = true
        session.send("one")
        session.send("  two \n")
        session.send("   ")                             // blank: ignored
        XCTAssertEqual(session.turns.map(\.question), ["one", "two"])
        XCTAssertEqual(session.turns.last?.state, .queued)
        await session.idle()
        let asked = await fake.asked
        XCTAssertEqual(asked, ["one", "two"])
        XCTAssertEqual(session.turns.map(\.state), [.done, .done])
        XCTAssertEqual(session.unseen, 0)
    }

    func testStopEndsTheRunningAnswerAndDropsTheQueue() async throws {
        let fake = SlowAssistant(delay: .seconds(5))
        let session = AskSession(env: try env(), assistant: { fake })
        session.send("long")
        session.send("next")
        try await Task.sleep(for: .milliseconds(100))
        session.stop()
        await session.idle()
        XCTAssertEqual(session.turns.map(\.state), [.stopped, .stopped])
        XCTAssertNil(session.turns.last?.answer)
        session.clear()
        XCTAssertTrue(session.turns.isEmpty)
    }

    func testNoKeyExplainsWhatToDo() async throws {
        let session = AskSession(env: try env(), assistant: { nil })
        session.send("How active was I today?")
        await session.idle()
        XCTAssertEqual(session.turns.first?.answer?.text, AskSession.noKeyAnswer)
        XCTAssertNil(session.turns.first?.report, "no report without an assistant")
    }

    func testUIStateTabDrivesAskVisibility() throws {
        let ui = UIState(env: try env())
        XCTAssertFalse(ui.ask.isVisible)
        ui.tab = .ask
        XCTAssertTrue(ui.ask.isVisible)
        ui.tab = .reports
        XCTAssertFalse(ui.ask.isVisible)
        XCTAssertFalse(ui.hasKey, "test mode has no API key")
    }
}

@MainActor
final class ThemeTests: XCTestCase {
    func testEveryThemeHasAFiveColourPaletteAndUniqueID() {
        XCTAssertEqual(Set(Theme.all.map(\.id)).count, Theme.all.count)
        for t in Theme.all { XCTAssertEqual(t.swatches.count, 5, t.name) }
        XCTAssertEqual(Theme.default.id, "lotus")
        XCTAssertEqual(Theme.named("nope"), .lotus)
        XCTAssertEqual(Theme.named("ocean"), .ocean)
    }

    func testLotusMatchesTheMoodBoard() {
        let ui = Theme.lotus.swatches.map { UIColor($0).hexString }
        XCTAssertEqual(ui, ["1B2B28", "23595C", "87536E", "D7809A", "D8BFCC"])
    }

    func testAppearancePersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "appearance-test"))
        defaults.removePersistentDomain(forName: "appearance-test")
        let a = Appearance(defaults: defaults)
        XCTAssertEqual(a.theme, .lotus)
        XCTAssertEqual(a.mode, .system)
        a.theme = .midnight
        a.mode = .dark
        let b = Appearance(defaults: defaults)
        XCTAssertEqual(b.theme, .midnight)
        XCTAssertEqual(b.mode.colorScheme, .dark)
    }
}

private extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
