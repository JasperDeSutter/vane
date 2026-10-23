import XCTest
@testable import vane

@MainActor final class SearchRankingTests: XCTestCase {
    private func fixture() throws -> Store {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Store(path: directory.appendingPathComponent("history.db").path)
    }

    func testExactTitleBeatsPopularSubstringAndBookmark() throws {
        let store = try fixture()
        let exact = URL(string: "https://rare.example")!
        store.record(exact, title: "Swift")
        for _ in 0..<20 { store.record(URL(string: "https://popular.example")!, title: "Learn Swift today") }
        store.toggleBookmark(URL(string: "https://bookmark.example")!, title: "Swift resources")
        XCTAssertEqual(store.suggest("Swift").first?.url, exact.absoluteString)
        XCTAssertEqual(store.history(matching: "Swift", limit: 1).first?.url, exact.absoluteString)
    }

    func testFuzzyMatchingFindsOldPageOutsideRecentHistoryCap() throws {
        let store = try fixture()
        let exact = URL(string: "https://github.com/project")!
        store.record([(exact, "GitHub Project", Date(timeIntervalSince1970: 1))])
        store.record((0..<600).map { (URL(string: "https://unrelated.example/\($0)")!, "Unrelated", Date.now) })
        XCTAssertEqual(store.suggest("ghp").map(\.url), [exact.absoluteString])
        XCTAssertEqual(store.history(matching: "ghp", limit: 1).first?.url, exact.absoluteString)
    }

    func testExactAndContinuousMatchesBeatScatteredLetters() {
        XCTAssertGreaterThan(Palette.score("abc", "abc")!, Palette.score("abc", "a b c a b c")!)
        XCTAssertGreaterThan(Palette.score("abc", "xabc")!, Palette.score("abc", "a b c")!)
        // The first 'a' is a distraction; use the later continuous alignment.
        XCTAssertGreaterThan(Palette.score("abc", "a---abc")!, Palette.score("abc", "a---b---c")!)
        XCTAssertNotNil(Palette.score("cafe", "Café"))
    }

    func testBookmarkIdentitySurvivesHistoryWinningItsTitleMatch() throws {
        let store = try fixture()
        let page = URL(string: "https://saved.example")!
        store.record(page, title: "Exact")
        store.toggleBookmark(page, title: "Reference")
        store.toggleBookmark(URL(string: "https://other.example")!, title: "Exact")
        let first = try XCTUnwrap(store.suggest("Exact", limit: 1).first)
        XCTAssertEqual(first.url, page.absoluteString)
        XCTAssertTrue(first.bookmarked, "A saved page must not gain a history-only forget action")
    }

    func testStrongTabsKeepTheirExistingKeyboardPriority() {
        XCTAssertTrue(Palette.strong("go", title: "Google", url: "https://google.com"))
        XCTAssertTrue(Palette.strong("go", title: "Search", url: "https://www.google.com"))
        XCTAssertTrue(Palette.strong("tur", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertFalse(Palette.strong("tu", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertFalse(Palette.strong("gpt", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertGreaterThan(Palette.score("doc", "mydoc doc")!, Palette.score("doc", "mydocdoc")!)
    }

    func testURLMatchesAndLiteralWildcardsStayPredictable() throws {
        let store = try fixture()
        let url = URL(string: "https://www.example.com/docs")!
        store.record(url, title: "Reference")
        store.toggleBookmark(URL(string: "https://other.example")!, title: "example.com/docs extras")
        XCTAssertEqual(store.suggest("example.com/docs").first?.url, url.absoluteString)
        XCTAssertEqual(store.suggest("www.example.com/docs").first?.url, url.absoluteString)
        XCTAssertEqual(store.suggest("https://www.example.com/docs").first?.url, url.absoluteString)
        XCTAssertTrue(Palette.strong("https://www.example.com/docs", title: "Reference", url: url.absoluteString))
        XCTAssertTrue(store.suggest("100%").isEmpty)
        store.record(URL(string: "https://cafe.example")!, title: "Café handbook")
        XCTAssertEqual(store.suggest("cafe handbook").first?.title, "Café handbook")
    }

    func testHeldResultsSurviveEitherSourceArrivingFirst() {
        struct Row: Equatable { let id: String; let completion: Bool }
        let oldHistory = Row(id: "url:old-page", completion: false)
        let oldPhrase = Row(id: "url:old-search", completion: true)
        let newHistory = Row(id: "url:new-page", completion: false)
        let newPhrase = Row(id: "url:new-search", completion: true)
        func shown(_ live: [Row], history: Bool = true, engine: Bool = true) -> [Row] {
            Palette.heldResults(live: live, held: [oldHistory, oldPhrase], historyPending: history,
                                enginePending: engine, isCompletion: \.completion, id: \.id)
        }
        XCTAssertEqual(shown([]), [oldHistory, oldPhrase], "nothing new yet: the last query's rows stay")
        XCTAssertEqual(shown([newPhrase], engine: false), [oldHistory, newPhrase],
                       "engine first: held history stays until the local lookup answers")
        XCTAssertEqual(shown([newHistory], history: false), [newHistory, oldPhrase],
                       "history first: held completions stay until the engine answers")
        XCTAssertEqual(shown([], history: false), [oldPhrase],
                       "history answered with nothing while the engine is slow: old history goes")
        XCTAssertEqual(shown([], history: true, engine: false), [oldHistory],
                       "the engine answered with nothing: old completions go")
        XCTAssertEqual(shown([newHistory, newPhrase], history: false, engine: false), [newHistory, newPhrase])
        XCTAssertEqual(shown([], history: false, engine: false), [], "both in and empty: shown as empty")
        let sameAsHistory = Row(id: newHistory.id, completion: true)
        XCTAssertEqual(Palette.heldResults(live: [newHistory], held: [sameAsHistory], historyPending: false,
                                           enginePending: true, isCompletion: \.completion, id: \.id),
                       [newHistory], "a held row is never shown twice")
    }

    func testHoverStaysOnItsSlotWhileResultsReorderUnderAStillPointer() {
        // Rows are rewritten in place: a reorder keeps the count, so the slot under the
        // pointer stays lit and now shows whatever result moved into it.
        XCTAssertEqual(Palette.litSlot(hover: 2, rowCount: 8), 2)
        XCTAssertNil(Palette.litSlot(hover: 5, rowCount: 3), "a slot the shorter list no longer has is not lit")
        XCTAssertNil(Palette.litSlot(hover: nil, rowCount: 8))
    }

    func testResultsFitAShortWindowAtTheHighestRowSetting() {
        // Field, divider and list padding: everything in the bar but its rows.
        let chrome = Look.barFieldHeight + 1 + (Look.barInset - Look.barRowGap + Look.barInset)
        let rows = Palette.fittingRows(12, windowHeight: 600, chrome: chrome)
        XCTAssertLessThan(rows, 12, "twelve rows do not fit a 600pt window")
        XCTAssertLessThanOrEqual(chrome + Palette.rowsHeight(rows) + Look.inset * 2, 600,
                                 "the whole bar, rows included, stays inside the window")
        XCTAssertEqual(Palette.fittingRows(12, windowHeight: 2000, chrome: chrome), 12,
                       "a tall window draws every row asked for")
        XCTAssertEqual(Palette.fittingRows(8, windowHeight: 100, chrome: chrome), 1, "never fewer than one")
        XCTAssertEqual(Palette.fittingRows(8, windowHeight: .infinity, chrome: chrome), 8,
                       "before the first layout the window's height is unknown")
    }
}
