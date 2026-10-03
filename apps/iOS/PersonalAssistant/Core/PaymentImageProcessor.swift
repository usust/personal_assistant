import UIKit
import ImageIO

/// 相册与快捷指令共用的支付图片校验和标准化。
enum PaymentImageProcessor {
    /// 验证并重编码图片，剔除元数据；参数：raw 为相册或快捷指令图片字节且上限 20 MB；返回值：最长边 2000 像素、最多 3 MB JPEG；非法图片抛错，无文件或网络副作用。
    @MainActor static func normalizedImage(_ raw: Data) throws -> Data {
        guard !raw.isEmpty, raw.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary),
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85), data.count <= 3 * 1024 * 1024 else {
            throw APIError(status: 0, message: "请选择有效的单张支付图片")
        }
        return data
    }
}
