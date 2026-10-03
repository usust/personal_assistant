import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

const source = await readFile(new URL('../src/composables/workspacePanels.ts', import.meta.url), 'utf8')
const { outputText } = ts.transpileModule(source.replace("'vue'", JSON.stringify(import.meta.resolve('vue'))), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
})
const { openPanel, removePanel, panelStack, confirmInPanel, settleConfirmation, confirmation } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`)

// 验证返回及卸载保留正确层级；参数：无；返回值：无。
test('nested panel closing restores its parent and unmount releases layout space', () => {
  const parent = Symbol(), child = Symbol()
  openPanel(parent)
  openPanel(child)
  openPanel(parent)
  assert.equal(panelStack.value.at(-1), child)
  removePanel(child)
  assert.deepEqual(panelStack.value, [parent])
  removePanel(parent)
  assert.equal(panelStack.value.length, 0)
})

// 验证取消确认会阻止业务写入；参数：无；返回值：异步测试完成 Promise。
test('cancelling a confirmation prevents the subsequent mutation', async () => {
  let writes = 0
  // 模拟业务确认后的写入；参数：无；返回值：无。
  const operation = confirmInPanel('删除记录？', '删除').then(() => { writes++ })
  // 验证取消原因；参数：reason 为拒绝值；返回值：是否为取消。
  const rejected = assert.rejects(operation, reason => reason === 'cancel')
  settleConfirmation(false)
  await rejected
  assert.equal(writes, 0)
  assert.equal(confirmation.value, null)
})

// 验证新确认替换旧确认且仅执行新操作；参数：无；返回值：异步测试完成 Promise。
test('replacing a confirmation cancels the old request and resolves only the accepted request', async () => {
  const old = confirmInPanel('旧操作', '确认')
  // 取消原因为字符串，保持原弹窗取消语义；参数：reason 为拒绝值；返回值：是否为取消。
  const cancelled = assert.rejects(old, reason => reason === 'cancel')
  const current = confirmInPanel('新操作', '确认')
  await cancelled
  settleConfirmation(true)
  await current
  assert.equal(confirmation.value, null)
})
