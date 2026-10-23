import XCTest

@MainActor final class MealJournalUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testCloseRestoreUnknownFoodAndDeleteEmptyDraft() throws {
        let app = XCUIApplication(); app.launchArguments = ["--meal-ui-testing"]
        app.launchEnvironment["CACALC_TEST_RUN"] = UUID().uuidString; app.launch()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 15)); app.buttons["recordMeal"].tap()
        XCTAssertTrue(app.buttons["dictateMeal"].exists)
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Проверочный обед")
        XCTAssertTrue(app.buttons["mealAddUnknown"].waitForExistence(timeout: 5)); app.buttons["mealAddUnknown"].tap()
        app.buttons["closeMeal"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeMealDraft"].waitForExistence(timeout: 15)); app.buttons["resumeMealDraft"].tap()
        XCTAssertTrue(app.staticTexts["Проверочный обед"].waitForExistence(timeout: 5))
        app.buttons["saveMeal"].tap()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Проверочный обед"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["diaryNutritionRings"].exists)
        app.buttons["recordMeal"].tap(); app.buttons["closeMeal"].tap()
        app.buttons["Действия с черновиком"].tap(); app.buttons["discardMealDraft"].tap()
        XCTAssertTrue(app.buttons["resumeMealDraft"].waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Проверочный обед"].exists)
    }
}
