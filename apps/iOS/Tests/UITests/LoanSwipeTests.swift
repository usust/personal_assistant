import XCTest

/// 使用后端计算器导出的只读样本，验证真实左滑及独立预览；不登录、不保存真实账户。
@MainActor final class LoanSwipeTests: XCTestCase {
    /// 验证单一卡堆、前后卡槽位交换和右侧滑出菜单；参数：无；返回值：无，仅操作预览虚构资料，不联网或写真实账本。
    func testCardWallet() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--wallet-ui"]
        app.launch()
        let card = app.buttons["wallet-card-preview-one"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        attach(app, name: "wallet-stack")
        let visa = app.buttons["wallet-card-preview-three"]
        let front = app.buttons["wallet-card-preview-four"]
        let middle = app.buttons["wallet-card-preview-two"]
        let rearY = visa.frame.minY
        let frontY = front.frame.minY
        let middleY = middle.frame.minY
        let firstY = card.frame.minY
        XCTAssertEqual(front.value as? String, "已选中")
        visa.tap()
        XCTAssertEqual(visa.value as? String, "已选中")
        waitForCardSlot(visa, y: frontY)
        XCTAssertEqual(front.frame.minY, rearY, accuracy: 1)
        XCTAssertEqual(middle.frame.minY, middleY, accuracy: 1)
        XCTAssertEqual(card.frame.minY, firstY, accuracy: 1)
        XCTAssertEqual(app.buttons.matching(identifier: "wallet-card-preview-three").count, 1)
        // 再次交换验证槽位稳定；输入为第一张后层卡，返回无，其他后层卡不移动。
        card.tap()
        XCTAssertEqual(card.value as? String, "已选中")
        waitForCardSlot(card, y: frontY)
        XCTAssertEqual(visa.frame.minY, firstY, accuracy: 1)
        XCTAssertEqual(middle.frame.minY, middleY, accuracy: 1)
        XCTAssertEqual(front.frame.minY, rearY, accuracy: 1)
        visa.tap()
        XCTAssertEqual(visa.value as? String, "已选中")
        XCTAssertFalse(app.staticTexts["账单下的卡片"].exists)
        XCTAssertFalse(app.buttons["编辑卡片"].exists)
        XCTAssertFalse(app.buttons["更换卡面"].exists)
        XCTAssertTrue(app.buttons["添加卡片"].exists)
        XCTAssertGreaterThan(app.buttons["添加卡片"].frame.minY, visa.frame.maxY)
        visa.swipeLeft()
        XCTAssertTrue(app.buttons["编辑卡片"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["编辑卡片"].frame.midY, app.buttons["删除卡片"].frame.midY)
        XCTAssertEqual(app.buttons["编辑卡片"].frame.midX, app.buttons["删除卡片"].frame.midX, accuracy: 2)
        XCTAssertLessThan(app.buttons["查看卡号"].frame.midY, app.buttons["编辑卡片"].frame.midY)
        attach(app, name: "wallet-swipe-menu")
        visa.swipeRight()
        XCTAssertFalse(app.buttons["编辑卡片"].exists)
        visa.swipeLeft()
        middle.tap()
        XCTAssertFalse(app.buttons["编辑卡片"].exists)
        visa.tap()
        XCTAssertTrue(visa.label.contains("**** 9012"))
        XCTAssertFalse(visa.label.contains("0000"))
        visa.swipeLeft()
        app.buttons["查看卡号"].tap()
        XCTAssertFalse(app.navigationBars["查看卡片"].exists)
        XCTAssertTrue(visa.label.contains("0000 0000 0000 9012"))
        XCTAssertFalse(app.buttons["编辑卡片"].exists)
        visa.swipeLeft()
        app.buttons["隐藏卡号"].tap()
        XCTAssertTrue(visa.label.contains("**** 9012"))
        visa.swipeLeft()
        app.buttons["查看卡号"].tap()
        middle.tap()
        XCTAssertFalse(visa.label.contains("0000"))
        middle.swipeLeft()
        app.buttons["查看卡号"].tap()
        XCTAssertFalse(app.navigationBars["查看卡片"].exists)
        XCTAssertTrue(middle.label.contains("**** 5678"))
        visa.tap()
        visa.swipeLeft()
        app.buttons["编辑卡片"].tap()
        XCTAssertTrue(app.textFields["卡片名称"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["卡片名称"].value as? String, "VISA全币种国际信用卡")
        XCTAssertFalse(app.staticTexts["编辑卡片"].exists)
        XCTAssertTrue(app.textFields["卡号或后四位"].isHittable)
        attach(app, name: "wallet-compact-editor")
        app.textFields["卡号或后四位"].tap()
        XCTAssertTrue(app.buttons["完成"].isHittable)
        XCTAssertTrue(app.textFields["卡号或后四位"].isHittable)
        attach(app, name: "wallet-compact-editor-keyboard")
        app.buttons["完成"].tap()
        app.buttons["添加卡片"].tap()
        XCTAssertTrue(app.textFields["卡片名称"].waitForExistence(timeout: 5))
        let input = app.textFields["卡号或后四位"]
        input.tap()
        input.typeText("1234567890123456")
        XCTAssertEqual(input.value as? String, "1234 5678 9012 3456")
    }
    /// 等待交换动画到达固定槽位；参数：card 为目标卡片按钮，y 为槽位纵坐标；返回值：无，超时记录测试失败。
    private func waitForCardSlot(_ card: XCUIElement, y: CGFloat) {
        // 谓词输入测试对象与上下文（不使用），返回是否到位，避免读取动画中的临时坐标。
        let settled = NSPredicate { _, _ in abs(card.frame.minY - y) < 1 }
        expectation(for: settled, evaluatedWith: card)
        waitForExpectations(timeout: 5)
    }
    /// 验证截图记账入口、独立教程；参数：无；返回值：无，只在隔离空白模拟器运行，不外发图片或写入交易。
    func testScreenshotBookkeepingSetup() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["添加账户"].waitForExistence(timeout: 15))
        app.tabBars.buttons["设置"].tap()
        XCTAssertFalse(app.buttons["图片记账"].exists)
        XCTAssertTrue(app.buttons["截图记账"].exists)
        app.tabBars.buttons["财务"].tap()
        app.buttons["财务管理"].tap()
        app.buttons["图片记账"].tap()
        XCTAssertTrue(app.navigationBars["图片记账"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["登录以使用 AI"].exists)
        XCTAssertTrue(app.buttons["从相册选择图片"].exists)
        XCTAssertFalse(app.buttons["从相册选择图片"].isEnabled)
        XCTAssertTrue(app.staticTexts["暂无图片记录"].exists)
        attach(app, name: "screenshot-bookkeeping-settings")
        app.buttons["AI 设置"].tap()
        XCTAssertTrue(app.navigationBars["图片记账设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["登录以使用 AI"].exists)
        XCTAssertFalse(app.buttons["同意外发并启用"].exists)
        XCTAssertFalse(app.buttons["截图记账"].exists)
        app.tabBars.buttons["设置"].tap()
        app.buttons["截图记账"].tap()
        XCTAssertTrue(app.navigationBars["截图记账"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "轻点两下")).firstMatch.exists)
        attach(app, name: "screenshot-back-tap-guide")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["截图记账"].waitForExistence(timeout: 5))
    }

    /// 验证游客可直接进入财务且同步入口只要求认证；参数：无；返回值：无，需在专用空白模拟器运行，不操作真实账本。
    func testGuestFinanceAndSyncEntry() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["添加账户"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.secureTextFields["密码"].exists)
        app.tabBars.buttons["用户"].tap()
        XCTAssertTrue(app.staticTexts["本机账本"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "同步")).firstMatch.tap()
        XCTAssertTrue(app.secureTextFields["密码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["账号"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["未开启"].waitForExistence(timeout: 5))
        attach(app, name: "guest-one-tap-sync")
    }

    /// 验证已还筛选最近期次在前且倒序后侧滑仍对应正确期次；参数：无；返回值：无，仅操作只读样本并保留截图。
    func testPaidPeriodsNewestFirst() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--tab", "finance", "--loan-ui", "--loan-plan"]
        app.launch()
        XCTAssertTrue(app.navigationBars["贷款计划"].waitForExistence(timeout: 15))
        let paid = app.segmentedControls.buttons["已还"]
        for _ in 0..<4 {
            if paid.isHittable { break }
            app.swipeUp()
        }
        paid.tap()
        let latest = app.staticTexts["第 47 期"]
        let previous = app.staticTexts["第 46 期"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            if previous.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(latest.isHittable)
        XCTAssertTrue(previous.isHittable)
        XCTAssertLessThan(latest.frame.minY, previous.frame.minY)
        attach(app, name: "paid-newest-first")
        let row = app.cells.containing(.staticText, identifier: "第 47 期").firstMatch
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        app.buttons["金额"].tap()
        XCTAssertTrue(app.staticTexts["本期按账单校准，后续按年利率重算。"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
    }

    /// 验证已还期次左滑利率入口与三期预览；参数：无；返回值：无，截图写测试产物。
    func testPaidRateSwipeAndPreview() {
        verifySwipe(period: 1, kind: "rate", paid: true)
    }

    /// 验证待还筛选后金额入口和期次绑定；参数：无；返回值：无，不执行真实写入。
    func testUnpaidAmountSwipeAndPreview() {
        verifySwipe(period: 48, kind: "payment", paid: false)
    }

    /// 启动样本并验证所选分期的独立表单；参数：period 为生效期，kind 为 rate 或 payment，paid 控制筛选；返回值：无，异常中止当前测试。
    private func verifySwipe(period: Int, kind: String, paid: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--tab", "finance", "--loan-ui", "--loan-plan"]
        app.launch()
        XCTAssertTrue(app.navigationBars["贷款计划"].waitForExistence(timeout: 15))
        let selector = app.segmentedControls.buttons["待还"]
        for _ in 0..<4 {
            if selector.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(selector.isHittable)
        XCTAssertTrue(app.segmentedControls.buttons["已还"].exists)
        XCTAssertFalse(app.staticTexts["计划已还"].exists)
        if !paid { selector.tap() }
        let row = app.cells.containing(.staticText, identifier: "第 \(period) 期").firstMatch
        for _ in 0..<4 {
            if row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["金额"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["利率"].exists)
        attach(app, name: "period-\(period)-swipe")
        app.buttons[kind == "rate" ? "利率" : "金额"].tap()
        XCTAssertTrue(app.navigationBars[kind == "rate" ? "调整利率" : "调整金额"].waitForExistence(timeout: 5))
        let scope = kind == "rate" ? "从第 \(period) 期起调整利率，此前各期保持不变。" : "本期按账单校准，后续按年利率重算。"
        XCTAssertTrue(app.staticTexts[scope].exists)
        XCTAssertFalse(app.navigationBars.buttons["保存"].isEnabled)
        let input = app.textFields[kind == "rate" ? "loan-adjustment-rate" : "loan-adjustment-payment"]
        XCTAssertTrue(input.exists)
        XCTAssertTrue(app.textFields["loan-adjustment-rate"].exists)
        if kind == "rate" { XCTAssertFalse(app.textFields["loan-adjustment-payment"].exists) }
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let current = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + (kind == "rate" ? "3" : "1000"))
        XCTAssertEqual(input.value as? String, kind == "rate" ? "3" : "1000")
        app.buttons["预览调整结果"].tap()
        XCTAssertTrue(app.staticTexts["调整后近 3 期"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["保存"].isEnabled)
        // 纵向滚动仍可操作，并且只展示所选期次起三期；最后一张滚入屏幕后再截图。
        for _ in 0..<4 {
            if app.staticTexts["第 \(period + 2) 期"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["第 \(period + 2) 期"].isHittable)
        XCTAssertFalse(app.staticTexts["第 \(period + 3) 期"].exists)
        if kind == "payment" {
            XCTAssertTrue(app.staticTexts["¥1,000.00"].exists)
            XCTAssertTrue(app.staticTexts["¥851.68"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts["每期本息"].exists)
        }
        attach(app, name: "period-\(period)-preview")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["贷款计划"].exists)
    }

    /// 保留阶段截图；参数：app 为样本应用，name 为截图名称；返回值：无，只写 xcresult。
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
