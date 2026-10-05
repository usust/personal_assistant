import XCTest

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
    /// 只读布局验收入口；参数无；返回无，由外部模拟器配置控制尺寸、外观和字号。
    func testLayoutSnapshot() {
        let app=launch();XCTAssertTrue(app.staticTexts["为新的一周留点空间"].waitForExistence(timeout: 5))
        capture(app,"layout-list")
        app.staticTexts["为新的一周留点空间"].tap();capture(app,"layout-detail")
        app.buttons["编辑"].tap();capture(app,"layout-edit")
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
    /// 验证push日期子页及清空；参数无；返回无，既有v4日期同日18:30截止。
    func testV4DateDraft() {
        let app=launch("v4");app.staticTexts["工作"].tap();app.staticTexts["阅读设计规范"].tap();app.buttons["编辑"].tap()
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","开始、")).firstMatch.tap();nativeToggle(app,"指定时间")
        app.buttons["Time Picker"].firstMatch.tap();app.pickerWheels.element(boundBy:0).adjust(toPickerWheelValue:"19");app.navigationBars["开始"].tap();back(app)
        XCTAssertFalse(app.buttons["保存"].isEnabled);capture(app,"v4-date-reversed")
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","开始、")).firstMatch.tap();nativeToggle(app,"设置日期");back(app)
        XCTAssertTrue(app.buttons["保存"].isEnabled);app.buttons["保存"].tap();app.buttons["编辑"].tap()
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","开始、")).firstMatch.tap();XCTAssertEqual(app.switches["设置日期"].value as? String,"0")
        nativeToggle(app,"设置日期");XCTAssertEqual(app.switches["指定时间"].value as? String,"0");capture(app,"v4-date-cleared")
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

}
