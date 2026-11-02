import CryptoKit
import Foundation
import ImageIO
import UIKit

/// 本机餐食缩略图按服务器与账号隔离，不参与云同步；原始照片与分析图片不写入此目录。
public enum MealThumbnailStore {
    private static let maximumBytes = 120 * 1024
    private static let maximumEdge = 480

    /// 生成稳定且可安全作为目录名的账号作用域；参数：server 为 APIClient 的规范化后端基础地址，userID 为当前账号的稳定整数 ID；返回值：服务器与账号组合的 SHA256 小写十六进制摘要；无文件或网络副作用。
    public nonisolated static func scope(server: String, userID: Int) -> String {
        // 长度前缀确保服务器字符串与账号的拼接无歧义；不使用随机 Hashable 值或显示昵称。
        let identity = "\(server.utf8.count):\(server):\(userID)"
        // 摘要映射回调参数为单个字节；返回值为固定两位十六进制文本。
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 读取本机缩略图；参数：owner 为 scope 生成的账号作用域，mealID 为餐食 UUID（大小写均可）；返回值：可用 UIImage，缺失、受保护不可读或标识无效时为 nil；不创建文件或目录。
    @MainActor public static func image(owner: String, mealID: String) -> UIImage? {
        guard let url = try? fileURL(owner: owner, mealID: mealID),
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return UIImage(data: data)
    }

    /// 保存餐食缩略图；参数：data 为有效单张图片，最大 20 MB、4000 万像素，owner 为 scope 生成的作用域，mealID 为已确认保存的餐食 UUID；返回值：无；重编码为最长边不超过 480 像素且不超过 120 KB 的 JPEG，剔除源元数据；校验、编码或受保护文件写入失败均抛错，调用者须保留照片以便重试。
    @MainActor public static func save(_ data: Data, owner: String, mealID: String) throws {
        let destination = try fileURL(owner: owner, mealID: mealID)
        let thumbnail = try encodedThumbnail(data)
        let directory = destination.deletingLastPathComponent()
        // 根目录及账号目录均排除系统备份并启用完整文件保护，锁屏时照片不可读。
        try prepareDirectory(directory.deletingLastPathComponent())
        try prepareDirectory(directory)
        try thumbnail.write(to: destination, options: [.atomic, .completeFileProtection])
        var protectedURL = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    /// 删除一餐的本机照片；参数：owner 为 scope 生成的作用域，mealID 为餐食 UUID；返回值：无；文件不存在时成功，标识无效或其他文件系统错误抛错，不创建目录。
    @MainActor public static func remove(owner: String, mealID: String) throws {
        try removeIfPresent(fileURL(owner: owner, mealID: mealID))
    }

    /// 删除指定账号作用域内的全部餐食照片；参数：owner 为 scope 生成的作用域；返回值：无；目录不存在时成功，其余校验或删除错误抛出，不影响其他服务器或账号。
    @MainActor public static func removeAll(owner: String) throws {
        try removeIfPresent(ownerDirectory(owner))
    }

    /// 定位账号目录；参数：owner 必须是 scope 生成的 64 位小写十六进制摘要；返回值：Application Support 下专属目录 URL；标识无效或系统目录不可定位时抛错，不创建目录。
    private static func ownerDirectory(_ owner: String) throws -> URL {
        guard owner.utf8.count == 64, owner.utf8.allSatisfy({ byte in
            // 校验回调参数为 UTF-8 字节；返回值表示该字节是否属于小写十六进制，阻止路径穿越。
            (48...57).contains(byte) || (97...102).contains(byte)
        }) else { throw StorageError.invalidIdentity }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("MealThumbnails", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
    }

    /// 定位单餐 JPEG 文件；参数：owner 为 scope 生成的作用域，mealID 必须能解析为 UUID；返回值：使用标准小写 UUID 的文件 URL；无效标识抛错，不访问照片内容。
    private static func fileURL(owner: String, mealID: String) throws -> URL {
        guard let uuid = UUID(uuidString: mealID) else { throw StorageError.invalidIdentity }
        return try ownerDirectory(owner).appendingPathComponent(uuid.uuidString.lowercased() + ".jpg", isDirectory: false)
    }

    /// 准备受保护且不备份的目录；参数：directory 为本存储拥有的目录 URL；返回值：无；创建目录并修复既有目录属性，任何失败抛错。
    private static func prepareDirectory(_ directory: URL) throws {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// 幂等移除文件或目录；参数：url 为已校验的本存储路径；返回值：无；仅忽略不存在错误，权限或保护状态等错误继续抛出，避免静默丢失删除失败。
    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    /// 生成去除源元数据的 JPEG；参数：data 为最大 20 MB 的单张图片；返回值：最长边不超过 480 像素且最多 120 KB 的新编码数据；拒绝无效或超大像素输入，编码失败抛错；仅使用内存。
    @MainActor private static func encodedThumbnail(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 40_000_000 else {
            throw StorageError.invalidImage
        }
        // 先在解码阶段缩小并校正方向，不把源 EXIF/GPS 属性传给新图；降低质量仍超限时继续缩小，绝不写入超限文件。
        var edge = maximumEdge
        while edge >= 60 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ]
            guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw StorageError.invalidImage
            }
            let image = UIImage(cgImage: pixels)
            for quality in [0.85, 0.7, 0.55, 0.4, 0.25] {
                if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= maximumBytes { return jpeg }
            }
            edge /= 2
        }
        throw StorageError.encodingFailed
    }

    /// 本机照片错误用于捕获页的可见重试提示，不伪装为服务器错误。
    private enum StorageError: LocalizedError {
        case invalidIdentity
        case invalidImage
        case encodingFailed

        /// 提供本机照片失败说明；参数：无；返回值：对应校验或编码错误的简短中文文本；无副作用。
        var errorDescription: String? {
            switch self {
            case .invalidIdentity: "照片所属账号或餐食标识无效。"
            case .invalidImage: "照片格式或尺寸无效。"
            case .encodingFailed: "无法生成符合大小限制的照片缩略图。"
            }
        }
    }
}
