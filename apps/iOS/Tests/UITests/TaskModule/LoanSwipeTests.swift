import XCTest

extension LoanSwipeTests {
    /// 验证 More 内一级和二级导航一致；参数：无；返回值：无；仅访问只读预览，检查单层栏、可用返回及模型服务样本，不保存或调用 AI。
    func testVisualMoreNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--tab", "chat"]
        app.launch()
        XCTAssertTrue(app.navigationBars["助手"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["返回更多页面"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 1)
        app.buttons["返回更多页面"].tap()
        let settings = app.staticTexts["设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["返回更多页面"].waitForExistence(timeout: 5))
        app.buttons["模型服务"].tap()
        XCTAssertTrue(app.buttons["添加模型服务"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["日常助手"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 1)
        XCTAssertFalse(app.buttons["返回更多页面"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["返回更多页面"].waitForExistence(timeout: 5))
        app.buttons["返回更多页面"].tap()
        XCTAssertTrue(app.staticTexts["助手"].firstMatch.waitForExistence(timeout: 5))
    }
}

extension LoanSwipeTests {
    /// 验证普通及多行输入的焦点切换与外部收键盘；参数：无；返回值：无；只编辑虚构任务草稿，点击输入内部继续编辑、点击分组标题结束编辑且保留文本。
    func testKeyboardDismissalOutsideAndFieldSwitching() {
        let app = launch("v4")
        app.buttons["新建任务"].tap()
        let name = app.textFields["名称"].firstMatch
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["基本信息"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        name.tap()
        name.typeText("键盘草稿")
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        // 浮动标签位于系统输入框上方，整块输入区域仍应维持焦点，不被误认为外部点击。
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let remark = app.textFields["备注"].exists ? app.textFields["备注"].firstMatch : app.textViews["备注"].firstMatch
        remark.tap()
        remark.typeText("第一行\n第二行")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(name.value as? String, "键盘草稿")
        app.staticTexts["基本信息"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(remark.value as? String, "第一行\n第二行")
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// 验证数字键盘外部点击与按钮透传；参数：无；返回值：无；仅修改虚构进度草稿，增量按钮必须一次生效并收起键盘，不保存业务数据。
    func testKeyboardDismissalNumberPadAndButton() {
        let app = launch("v4")
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        let increment = button(app, "目标总量.stepper-Increment")
        let total = app.textFields["目标总量"].firstMatch
        total.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["编辑任务"].staticTexts["编辑任务"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(total.value as? String, "10")
        total.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        increment.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(total.value as? String, "11")
        app.buttons["取消"].tap()
    }

    /// 验证导航后的清单面板复用窗口收键盘及业务点击；参数：无；返回值：无；只输入清单草稿，点击颜色仍选中颜色且结束编辑，取消不持久化。
    func testKeyboardDismissalNestedSheet() {
        let app = launch("v4")
        app.navigationBars.buttons["我的清单"].tap()
        app.buttons["新建清单"].tap()
        let name = app.textFields["清单名称"].firstMatch
        name.tap()
        name.typeText("嵌套面板草稿")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["新建清单"].staticTexts["新建清单"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "嵌套面板草稿")
        name.tap()
        let color = app.buttons["颜色 #EF4444"]
        color.tap()
        XCTAssertTrue(color.isSelected)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "嵌套面板草稿")
        app.buttons["取消"].tap()
    }

    /// 验证系统搜索框也能外部结束编辑；参数：无；返回值：无；查询与过滤结果保留，重新点击搜索框继续输入，不修改任务。
    func testKeyboardDismissalSearch() {
        let app = launch("v4")
        app.navigationBars.buttons["我的清单"].tap()
        let search = app.searchFields.firstMatch
        // 系统导航栏搜索默认随列表收起；向下展开后才访问输入框，不假定存在独立搜索按钮。
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("工作")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["工作"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "工作")
        XCTAssertTrue(app.staticTexts["工作"].exists)
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        search.typeText("计划")
        XCTAssertEqual(search.value as? String, "工作计划")
    }

    /// 验证 UIKit 卡号输入和卡片手势兼容；参数：无；返回值：无；仅操作虚构钱包，数字键盘可外部收起、分组格式保持、完成按钮仍关闭面板。
    func testKeyboardDismissalCardNumber() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--wallet-ui"]
        app.launch()
        let card = app.buttons["wallet-card-preview-three"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        card.swipeLeft()
        app.buttons["编辑卡片"].tap()
        let number = app.textFields["卡号或后四位"]
        number.tap()
        let originalLength = (number.value as? String ?? "").count
        number.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalLength) + "1234567890123456")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // 使用编辑面板的导航栏，避免误点底层钱包导航栏而触发系统 sheet 外部关闭。
        app.navigationBars.containing(.button, identifier: "完成").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(number.value as? String, "1234 5678 9012 3456")
        number.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(number.exists)
    }

    /// 验证模型服务的密码与 URL 输入可统一结束编辑；参数：无；返回值：无；使用只读预览和虚构密钥，不保存、不发起模型请求。
    func testKeyboardDismissalSecureAndURLFields() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--preview", "--tab", "settings"]
        app.launch()
        let services = app.buttons["模型服务"]
        XCTAssertTrue(services.waitForExistence(timeout: 15))
        services.tap()
        app.buttons["添加模型服务"].tap()
        let address = app.textFields["API 地址"].firstMatch
        address.tap()
        address.typeText("https://example.test/api")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["添加模型服务"].staticTexts["添加模型服务"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "https://example.test/api")
        let key = app.secureTextFields["API Key"].firstMatch
        key.tap()
        key.typeText("preview-only")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["添加模型服务"].staticTexts["添加模型服务"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        key.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
    }
}

/// 独立验收任务模块，只使用 Debug 内存样本；不登录真实账号或访问服务器。
@MainActor final class LoanSwipeTests: XCTestCase {
    /// 启动场景；参数 scenario 为固定场景名；返回独立启动的应用，进程重启清空样本。
    func launch(_ scenario: String = "normal") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments = ["--task-ui-scenario", scenario, "--tab", "tasks"]
        app.launch()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 15))
        return app
    }
    /// 保存截图与可访问树；参数 app 为被验收应用、name 为唯一名字；返回无，仅写测试附件和临时目录。
    func capture(_ app: XCUIApplication, _ name: String) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/task-module-after/" + name + ".png"))
        try? app.debugDescription.write(toFile: "/private/tmp/task-module-after/" + name + ".txt", atomically: true, encoding: .utf8)
    }
    /// 滚动至按钮；参数 app 为应用、label 为精确按钮名称；返回按钮；最多滚动六次，找不到则失败。
    func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let element = app.buttons[label].firstMatch
        for _ in 0..<6 { if element.exists && element.isHittable { return element }; app.swipeUp() }
        XCTAssertTrue(element.exists, label)
        return element
    }
    /// 返回任务列表；参数 app 为应用；返回无；仅在详情页调用。
    func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    /// 输入字段；参数 app、label、value 分别为应用、字段名及虚构测试文本；返回无，保留其他草稿。
    func enter(_ app: XCUIApplication, _ label: String, _ value: String) {
        let field = app.textFields[label].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), label)
        field.tap(); field.typeText(value)
    }
    /// 验证页面、主任务隐藏配置及叶任务保留配置；参数无；返回无，保存页面截图。
    func testPagesAndConfiguration() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["为新的一周留点空间"].waitForExistence(timeout: 10)); capture(app, "iphone-tasks-list")
        app.staticTexts["为新的一周留点空间"].tap()
        XCTAssertTrue(app.staticTexts["安排"].exists); capture(app, "iphone-tasks-detail")
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["编辑任务"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["进度配置"].exists); capture(app, "iphone-tasks-edit")
        app.buttons["取消"].tap(); back(app)
        app.buttons["新建任务"].tap()
        XCTAssertTrue(app.navigationBars["新建任务"].waitForExistence(timeout: 5)); capture(app, "iphone-tasks-new")
        app.swipeUp(); XCTAssertTrue(app.staticTexts["进度配置"].exists)
        app.buttons["取消"].tap(); app.buttons["清单"].tap()
        XCTAssertTrue(app.staticTexts["日常与成长"].waitForExistence(timeout: 5)); capture(app, "iphone-task-lists")
    }
    /// 验证父归档后活跃子任务仍可到达与恢复去重；参数无；返回无，仅更改内存样本。
    func testArchiveRootReachability() {
        let app = launch(); app.staticTexts["为新的一周留点空间"].tap()
        button(app, "归档任务").tap(); back(app)
        XCTAssertTrue(app.staticTexts["读完《设计心理学》第三章"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "读完《设计心理学》第三章")).count, 1)
        capture(app, "iphone-parent-archived-child-visible")
        app.buttons["已归档"].tap(); app.staticTexts["为新的一周留点空间"].tap()
        button(app, "恢复任务").tap(); back(app); app.segmentedControls.buttons["任务"].tap()
        XCTAssertTrue(app.staticTexts["为新的一周留点空间"].exists)
        XCTAssertFalse(app.staticTexts["读完《设计心理学》第三章"].exists)
    }
    /// 验证初载失败与无清单状态；参数无；返回无，错误不混同正常空态。
    func testLoadErrorAndEmpty() {
        let app = launch("load-error")
        XCTAssertTrue(app.buttons["重新加载"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["创建第一个清单"].exists); capture(app, "iphone-load-error")
        app.terminate()
        let empty = launch("empty")
        XCTAssertTrue(empty.staticTexts["创建第一个清单"].waitForExistence(timeout: 5))
        XCTAssertFalse(empty.buttons["新建任务"].isEnabled); capture(empty, "iphone-empty")
        empty.buttons["新建清单"].tap()
        XCTAssertTrue(empty.navigationBars["我的清单"].waitForExistence(timeout: 5))
    }
    /// 验证明确业务拒绝不锁写、保留任务草稿；参数无；返回无，样本不落库。
    func testBusinessRejectionKeepsDraft() {
        let app = launch("write-error"); app.buttons["新建任务"].tap()
        enter(app, "任务名称", "拒绝后草稿保留")
        app.buttons["保存"].tap()
        capture(app, "submit-" + name)
        XCTAssertTrue(app.staticTexts["错误：示例业务拒绝，请调整后重试。"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["任务名称"].value as? String, "拒绝后草稿保留")
        XCTAssertTrue(app.buttons["保存"].isEnabled); capture(app, "iphone-write-rejected")
        app.buttons["取消"].tap(); XCTAssertTrue(app.buttons["新建任务"].isEnabled)
    }
    /// 验证成功刷新失败的共享写保护；参数无；返回无，跨页面后仅重读解除保护。
    func testRefreshFailureBlocksAcrossPages() {
        let app = launch("refresh-error"); app.staticTexts["整理本月订阅与开销"].tap()
        button(app, "增加").tap()
        XCTAssertFalse(button(app, "增加").isEnabled)
        capture(app, "iphone-saved-refresh-failed")
        back(app); XCTAssertFalse(app.buttons["新建任务"].isEnabled)
        app.buttons["清单"].tap(); XCTAssertFalse(app.buttons["新建清单"].isEnabled)
        capture(app, "iphone-shared-write-protection")
        app.buttons["完成"].tap(); app.staticTexts["整理本月订阅与开销"].tap()
        XCTAssertFalse(button(app, "增加").isEnabled)
        button(app, "刷新任务").tap()
        XCTAssertTrue(button(app, "增加").isEnabled)
        app.swipeDown(); XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "3 / 10")).firstMatch.exists)
        capture(app, "iphone-retry-read-recovered")
    }
    /// 验证创建响应丢失不重发；参数无；返回无，刷新后只有一个已创建样本。
    func testLostCreateResponseNoDuplicate() {
        let app = launch("lost-response-read-error"); app.buttons["新建任务"].tap()
        enter(app, "任务名称", "唯一创建样本")
        app.buttons["保存"].tap()
        capture(app, "submit-" + name)
        XCTAssertTrue(app.staticTexts["错误：创建结果未确认。请关闭此表单并刷新列表，确认后再创建。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["保存"].isEnabled); capture(app, "iphone-create-response-lost")
        app.buttons["取消"].tap(); XCTAssertFalse(app.buttons["新建任务"].isEnabled)
        app.buttons["刷新任务"].tap()
        XCTAssertFalse(app.buttons["新建任务"].isEnabled)
        XCTAssertTrue(app.staticTexts["错误：操作结果未确认，请刷新后检查任务，避免重复提交。"].exists)
        XCTAssertFalse(app.staticTexts["错误：已保存，最新数据加载失败。请刷新后继续。"].exists)
        app.buttons["刷新任务"].tap()
        XCTAssertFalse(app.buttons["新建任务"].isEnabled)
        app.buttons["刷新任务"].tap()
        XCTAssertTrue(app.staticTexts["唯一创建样本"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "唯一创建样本").count, 1)
        XCTAssertTrue(app.buttons["新建任务"].isEnabled); capture(app, "iphone-create-confirmed-on-read")
    }
    /// 验证非首清单继承与删除后筛选回总览；参数无；返回无，仅创建及删除内存清单任务。
    func testSelectedListCreateAndDelete() {
        let app = launch()
        app.buttons["清单、全部清单"].tap(); app.buttons["工作计划"].tap()
        XCTAssertTrue(app.buttons["清单、工作计划"].exists)
        app.navigationBars.buttons["新建任务"].tap()
        XCTAssertTrue(app.buttons["清单、工作计划"].exists)
        enter(app, "任务名称", "非首清单任务")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["非首清单任务"].waitForExistence(timeout: 5))
        app.staticTexts["非首清单任务"].tap()
        capture(app, "selected-list-detail-tree")
        capture(app, "iphone-selected-list-created"); back(app)
        app.navigationBars.buttons["清单"].tap()
        let row = app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "工作计划")).firstMatch
        row.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts["删除清单？"].waitForExistence(timeout: 5))
        app.alerts.buttons["删除"].tap()
        XCTAssertFalse(app.staticTexts["工作计划"].exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["清单、全部清单"].exists)
        XCTAssertFalse(app.staticTexts["非首清单任务"].exists)
        capture(app, "iphone-deleted-selected-list")
    }
    /// 验证实际删除主任务会级联并返回列表；参数无；返回无，删除的仅为内存样本。
    func testCascadeDeletion() {
        let app = launch();app.staticTexts["为新的一周留点空间"].tap()
        button(app, "删除任务").tap()
        app.buttons["删除任务及子任务"].tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["为新的一周留点空间"].exists)
        let search = app.searchFields.firstMatch
        if search.exists { search.tap();search.typeText("设计心理学");XCTAssertFalse(app.staticTexts["读完《设计心理学》第三章"].exists) }
        capture(app,"iphone-cascade-deleted")
    }
    /// 只读日期布局验收入口；参数：无；返回值：无；使用 v4 虚构样本检查首页、清单筛选及今日复用行的起止日期时间，记录截图，外观及字号由外部模拟器控制，不写真实服务器。
    func testLayoutSnapshot() {
        let app = launch("v4")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "阅读设计规范")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("开始："))
        XCTAssertTrue(row.label.contains("结束："))
        XCTAssertTrue(row.label.contains("18:30"))
        capture(app, "date-single-line-tree")
        app.buttons["taskListSwitcher"].tap()
        app.buttons["工作"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "date-single-line-list")
        app.buttons["今日"].tap()
        XCTAssertTrue(app.staticTexts["今日专注"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["阅读设计规范"].exists)
        capture(app, "date-single-line-today")
    }

    /// 滚动并操作表单开关；参数为应用与标签；返回无，最多六次滚动。
    func toggle(_ app:XCUIApplication,_ label:String) {
        let item=app.switches[label].firstMatch
        for _ in 0..<6 { if item.exists && item.frame.midY > 150 && item.frame.midY < app.frame.height - 150 { item.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap();return }; if item.exists && item.frame.midY < 150 { app.swipeDown() } else { app.swipeUp() } }
        XCTFail("开关不可达："+label)
    }
    /// 切换实际原生开关子节点；参数为应用与标签；返回无，按元素几何有界滚动。
    func nativeToggle(_ app:XCUIApplication,_ label:String) {
        let item=app.switches[label].firstMatch
        for _ in 0..<8 {
            if item.exists && item.frame.midY > 170 && item.frame.midY < app.frame.height-160 { item.descendants(matching:.switch).firstMatch.tap();return }
            let up = item.frame.midY >= app.frame.height-160
            app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:up ? 0.65:0.40)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:up ? 0.40:0.65)))
        }
        XCTFail("原生开关未到可见范围："+label)
    }
    /// 验证同日逆序、正确保存和清空日期；参数无；返回无，仅操作虚构样本。
    func testDateTimeOrdering() throws {
        let app=launch();app.staticTexts["整理本月订阅与开销"].tap();app.buttons["编辑"].tap()
        nativeToggle(app,"指定开始时间")
        app.buttons["Time Picker"].firstMatch.tap()
        app.pickerWheels.element(boundBy:0).adjust(toPickerWheelValue:"18")
        app.navigationBars["编辑任务"].tap()
        nativeToggle(app,"指定截止时间")
        capture(app,"iteration6-reversed-time")
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        nativeToggle(app,"指定开始时间")
        XCTAssertTrue(app.buttons["保存"].isEnabled)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout:5))
        capture(app,"iteration6-date-saved")
        app.buttons["编辑"].tap();nativeToggle(app,"设置开始日期");nativeToggle(app,"设置截止日期")
        app.buttons["保存"].tap();app.buttons["编辑"].tap()
        XCTAssertEqual(app.switches["设置开始日期"].firstMatch.value as? String,"0")
        XCTAssertEqual(app.switches["设置截止日期"].firstMatch.value as? String,"0")
        nativeToggle(app,"设置开始日期");nativeToggle(app,"设置截止日期")
        XCTAssertEqual(app.switches["指定开始时间"].firstMatch.value as? String,"0")
        XCTAssertEqual(app.switches["指定截止时间"].firstMatch.value as? String,"0")
        capture(app,"iteration6-cleared-dates-reopened")
    }
    /// 验证辅助字号元信息与复用入口；参数无；返回无，仅截图与读取可访问树；字体/外观由专用模拟器配置。
    func testAccessibleMetadataLayout() {
        let app=launch();XCTAssertTrue(app.staticTexts["为新的一周留点空间"].waitForExistence(timeout:5))
        capture(app,"iteration2-list-initial")
        app.swipeUp();capture(app,"iteration2-list-scrolled")
        let row=app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "为新的一周留点空间")).firstMatch
        XCTAssertTrue(row.label.contains("高优先级"));XCTAssertTrue(row.label.contains("2026"));XCTAssertTrue(row.label.contains("40%"))
        row.tap();app.swipeUp();capture(app,"iteration2-detail")
        app.terminate();app.launchArguments=["--task-ui-scenario","normal","--tab","today"];app.launch()
        XCTAssertTrue(app.staticTexts["今日专注"].waitForExistence(timeout:10));app.swipeUp();capture(app,"iteration2-today")
    }

    /// 启动今日专项场景；参数为固定场景名；返回隔离内存应用，不发真实请求。
    func launchToday(_ scenario:String) -> XCUIApplication {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"personalassistant.lylab.vip.PersonalAssistant")
        app.launchArguments=["--task-ui-scenario",scenario,"--tab","today"];app.launch()
        XCTAssertTrue(app.navigationBars["今日"].waitForExistence(timeout:15));return app
    }
    /// 验证任务首次失败不假空且财务正常；参数无；返回无，重试只读任务。
    func testTodayTaskErrorFinanceSuccess() {
        let app=launchToday("today-task-error")
        XCTAssertTrue(app.staticTexts["错误：任务：示例加载失败。"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["今天的安排，由你定义。"].exists)
        XCTAssertFalse(app.buttons["先创建一个清单"].exists)
        XCTAssertTrue(app.staticTexts["财务一瞥"].exists)
        XCTAssertFalse(app.buttons["添加任务"].isEnabled)
        capture(app,"today-task-error")
        button(app,"刷新任务").tap()
        XCTAssertTrue(app.staticTexts["错误：任务：示例加载失败。"].exists)
        XCTAssertTrue(app.staticTexts["财务一瞥"].exists)
    }
    /// 验证财务失败与任务分离；参数无；返回无，任务可操作，财务错误不混同任务错误。
    func testTodayFinanceErrorTasksSuccess() {
        let app=launchToday("today-finance-error")
        XCTAssertTrue(app.staticTexts["整理本月订阅与开销"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["错误：财务：示例加载失败。"].exists)
        XCTAssertFalse(app.staticTexts["错误：任务：示例加载失败。"].exists)
        XCTAssertTrue(app.buttons["添加任务"].isEnabled)
        capture(app,"today-finance-error")
    }
    /// 验证已确认空任务与无清单不同入口；参数无；返回无，不将加载失败当作可创建状态。
    func testTodayEmptyStates() {
        let app=launchToday("today-empty-list")
        XCTAssertTrue(app.staticTexts["今天的安排，由你定义。"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["添加任务"].isEnabled)
        XCTAssertFalse(app.buttons["先创建一个清单"].exists);capture(app,"today-empty-tasks")
        app.terminate();let empty=launchToday("empty")
        XCTAssertTrue(empty.buttons["先创建一个清单"].waitForExistence(timeout:5))
        XCTAssertFalse(empty.buttons["添加任务"].isEnabled);capture(empty,"today-empty-lists")
        empty.buttons["先创建一个清单"].tap()
        XCTAssertTrue(empty.navigationBars["我的清单"].waitForExistence(timeout:5))
    }
    /// 验证详情写后刷新失败回今日保持旧任务与共享锁；参数无；返回无，完整重读后解除。
    func testTodaySharedProtectionAndCache() {
        let app=launchToday("refresh-error")
        app.staticTexts["整理本月订阅与开销"].tap()
        button(app,"增加").tap();back(app)
        XCTAssertTrue(app.staticTexts["整理本月订阅与开销"].exists)
        XCTAssertFalse(app.buttons["添加任务"].isEnabled)
        XCTAssertEqual(app.staticTexts.matching(identifier:"错误：已保存，最新数据加载失败。请刷新后继续。").count,1)
        capture(app,"today-cache-write-protection")
        button(app,"刷新任务").tap()
        XCTAssertTrue(app.buttons["添加任务"].isEnabled)
        XCTAssertFalse(app.staticTexts["错误：已保存，最新数据加载失败。请刷新后继续。"].exists)
        capture(app,"today-cache-recovered")
    }

    /// 检查今日任务错误大字号布局；参数无；返回无，外部配置深色最大字号后只读检查。
    func testTodayErrorLayout() {
        let app=launchToday("today-task-error")
        XCTAssertTrue(app.staticTexts["错误：任务：示例加载失败。"].waitForExistence(timeout:5))
        _ = button(app,"刷新任务")
        capture(app,"today-error-accessible")
        XCTAssertTrue(app.buttons["刷新任务"].isEnabled)
    }

    /// 验证空清单入口共享保护；参数无；返回无，使用现有样本和读取失败，不写真实账号。
    func testEmptyEntryWriteProtection() {
        let app=launch("refresh-error")
        app.buttons["清单、全部清单"].tap();app.buttons["工作计划"].tap()
        XCTAssertTrue(app.staticTexts["暂无任务"].exists)
        let entry=app.buttons.matching(identifier:"新建任务").matching(NSPredicate(format:"enabled == true")).firstMatch
        XCTAssertTrue(entry.exists);capture(app,"iteration5-empty-enabled");entry.tap()
        XCTAssertTrue(app.navigationBars["新建任务"].waitForExistence(timeout:5));app.buttons["取消"].tap()
        app.buttons["清单、工作计划"].tap();app.buttons["全部清单"].tap()
        app.staticTexts["整理本月订阅与开销"].tap();button(app,"增加").tap();back(app)
        app.buttons["清单、全部清单"].tap();app.buttons["工作计划"].tap()
        XCTAssertTrue(app.staticTexts["暂无任务"].exists)
        for entry in app.buttons.matching(identifier:"新建任务").allElementsBoundByIndex { XCTAssertFalse(entry.isEnabled) }
        capture(app,"iteration5-empty-blocked")
        app.buttons["刷新任务"].tap()
        XCTAssertTrue(app.buttons.matching(identifier:"新建任务").matching(NSPredicate(format:"enabled == true")).firstMatch.waitForExistence(timeout:5))
        capture(app,"iteration5-empty-recovered")
    }

    /// 验证v4六页面与类型边界；参数无；返回无，隔离样本不代表真实后端联调。
    func testV4Pages() {
        let app=launch("v4");capture(app,"v4-root")
        app.staticTexts["工作"].tap();XCTAssertTrue(app.navigationBars["工作"].waitForExistence(timeout:5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture(app,"v4-tree")
        app.staticTexts["设计准备"].tap();XCTAssertTrue(app.navigationBars["主任务详情"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","6 / 11")).firstMatch.exists)
        capture(app,"v4-main-detail")
        app.buttons["编辑"].tap();XCTAssertTrue(app.navigationBars["编辑主任务"].waitForExistence(timeout:5));capture(app,"v4-main-edit")
        app.buttons["图标"].tap();capture(app,"v4-icon-picker");app.buttons["完成"].tap();app.buttons["取消"].tap()
        app.staticTexts["阅读设计规范"].tap();XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["新建下级"].exists);capture(app,"v4-leaf-detail")
        back(app);back(app);for _ in 0..<8 { if app.staticTexts["下一阶段"].exists { break };app.swipeUp() };app.staticTexts["下一阶段"].tap();XCTAssertTrue(app.staticTexts["暂无任务"].exists);capture(app,"v4-empty-main")
    }

    /// 验证图标草稿与保存、归属和历史容器；参数无；返回无，只作用于内存样本。
    func testV4IconAndMove() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.staticTexts["设计准备"].tap();app.buttons["编辑"].tap();app.buttons["图标"].tap()
        XCTAssertTrue(app.buttons["分层计划"].isSelected);app.buttons["目标"].tap();app.buttons["完成"].tap();app.buttons["取消"].tap()
        app.buttons["编辑"].tap();app.buttons["图标"].tap();XCTAssertTrue(app.buttons["分层计划"].isSelected)
        app.buttons["目标"].tap();app.buttons["完成"].tap();app.buttons["保存"].tap()
        app.buttons["编辑"].tap();app.buttons["图标"].tap();XCTAssertTrue(app.buttons["目标"].isSelected);capture(app,"v4-icon-saved")
        app.buttons["完成"].tap();app.buttons["取消"].tap();back(app)
        app.staticTexts["产品发布"].tap();app.buttons["编辑"].tap();app.buttons["清单、工作"].tap();app.buttons["学习"].tap()
        XCTAssertTrue(app.buttons["父主任务、无"].exists);app.buttons["保存"].tap();back(app);back(app)
        app.staticTexts["学习"].tap();XCTAssertTrue(app.staticTexts["产品发布"].exists);XCTAssertTrue(app.staticTexts["阅读设计规范"].exists);capture(app,"v4-tree-moved")
        back(app);app.staticTexts["工作"].tap();app.staticTexts["历史任务容器"].tap()
        XCTAssertFalse(app.buttons["新建下级"].exists);XCTAssertFalse(app.buttons["减少"].exists);capture(app,"v4-legacy-container")
    }
    /// 验证液态玻璃数量按钮、按住连续调整、独立边界、直接输入及保存／取消；参数：无；返回值：无；仅修改 v4 内存样本，不访问真实服务器。
    func testV4ProgressSteppers() {
        let app = launch("v4")
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        let target = app.buttons["目标总量.stepper-Increment"]
        let targetMinus = app.buttons["目标总量.stepper-Decrement"]
        for _ in 0..<4 { if target.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(target.exists)
        capture(app, "progress-stepper-initial")
        let done = app.buttons["已完成量.stepper-Increment"]
        let doneMinus = app.buttons["已完成量.stepper-Decrement"]
        let step = app.buttons["每次增加.stepper-Increment"]
        let stepMinus = app.buttons["每次增加.stepper-Decrement"]
        XCTAssertTrue(targetMinus.exists)
        XCTAssertTrue(doneMinus.exists)
        XCTAssertTrue(stepMinus.exists)
        // 原生玻璃加减按钮保留独立可访问名称；每次仅变更对应字段，不额外弹出键盘。
        target.tap()
        XCTAssertEqual(app.textFields["目标总量"].value as? String, "11")
        XCTAssertEqual(app.textFields["已完成量"].value as? String, "5")
        targetMinus.tap()
        done.tap()
        XCTAssertEqual(app.textFields["已完成量"].value as? String, "6")
        doneMinus.tap()
        step.tap()
        XCTAssertEqual(app.textFields["每次增加"].value as? String, "2")
        stepMinus.tap()
        XCTAssertFalse(stepMinus.isEnabled)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // 按住增加应连续读取最新草稿而非重复写入同一候选值；随后用减少按钮恢复初值。
        target.press(forDuration: 1.5)
        let heldTotal = Int(app.textFields["目标总量"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(heldTotal, 11)
        for _ in 10..<max(10, heldTotal) { targetMinus.tap() }
        // 已完成下界为 0，上界为目标总量；总量不小于已完成量，也不改写其他草稿。
        for _ in 0..<5 { doneMinus.tap() }
        XCTAssertEqual(app.textFields["已完成量"].value as? String, "0")
        XCTAssertFalse(doneMinus.isEnabled)
        for _ in 0..<10 { done.tap() }
        XCTAssertFalse(done.isEnabled)
        XCTAssertFalse(targetMinus.isEnabled)
        capture(app, "progress-stepper-bounds")
        doneMinus.tap()
        app.buttons["保存"].tap()
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        for _ in 0..<4 { if target.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.textFields["已完成量"].value as? String, "9")
        // 直接输入仍可编辑；达到总量上限后增加停用，非法草稿不能保存，取消保留持久化值。
        let field = app.textFields["目标总量"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "1000000000")
        XCTAssertFalse(target.isEnabled)
        field.typeText("1")
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        app.buttons["取消"].tap()
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        for _ in 0..<4 { if target.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.textFields["目标总量"].value as? String, "10")
        XCTAssertEqual(app.textFields["已完成量"].value as? String, "9")
        capture(app, "progress-stepper-saved")
    }

    /// 验证全天默认开启、已有时分保留、底部日期时间选择、取消及行内清空；参数：无；返回值：无；仅操作 v4 内存样本，截止为同日 18:30。
    func testV4DateDraft() {
        let app = launch("v4")
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        capture(app, "bottom-date-task-form")
        button(app, "开始.selector").tap()
        XCTAssertTrue(app.navigationBars["编辑任务"].exists)
        XCTAssertFalse(app.navigationBars["开始"].exists)
        // 历史仅日期数据保留全天；关闭全天后，同一个系统控件同时提供日期、小时和分钟滚轮。
        let allDay = app.switches["全天"].firstMatch
        XCTAssertEqual(allDay.value as? String, "1")
        allDay.descendants(matching: .switch).firstMatch.tap()
        XCTAssertEqual(app.pickerWheels.count, 3)
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "19")
        capture(app, "bottom-date-combined-wheel")
        app.buttons["完成"].tap()
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        capture(app, "bottom-date-reversed")
        button(app, "开始.selector").tap()
        XCTAssertEqual(app.switches["全天"].firstMatch.value as? String, "0")
        XCTAssertFalse(app.buttons["清除"].exists)
        // 底部取消保留已经确认的 19 点；清空操作只在表单行内执行，且不影响截止值。
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "09")
        app.buttons["system-date-time-cancel"].tap()
        XCTAssertTrue(app.buttons["开始.selector"].label.contains("19:00"))
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        button(app, "开始.clear").tap()
        XCTAssertFalse(app.buttons["开始.clear"].exists)
        XCTAssertTrue(app.buttons["截止.selector"].label.contains("18:30"))
        XCTAssertTrue(app.buttons["保存"].isEnabled)
        app.buttons["保存"].tap()
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        XCTAssertEqual(app.buttons["开始.selector"].staticTexts["未设置"].label, "未设置")
        button(app, "开始.selector").tap()
        XCTAssertEqual(app.switches["全天"].firstMatch.value as? String, "1")
        capture(app, "bottom-date-all-day-default")
        app.switches["全天"].firstMatch.descendants(matching: .switch).firstMatch.tap()
        XCTAssertEqual(app.pickerWheels.count, 3)
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "09")
        capture(app, "bottom-date-new-selection")
        // 底部取消只丢弃选择草稿，表单仍保持未设置；随后确认完整日期时间，再取消整个表单也不写入。
        app.buttons["system-date-time-cancel"].tap()
        XCTAssertTrue(app.buttons["开始.selector"].staticTexts["未设置"].exists)
        button(app, "开始.selector").tap()
        XCTAssertEqual(app.switches["全天"].firstMatch.value as? String, "1")
        app.switches["全天"].firstMatch.descendants(matching: .switch).firstMatch.tap()
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "09")
        app.buttons["完成"].tap()
        XCTAssertFalse(app.buttons["开始.selector"].staticTexts["未设置"].exists)
        capture(app, "bottom-date-confirmed")
        app.buttons["取消"].tap()
        app.staticTexts["阅读设计规范"].swipeLeft()
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.buttons["开始.selector"].staticTexts["未设置"].exists)
        capture(app, "bottom-date-cancel-retained")
    }

    /// 验证v4菜单排序和共享失败保护；参数无；返回无，不提交真实排序或真实服务器请求。
    func testV4SortAndProtection() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.buttons["更多"].tap();app.buttons["排序"].tap();capture(app,"v4-sort-mode")
        app.buttons["更多"].tap();app.buttons["完成排序"].tap();capture(app,"v4-sort-ended")
        app.terminate();let failure=launch("refresh-error");failure.staticTexts["日常与成长"].tap();failure.staticTexts["整理本月订阅与开销"].tap()
        failure.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","+1")).firstMatch.tap();XCTAssertFalse(failure.buttons["编辑"].isEnabled)
        back(failure);XCTAssertFalse(failure.buttons["新建任务"].isEnabled);capture(failure,"v4-shared-protection")
        failure.buttons["刷新任务"].tap();if !failure.buttons["新建任务"].isEnabled { failure.buttons["刷新任务"].tap() };XCTAssertTrue(failure.buttons["新建任务"].isEnabled);capture(failure,"v4-shared-recovered")
    }

    /// 验证选中角标与可访问选择trait；参数无；返回无，外观字号由专用模拟器配置，不模拟真实VoiceOver。
    func testV4IconBadge() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.staticTexts["设计准备"].tap();app.buttons["编辑"].tap();app.buttons["图标"].tap()
        XCTAssertTrue(app.buttons["分层计划"].isSelected);capture(app,"v4-badge-selected")
        app.buttons["目标"].tap();XCTAssertTrue(app.buttons["目标"].isSelected);XCTAssertFalse(app.buttons["分层计划"].isSelected)
        let search=app.searchFields.firstMatch;search.tap();search.typeText("发布")
        XCTAssertTrue(app.buttons["发布"].waitForExistence(timeout:5));app.buttons["发布"].tap();XCTAssertTrue(app.buttons["发布"].isSelected)
        capture(app,"v4-badge-search-selected");app.buttons["close"].tap();app.buttons["完成"].tap();app.buttons["取消"].tap()
        app.buttons["编辑"].tap();app.buttons["图标"].tap();XCTAssertTrue(app.buttons["分层计划"].isSelected)
    }

    /// 验证未知图标编辑不变成已知默认键；参数无；返回无，实际选择trait区别原始未知与Folder回退显示。
    func testV4UnknownIconCompatibility() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.staticTexts["历史任务容器"].tap();app.buttons["编辑"].tap()
        app.buttons["类型、具体任务"].tap();app.buttons["主任务"].tap();app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["主任务详情"].waitForExistence(timeout:5));app.buttons["编辑"].tap();app.buttons["图标"].tap()
        XCTAssertFalse(app.buttons["文件夹"].isSelected)
        XCTAssertEqual(app.buttons.allElementsBoundByIndex.filter { $0.isHittable && $0.isSelected }.count,0)
        capture(app,"unknown-icon-after-main-conversion");app.buttons["完成"].tap()
        let field=app.textFields["名称"].firstMatch;field.tap();field.typeText("兼容检查")
        app.buttons["保存"].tap();app.buttons["编辑"].tap();app.buttons["图标"].tap()
        XCTAssertFalse(app.buttons["文件夹"].isSelected)
        XCTAssertEqual(app.buttons.allElementsBoundByIndex.filter { $0.isHittable && $0.isSelected }.count,0)
        capture(app,"unknown-icon-after-title-save")
    }

    /// 通过实际排序手柄拖动同父根并刷新确认；参数无；返回无，仅内存场景，不猜测屏幕坐标。
    func testV4ActualReorder() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.buttons["收起下级"].firstMatch.tap()
        app.buttons["更多"].tap();app.buttons["排序"].tap();capture(app,"reorder-before")
        let source=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Reorder 下一阶段")).firstMatch
        let target=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Reorder 产品发布")).firstMatch
        XCTAssertTrue(source.exists && target.exists);source.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.8,thenDragTo:target.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.1)))
        app.buttons["更多"].tap();app.buttons["完成排序"].tap()
        XCTAssertLessThan(app.staticTexts["下一阶段"].frame.minY,app.staticTexts["产品发布"].frame.minY);capture(app,"reorder-after-drag")
        app.swipeDown();back(app);app.staticTexts["工作"].tap()
        XCTAssertLessThan(app.staticTexts["下一阶段"].frame.minY,app.staticTexts["产品发布"].frame.minY)
        XCTAssertTrue(app.staticTexts["设计准备"].exists && app.staticTexts["阅读设计规范"].exists && app.staticTexts["确认评审时间"].exists)
        app.staticTexts["设计准备"].tap();XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","6 / 11")).firstMatch.exists);capture(app,"reorder-subtree-retained")
        back(app);capture(app,"reorder-after-reentry")
    }

    /// 探测系统减少动态效果设置；参数无；返回无，只打开专用模拟器设置并保存AX。
    func testReduceMotionSettingsProbe() {
        let settings=XCUIApplication(bundleIdentifier:"com.apple.Preferences");settings.launch();capture(settings,"reduce-motion-settings-root")
        let accessibility=settings.staticTexts["Accessibility"].firstMatch
        for _ in 0..<6 { if accessibility.exists && accessibility.isHittable { break };settings.swipeUp() }
        accessibility.tap();capture(settings,"reduce-motion-accessibility")
        settings.staticTexts["Motion"].firstMatch.tap();capture(settings,"reduce-motion-motion-settings")
    }

    /// 在真实系统减少动态效果开启后验证浮动字段与草稿；参数无；返回无，结束恢复原系统开关。
    func testV4ReduceMotionDraft() {
        let settings=XCUIApplication(bundleIdentifier:"com.apple.Preferences");settings.launch()
        if !settings.switches["Reduce Motion"].exists {
            let accessibility=settings.staticTexts["Accessibility"].firstMatch
            for _ in 0..<6 { if accessibility.exists && accessibility.isHittable {break};settings.swipeUp() }
            accessibility.tap();settings.staticTexts["Motion"].tap()
        }
        let motion=settings.switches["Reduce Motion"].firstMatch
        XCTAssertEqual(motion.value as? String,"0");motion.descendants(matching:.switch).firstMatch.tap();XCTAssertEqual(motion.value as? String,"1");capture(settings,"motion-enabled")
        // 恢复回调无输入输出；仅关掉本测试开启的专用模拟器偏好，不改其他设置。
        defer { settings.launch();if !settings.switches["Reduce Motion"].exists {let access=settings.staticTexts["Accessibility"].firstMatch;for _ in 0..<6 {if access.exists && access.isHittable {break};settings.swipeUp()};access.tap();settings.staticTexts["Motion"].tap()};let restore=settings.switches["Reduce Motion"].firstMatch;XCTAssertTrue(restore.waitForExistence(timeout:5));if restore.value as? String == "1" {restore.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()};XCTAssertEqual(restore.value as? String,"0");capture(settings,"motion-restored") }
        let app=launch("v4");app.buttons["新建任务"].tap();capture(app,"motion-label-empty")
        let name=app.textFields["名称"].firstMatch;name.tap();capture(app,"motion-label-focused");name.typeText("减少动态效果草稿")
        app.buttons["类型、具体任务"].tap();app.buttons["主任务"].tap();app.buttons["图标"].tap();app.buttons["目标"].tap();app.buttons["完成"].tap()
        XCTAssertEqual(name.value as? String,"减少动态效果草稿");capture(app,"motion-icon-draft-return")
        button(app,"开始.selector").tap();app.buttons["完成"].tap()
        XCTAssertEqual(name.value as? String,"减少动态效果草稿")
        app.buttons["图标"].tap();XCTAssertTrue(app.buttons["目标"].isSelected);app.buttons["完成"].tap();capture(app,"motion-date-draft-return")
        app.buttons["取消"].tap()
    }

    /// 恢复本验收开启的系统偏好；参数无；返回无，独立确认设置关闭，不涉及应用业务。
    func testRestoreReduceMotion() {
        let settings=XCUIApplication(bundleIdentifier:"com.apple.Preferences");settings.launch()
        if !settings.switches["Reduce Motion"].exists {
            let accessibility=settings.staticTexts["Accessibility"].firstMatch
            for _ in 0..<6 { if accessibility.exists && accessibility.isHittable {break};settings.swipeUp() }
            accessibility.tap();settings.staticTexts["Motion"].tap()
        }
        let motion=settings.switches["Reduce Motion"].firstMatch
        XCTAssertTrue(motion.waitForExistence(timeout:5));if motion.value as? String == "1" {motion.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()}
        XCTAssertEqual(motion.value as? String,"0");capture(settings,"motion-restored")
    }

}
