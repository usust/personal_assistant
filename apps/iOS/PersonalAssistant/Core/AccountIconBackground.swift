/// 账户图标的外围白底处理；只修改内存像素，不修改品牌资源文件。
nonisolated enum AccountIconBackground {
    /// 清除与画布边缘连通的透明或近白背景；参数：pixels 为预乘 alpha 的 RGBA 字节，width、height 为正数像素尺寸，字节数必须等于宽×高×4；返回值：无；原地更新像素，输入无效或图像没有有色图案时保持原样，封闭的内部白色细节保持不变。
    static func remove(from pixels: inout [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0,
              width <= Int.max / height / 4,
              pixels.count == width * height * 4 else { return }
        let count = width * height
        var background = [Bool](repeating: false, count: count)
        var hasArtwork = false
        for index in 0..<count {
            let offset = index * 4
            let alpha = Int(pixels[offset + 3])
            // 预乘通道与 alpha 比较，避免将半透明白边误判为灰色前景。
            background[index] = alpha <= 24 || min(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])) >= alpha * 96 / 100
            if !background[index] { hasArtwork = true }
        }
        guard hasArtwork else { return }
        var queue: [Int] = []
        var visited = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let x = index % width, y = index / width
            if (x == 0 || x == width - 1 || y == 0 || y == height - 1) && background[index] {
                visited[index] = true
                queue.append(index)
            }
        }
        // 从外缘进行四邻域遍历；封闭在品牌图案内的白色不会进入队列。
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let offset = index * 4
            for channel in 0..<4 { pixels[offset + channel] = 0 }
            let x = index % width, y = index / width
            let neighbors = [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
            for neighbor in neighbors where neighbor >= 0 {
                if background[neighbor] && !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
        }
    }
}
