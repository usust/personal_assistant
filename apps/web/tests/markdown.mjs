import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

// 加载实际渲染函数，使用项目依赖解析路径；不复制实现，测试纯文本到展示 HTML 的行为。
const source = await readFile(new URL('../src/utils/markdown.ts', import.meta.url), 'utf8')
const { outputText } = ts.transpileModule(source.replace("'markdown-it'", JSON.stringify(import.meta.resolve('markdown-it'))), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
})
const { renderMarkdown } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`)

// 验证截图中的用户表格变为结构化表格；参数：无；返回值：无。
test('renders user tables inside a focusable horizontal scrolling region', () => {
  const html = renderMarkdown('查询成功，共 2 个用户：\n\n| ID | 账号 | 昵称 | 角色 |\n|---|---|---|---|\n| 1 | admin | 系统管理员 | sys_admin |\n| 9 | demo | 测试用户 | user |')
  assert.match(html, /class="markdown-table"[^>]*tabindex="0"/)
  assert.match(html, /<th>ID<\/th>/)
  assert.match(html, /<td>系统管理员<\/td>/)
  assert.equal((html.match(/<tr>/g) || []).length, 3)
})

// 验证常见回答格式及代码转义；参数：无；返回值：无。
test('renders headings, lists, quotes, emphasis and escaped code', () => {
  const html = renderMarkdown('## 结果\n\n- **完成**\n- `user.list`\n\n> 提示\n\n```html\n<script>alert(1)</script>\n```')
  assert.match(html, /<h2>结果<\/h2>/)
  assert.match(html, /<ul>/)
  assert.match(html, /<strong>完成<\/strong>/)
  assert.match(html, /<blockquote>/)
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/)
  assert.doesNotMatch(html, /<script>/)
})

// 验证不可信 HTML、脚本 URL 和远程图片不成为可执行或自动加载的内容；参数：无；返回值：无。
test('escapes raw HTML and rejects script links and automatic images', () => {
  const html = renderMarkdown('<img src=x onerror=alert(1)>\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1))\n\n[x](jav&#x61;script:alert(1))\n\n![追踪](https://example.com/pixel.png)')
  assert.doesNotMatch(html, /<(?:script|img)\b/i)
  assert.doesNotMatch(html, /href="javascript:/i)
  assert.match(html, /&lt;img/)
})

// 验证正常链接可以打开且隔离新窗口；参数：无；返回值：无。
test('opens valid links separately and preserves plain text line breaks', () => {
  const html = renderMarkdown('[文档](https://example.com)\n下一行')
  assert.match(html, /href="https:\/\/example.com"/)
  assert.match(html, /target="_blank"/)
  assert.match(html, /rel="noopener noreferrer"/)
  assert.match(html, /<br>/)
  assert.equal(renderMarkdown(''), '')
})
