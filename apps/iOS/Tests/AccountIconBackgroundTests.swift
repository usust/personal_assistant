/// 外围白底透明化回归；仅验证内存像素，不访问原始资源或模拟器。
@MainActor enum AccountIconBackgroundTests {
    /// 验证外围透明、内部白色和品牌颜色保护；参数：无；返回值：无；失败由测试断言终止进程。
    static func run() {
        let white: [UInt8] = [255, 255, 255, 255]
        let red: [UInt8] = [220, 20, 30, 255]
        var pixels = [UInt8](repeating: 255, count: 5 * 5 * 4)
        // 红色环包围白色中心，模拟银行标志内部白色细节；外围保持白底。
        for y in 1...3 {
            for x in 1...3 where x != 2 || y != 2 {
                let start = (y * 5 + x) * 4
                pixels.replaceSubrange(start..<start + 4, with: red)
            }
        }
        AccountIconBackground.remove(from: &pixels, width: 5, height: 5)
        CoreTests.check(Array(pixels[0..<4]) == [0, 0, 0, 0], "图标外围白底变为透明")
        CoreTests.check(Array(pixels[48..<52]) == white, "图标内部封闭白色保持原样")
        CoreTests.check(Array(pixels[24..<28]) == red, "图标品牌颜色保持原样")
        var translucent: [UInt8] = [128, 128, 128, 128] + red + [0, 0, 0, 0]
        AccountIconBackground.remove(from: &translucent, width: 3, height: 1)
        CoreTests.check(Array(translucent[0..<4]) == [0, 0, 0, 0], "图标半透明白色外缘正确清除")
        CoreTests.check(Array(translucent[4..<8]) == red, "贴边品牌图案不被清除")
        var whiteOnly = white
        AccountIconBackground.remove(from: &whiteOnly, width: 1, height: 1)
        CoreTests.check(whiteOnly == white, "纯白图标不被整体清空")
        var invalid = red
        AccountIconBackground.remove(from: &invalid, width: 2, height: 2)
        CoreTests.check(invalid == red, "图标像素尺寸不匹配时保留输入")
    }
}
