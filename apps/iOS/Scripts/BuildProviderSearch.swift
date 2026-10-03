import Foundation

/// 生成离线搜索索引；参数：命令行第一个参数为待更新 JSON 文件路径；返回值：无；原地写入拼音与首字母，读写失败抛错并退出，JSON 必须由导入器生成，结构或字段类型不符将终止进程。
func buildSearchIndex() throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var providers = document["providers"] as! [[String: Any]]
    for index in providers.indices {
        let item = providers[index]
        let names = [item["name"] as! String, item["institution"] as! String] + (item["aliases"] as! [String])
        var tokens = names + [item["region"] as! String]
        for name in names {
            // 常见地名多音字采用地名读音；不影响保留在索引中的原始中文与英文名。
            let places = [("长沙", "chang sha"), ("长春", "chang chun"), ("长安", "chang an"),
                          ("长治", "chang zhi"), ("长兴", "chang xing"), ("长城", "chang cheng"),
                          ("长江", "chang jiang"), ("长白", "chang bai"), ("长汀", "chang ting"),
                          ("长丰", "chang feng"), ("长乐", "chang le"), ("长葛", "chang ge"),
                          ("厦门", "xia men"), ("蚌埠", "beng bu"), ("六安", "lu an"),
                          ("乐清", "yue qing"), ("乐亭", "lao ting"), ("单县", "shan xian"),
                          ("繁峙", "fan shi"), ("洪洞", "hong tong")]
            var phoneticName = name
            for (place, pronunciation) in places {
                phoneticName = phoneticName.replacingOccurrences(of: place, with: " " + pronunciation + " ")
            }
            let rawLatin = phoneticName.applyingTransform(.toLatin, reverse: false)?.folding(options: .diacriticInsensitive, locale: Locale(identifier: "zh_CN")) ?? name
            // ICU 对「行」默认取 xing；银行与分行的行业读音应为 hang，避免首字母检索错失。
            let latin = rawLatin.replacingOccurrences(of: "yin xing", with: "yin hang")
                .replacingOccurrences(of: "fen xing", with: "fen hang")
            tokens.append(latin)
            tokens.append(latin.split(separator: " ").compactMap(\.first).map(String.init).joined())
        }
        providers[index]["searchKey"] = tokens.joined(separator: " ").lowercased().filter { !$0.isWhitespace }
    }
    document["providers"] = providers
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    try data.write(to: url, options: .atomic)
}
try buildSearchIndex()
