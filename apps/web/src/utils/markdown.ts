import MarkdownIt from 'markdown-it'

// 禁止模型输出原始 HTML，保留解析器自带的危险链接过滤，不加载 HTML/高亮扩展。
const markdown = new MarkdownIt({ html: false, breaks: true, linkify: true, typographer: false })
// 当前对话只需要文本和表格；禁用图片，避免回答自动向第三方发起图片请求。
markdown.disable('image')

// link_open 为链接添加新窗口及隔离属性；参数：tokens 为解析结果，index 为当前位置，options 为渲染选项，_env 为上下文，renderer 为默认渲染器；返回：转义后的链接起始标签。
markdown.renderer.rules.link_open = (tokens, index, options, _env, renderer) => {
  const token = tokens[index]!
  token.attrSet('target', '_blank')
  token.attrSet('rel', 'noopener noreferrer')
  return renderer.renderToken(tokens, index, options)
}

// table_open 为宽表格增加可键盘聚焦的滚动区域；参数：无；返回：固定的容器和表格起始标签。
markdown.renderer.rules.table_open = () => '<div class="markdown-table" role="region" aria-label="表格，可横向滚动" tabindex="0"><table>\n'
// table_close 关闭表格与滚动区域；参数：无；返回：固定结束标签。
markdown.renderer.rules.table_close = () => '</table></div>\n'

// renderMarkdown 解析 AI 原文；参数：source 为未转换的 Markdown 字符串；返回：禁用原始 HTML 后生成的展示 HTML，不用于回传模型。
export function renderMarkdown(source: string): string {
  return markdown.render(source)
}
