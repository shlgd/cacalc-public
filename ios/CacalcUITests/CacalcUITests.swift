import XCTest

@MainActor final class CacalcUITests: XCTestCase {
    func testCatalogSearchRemainsVisibleAfterScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let productsTab = app.buttons["Продукты"]
        XCTAssertTrue(productsTab.waitForExistence(timeout: 10))
        productsTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        let create = app.buttons["createProduct"]
        XCTAssertTrue(create.isHittable)
        keepScreenshot(app, "Каталог — поиск сверху")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(search.isHittable, "Поиск должен оставаться доступным после прокрутки")
        XCTAssertTrue(app.buttons["createProduct"].isHittable)
        keepScreenshot(app, "Каталог — после прокрутки")
        search.tap()
        search.typeText("банан")
        XCTAssertEqual(search.value as? String, "банан")
        keepScreenshot(app, "Каталог — ввод поиска")
    }

    func testPersonalProductCreationAndDiaryLookup() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 10))
        app.buttons["Продукты"].tap()
        app.buttons["createProduct"].tap()
        XCTAssertTrue(productField("productName", in: app).waitForExistence(timeout: 5))
        let values = [("productName", "Синтетический творог"), ("productBrand", "Тестовая марка"),
                      ("productCalories", "95,5"), ("productProtein", "16.25"),
                      ("productFat", "1,5"), ("productCarbs", "3.05")]
        for (key, _) in values { XCTAssertTrue(productField(key, in: app).isHittable, key) }
        XCTAssertTrue(app.buttons["productVoice"].isHittable)
        XCTAssertTrue(app.buttons["productVoice"].isEnabled, "Микрофон доступен до установки моделей")
        XCTAssertEqual(app.buttons["productVoice"].frame.midX, app.frame.midX, accuracy: 1)
        keepScreenshot(app, "Продукт — пустая карточка")
        productField("productName", in: app).tap()
        for (index, pair) in values.enumerated() {
            let field = productField(pair.0, in: app)
            XCTAssertTrue(field.exists, pair.0)
            // The keyboard overlays lower fields; its value readout remains visible while editing.
            field.typeText(pair.1)
            if index >= 2 {
                let readout = app.staticTexts["productKeyboardValue"]
                XCTAssertTrue(readout.isHittable)
                XCTAssertTrue(readout.label.contains(pair.1))
            }
            if index == 2 { keepScreenshot(app, "Продукт — цифровая клавиатура") }
            if index < values.count - 1 { app.buttons["nextProductField"].tap() }
        }
        app.buttons["productKeyboardDone"].tap()
        keepScreenshot(app, "Продукт — заполненная карточка")
        app.buttons["closeProduct"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resumeProductDraft_'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resumeProductDraft_'")).firstMatch.tap()
        for (key, value) in values { XCTAssertEqual(productField(key, in: app).value as? String, value) }
        let save = app.buttons["saveProduct"]
        XCTAssertTrue(save.isHittable); XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["createProduct"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Синтетический творог"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Личный каталог"
        attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Дневник"].tap()
        app.buttons["recordMeal"].tap()
        app.searchFields.firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap(); search.typeText("Тестовая марка")
        XCTAssertTrue(app.staticTexts["Синтетический творог"].waitForExistence(timeout: 5))
    }

    func testCompactProductAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Продукты"].waitForExistence(timeout: 10))
        app.buttons["Продукты"].tap(); app.buttons["createProduct"].tap()
        XCTAssertTrue(productField("productName", in: app).waitForExistence(timeout: 5))
        for key in ["productName", "productBrand", "productCalories", "productProtein", "productFat", "productCarbs"] {
            XCTAssertTrue(productField(key, in: app).isHittable, key)
        }
        XCTAssertTrue(app.buttons["productVoice"].isHittable)
        XCTAssertTrue(app.buttons["productScanner"].isHittable)
        keepScreenshot(app, "Продукт — крупный системный текст")
        let carbs = productField("productCarbs", in: app)
        carbs.tap(); carbs.typeText("0,5")
        XCTAssertEqual(carbs.value as? String, "0,5")
        keepScreenshot(app, "Продукт — крупный текст и клавиатура")
        app.buttons["productKeyboardDone"].tap()
    }

    func testProductScannerOpensCameraAndPreservesDraftOnClose() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["Продукты"].waitForExistence(timeout: 10))
        app.buttons["Продукты"].tap(); app.buttons["createProduct"].tap()
        let name = productField("productName", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Синтетическая карточка"); app.buttons["productKeyboardDone"].tap()
        let scanner = app.buttons["productScanner"], mic = app.buttons["productVoice"]
        XCTAssertTrue(scanner.isHittable); XCTAssertTrue(scanner.isEnabled)
        XCTAssertLessThan(scanner.frame.maxX, mic.frame.minX)
        XCTAssertEqual(scanner.frame.midY, mic.frame.midY, accuracy: 1)
        XCTAssertEqual(mic.frame.midX, app.frame.midX, accuracy: 1)
        keepScreenshot(app, "Продукт — сканер слева от диктовки")
        scanner.tap()
        XCTAssertTrue(app.buttons["closeScanner"].waitForExistence(timeout: 5))
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.descendants(matching: .any)["scannerUnavailable"].waitForExistence(timeout: 5))
        #endif
        XCTAssertFalse(app.textFields["productBarcode"].exists, "Кнопка открывает камеру, а не ручной ввод кода")
        keepScreenshot(app, "Сканер — камера недоступна в симуляторе")
        app.buttons["closeScanner"].tap()
        XCTAssertTrue(scanner.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Синтетическая карточка")
        XCTAssertTrue(mic.isEnabled)
    }

    func testProductKeyboardDoesNotMoveCard() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["Продукты"].waitForExistence(timeout: 10))
        app.buttons["Продукты"].tap(); app.buttons["createProduct"].tap()
        XCTAssertTrue(productField("productName", in: app).waitForExistence(timeout: 5))
        let keys = ["productName", "productBrand", "productCalories", "productProtein", "productFat", "productCarbs"]
        let frames = keys.map { productField($0, in: app).frame }
        let voiceFrame = app.buttons["productVoice"].frame
        keepScreenshot(app, "Карточка — до клавиатуры")
        for key in ["productCalories", "productProtein", "productFat", "productCarbs", "productName"] {
            let field = productField(key, in: app)
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            for (index, id) in keys.enumerated() {
                let frame = productField(id, in: app).frame
                XCTAssertEqual(frame.minY, frames[index].minY, accuracy: 1, id + " сдвинулось при фокусе " + key)
                XCTAssertEqual(frame.height, frames[index].height, accuracy: 1, id + " изменило размер")
            }
            XCTAssertEqual(app.buttons["productVoice"].frame.minY, voiceFrame.minY, accuracy: 1)
            if key == "productCarbs" { keepScreenshot(app, "Карточка — клавиатура поверх") }
            app.buttons["productKeyboardDone"].tap()
        }
    }

    private func productField(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testOfflineDiaryFlow() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 10))
        app.buttons["recordMeal"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("молоко")
        let product = app.buttons["mealSearch_basic:no:01.229"]
        XCTAssertTrue(product.waitForExistence(timeout: 5)); product.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mealRow_' ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let amount = app.textFields["mealAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap(); amount.typeText("125,5")
        app.buttons["Готово"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["mealPreviewAdded"].waitForExistence(timeout: 5))
        app.buttons["saveMeal"].tap()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["diaryNutritionRings"].exists)
        XCTAssertTrue(app.staticTexts["Молоко 1%"].exists)
        keepScreenshot(app, "Дневник — текущий базовый каталог")
    }
    func testIndependentMealDrafts() throws {
        let app = XCUIApplication(); app.launchArguments = ["--meal-ui-testing"]
        app.launchEnvironment["CACALC_TEST_RUN"] = UUID().uuidString; app.launch()
        XCTAssertTrue(app.buttons["recordMeal"].waitForExistence(timeout: 10)); app.buttons["recordMeal"].tap()
        app.buttons["closeMeal"].tap()
        XCTAssertTrue(app.buttons["resumeMealDraft"].waitForExistence(timeout: 5))
        app.buttons["Действия с черновиком"].tap(); app.buttons["Новый приём"].tap()
        let search = app.searchFields.firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Синтетический второй приём"); app.buttons["mealAddUnknown"].tap()
        app.buttons["closeMeal"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["resumeMealDraft"].waitForExistence(timeout: 15)); app.buttons["resumeMealDraft"].tap()
        let drafts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mealDraft_' "))
        XCTAssertEqual(drafts.count, 2)
        drafts.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["closeMeal"].waitForExistence(timeout: 5))
        keepScreenshot(app, "Продолжение выбранного черновика")
    }

    func testAccessibilityProfile() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["Профиль"].waitForExistence(timeout: 10))
        app.buttons["Профиль"].tap()
        for (id, value) in [("goalCalories", "2000"), ("goalProtein", "100"), ("goalFat", "70"), ("goalCarbs", "250")] {
            let field = app.textFields[id]
            for _ in 0..<16 { if field.isHittable { break }; smallScroll(app) }
            field.tap(); field.typeText(value)
            if app.buttons["dismissKeyboard"].exists { app.buttons["dismissKeyboard"].tap() }
        }
        let save = app.buttons["saveGoals"]
        for _ in 0..<16 { if save.isHittable { break }; smallScroll(app) }
        save.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["Дневник"].tap()
        XCTAssertTrue(app.staticTexts["calorieValue"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Крупный текст — дневник"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPagingDirectionAndCancellation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["returnToday"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["returnToday"].label, "Сегодня")
        let initial = try XCTUnwrap(app.buttons["returnToday"].value as? String)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = try XCTUnwrap(formatter.date(from: initial))
        waitForPage(app)
        for offset in [1, 2, 3] {
            app.swipeLeft(); waitForPage(app)
            let expected = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            XCTAssertEqual(app.buttons["returnToday"].value as? String, formatter.string(from: expected))
        }
        app.buttons["returnToday"].tap(); waitForPage(app)
        XCTAssertEqual(app.buttons["returnToday"].value as? String, initial)
        // Neighbours must remain correct after a non-adjacent animated jump.
        app.swipeLeft(); waitForPage(app)
        XCTAssertEqual(app.buttons["returnToday"].label, "Завтра")
        app.swipeLeft(); waitForPage(app)
        app.swipeLeft(); waitForPage(app)
        for offset in [2, 1, 0, -1] {
            app.swipeRight(); waitForPage(app)
            let expected = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            XCTAssertEqual(app.buttons["returnToday"].value as? String, formatter.string(from: expected))
        }
        XCTAssertEqual(app.buttons["returnToday"].label, "Вчера")
        let before = app.buttons["returnToday"].value as? String
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -25, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForPage(app)
        XCTAssertEqual(app.buttons["returnToday"].value as? String, before)
        app.buttons["returnToday"].tap(); waitForPage(app)
        XCTAssertEqual(app.buttons["returnToday"].value as? String, initial)
        XCTAssertEqual(app.buttons["returnToday"].label, "Сегодня")
        let streakFrame = app.buttons["streak"].frame
        XCTAssertEqual(app.buttons["returnToday"].frame.midY, streakFrame.midY, accuracy: 3)
        let resting = XCTAttachment(screenshot: app.screenshot())
        resting.name = "Шапка без прокрутки"; resting.lifetime = .keepAlways; add(resting)
        let headerY = app.buttons["returnToday"].frame.minY
        app.swipeUp()
        XCTAssertEqual(app.buttons["returnToday"].frame.minY, headerY, accuracy: 1,
                       "Дата должна оставаться поверх содержимого")
        XCTAssertTrue(app.buttons["returnToday"].exists)
        XCTAssertTrue(app.buttons["returnToday"].isEnabled)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "Плавающие элементы после прокрутки"; scrolled.lifetime = .keepAlways; add(scrolled)
        XCTAssertTrue(app.buttons["streak"].isHittable)
        XCTAssertEqual(app.buttons["streak"].frame.minY, streakFrame.minY, accuracy: 1)
        app.buttons["streak"].tap()
        XCTAssertTrue(app.staticTexts["Серия: 0"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Календарь и серия"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.datePickers["diaryCalendar"].exists)
        app.buttons["calendarToday"].tap()
        XCTAssertEqual(app.buttons["returnToday"].label, "Сегодня")
    }

    private func waitForPage(_ app: XCUIApplication) {
        let ready = NSPredicate(format: "enabled == true AND hittable == true")
        expectation(for: ready, evaluatedWith: app.buttons["recordMeal"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["closeMeal"].exists, "Свайп не должен открывать добавление еды")
    }

    private func smallScroll(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }

}
