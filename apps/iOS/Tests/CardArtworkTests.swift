import Foundation

@main enum CardArtworkTests {
    /// 验证公开搜索解析、银行归属及名称隐私；参数：无；返回值：无；默认不联网，--live 额外验证官方公开页。
    static func main() async throws {
        for name in ["银联 初音未来粉丝信用卡", "招商银行美国运通百夫长金卡", "VISA全币种国际信用卡", "皮卡丘信用卡"] {
            precondition(CardArtwork.preset(bank: "招商银行信用卡", name: name) != nil)
        }
        precondition(CardArtwork.preset(bank: "建设银行", name: "皮卡丘信用卡") == nil)
        precondition(CardArtwork.preset(bank: "招商银行", name: "MasterCard全币种国际信用卡") == nil)
        precondition(CardArtwork.preset(bank: "招商银行", name: "百夫长白金卡") == nil)
        let html = #"<a m="{&quot;murl&quot;:&quot;https://images.example.com/card.png&quot;,&quot;purl&quot;:&quot;https://market.cmbchina.com/card&quot;,&quot;t&quot;:&quot;bilibili信用卡&quot;}"></a>"#
        let values = CardArtwork.candidates(html: html)
        precondition(values.count == 1)
        precondition(CardArtwork.automatic(values[0], name: "bilibili联名信用卡", bank: "招商银行"))
        precondition(!CardArtwork.automatic(values[0], name: "bilibili联名信用卡", bank: "建设银行"))
        precondition(!CardArtwork.automatic(values[0], name: "信用卡", bank: "招商银行"))
        precondition(CardArtwork.publicURL("http://images.example.com/card.png") == nil)
        precondition(CardArtwork.publicURL("https://127.0.0.1/card.png") == nil)
        precondition(!CardArtwork.query(bank: "招商银行", name: "卡 6222 0000 0000 5510").contains("6222"))
        let page = #"<img src="images/pagecontent-main-row11-5.png" /><div><h6>bilibili信用卡</h6>"#
        let source = URL(string: "https://market.cmbchina.com/ccard/xkyxk/index.html")!
        let cards = CardArtwork.officialCandidates(html: page, source: source)
        precondition(cards.count == 1 && cards[0].imageURL.absoluteString == "https://market.cmbchina.com/ccard/xkyxk/images/pagecontent-main-row11-5.png")
        if CommandLine.arguments.contains("--live") {
            let live = try await CardArtwork.search("招商银行 bilibili信用卡")
            precondition(!live.isEmpty && CardArtwork.automatic(live[0], name: "bilibili信用卡", bank: "招商银行"))
            let data = try await CardArtwork.fetch(live[0].imageURL, limit: 5 * 1024 * 1024)
            precondition(data.count > 1000)
            print("Official card artwork live lookup passed")
        }
        print("Card artwork tests passed")
    }
}
