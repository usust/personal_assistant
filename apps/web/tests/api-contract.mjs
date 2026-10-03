import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

const calls = []
const replies = []
// HTTP 模拟器：外层回调输入 method 并返回键值对；内层输入请求参数，记录调用并返回排队响应，错误响应会抛出。
const http = Object.fromEntries(['get', 'post', 'patch', 'delete'].map(method => [method, async (...args) => {
  calls.push({ method, args })
  const reply = replies.shift()
  if (reply instanceof Error) throw reply
  return { data: { data: reply } }
}]))
globalThis.__contractHttp = http
// loadAPI 加载真实 API 实现并替换 HTTP 传输；参数：name 为 api 目录模块名；返回值：模块导出，读取或编译失败抛出错误。
async function loadAPI(name) {
  const source = await readFile(new URL(`../src/api/${name}.ts`, import.meta.url), 'utf8')
  const { outputText } = ts.transpileModule(source.replace("import { http } from './http'", 'const http = globalThis.__contractHttp'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
  })
  return import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`)
}
const auth = await loadAPI('auth')
const preferences = await loadAPI('preferences')
const aiConfig = await loadAPI('aiConfig')

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('captcha and login map the current API and load a profile with the new token', async () => {
  replies.push({ captcha_id: 'once', image: 'data:image/png;base64,test', expires_at: 123 })
  assert.deepEqual(await auth.getCaptcha(), { captchaId: 'once', image: 'data:image/png;base64,test', expiresAt: 123 })
  assert.deepEqual(calls.pop(), { method: 'get', args: ['/auth/captcha'] })
  replies.push({ token: 'new-token', token_type: 'Bearer' }, { id: 7, account: 'member', nickname: 'Member', role: 'user' })
  assert.deepEqual(await auth.login('member', 'password', 'once', 'answer'), {
    token: 'new-token', user: { id: 7, username: 'member', nickname: 'Member', role: 'user' },
  })
  assert.deepEqual(calls.shift(), { method: 'post', args: ['/auth/login', { account: 'member', password: 'password', captcha_id: 'once', captcha_answer: 'answer' }] })
  assert.deepEqual(calls.shift(), { method: 'get', args: ['/users/me', { headers: { Authorization: 'Bearer new-token' } }] })
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('preferences patch only supported fields and use server-normalized values', async () => {
  replies.push({ language: 'zh-CN', timezone: 'UTC' })
  assert.deepEqual(await preferences.getUserSettings(), { language: 'zh-CN', timezone: 'UTC' })
  assert.equal(calls.shift().args[0], '/settings/user')
  replies.push({ language: 'en', timezone: 'Asia/Singapore' })
  assert.deepEqual(await preferences.saveUserSettings({ language: 'en', timezone: 'Asia/Singapore' }), { language: 'en', timezone: 'Asia/Singapore' })
  assert.deepEqual(calls.shift(), { method: 'patch', args: ['/settings/user', { language: 'en', timezone: 'Asia/Singapore' }] })
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('AI list has no scope query, create uses source fields and discards returned secrets', async () => {
  replies.push([{ id: 'custom', name: 'Custom' }], [])
  assert.deepEqual(await aiConfig.getProviders(), [{ id: 'custom', name: 'Custom' }])
  assert.deepEqual(await aiConfig.getProviderConfigs(), [])
  assert.deepEqual(calls.splice(0), [
    { method: 'get', args: ['/setting/ai/providers'] },
    { method: 'get', args: ['/setting/ai/provider_config'] },
  ])
  const input = { name: 'My model', provider_name: 'custom', base_url: 'https://example.com/v1', model_name: 'model', api_key: 'secret', owner_type: 'user', owner_id: 7, visibility: 'private' }
  replies.push({ ...input, id: 1 })
  assert.equal(await aiConfig.createProviderConfig(input), undefined)
  assert.deepEqual(calls.shift(), { method: 'post', args: ['/setting/ai/provider_config/create', input] })
  replies.push(new Error('save failed'))
  await assert.rejects(aiConfig.createProviderConfig(input), /save failed/)
  calls.length = 0
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('user creation sends registration fields only and preserves the server identity', async () => {
  const users = await loadAPI('users')
  replies.push({ id: 8, account: 'new_user', nickname: 'New user', role: 'user' })
  assert.deepEqual(await users.registerUser({ account: ' New_User ', password: ' password ', nickname: ' New user ' }), {
    id: 8, username: 'new_user', nickname: 'New user', role: 'user',
  })
  assert.deepEqual(calls.shift(), { method: 'post', args: ['/users/register', { account: 'new_user', password: ' password ', nickname: 'New user' }] })
  replies.push(new Error('账号已存在'))
  await assert.rejects(users.registerUser({ account: 'new_user', password: 'password', nickname: 'New user' }), /账号已存在/)
  calls.length = 0
})


// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('users list maps server identities and handles an empty list', async () => {
  const users = await loadAPI('users')
  replies.push([{ id: 2, account: 'admin', nickname: '管理员', role: 'admin', password_hash: 'discard' }], [])
  assert.deepEqual(await users.listUsers(), [{ id: 2, username: 'admin', nickname: '管理员', role: 'admin' }])
  assert.deepEqual(await users.listUsers(), [])
  assert.deepEqual(calls.splice(0), [{ method: 'get', args: ['/users'] }, { method: 'get', args: ['/users'] }])
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('edit payload contains only changed fields and treats blank password as unchanged', async () => {
  const users = await loadAPI('users')
  const original = { id: 2, username: 'member', nickname: '昵称', role: 'user' }
  const form = { account: ' Member ', nickname: ' 昵称 ', role: 'user', password: '' }
  assert.deepEqual(users.buildUserPatch(original, form), {})
  assert.deepEqual(users.buildUserPatch(original, { ...form, nickname: '新昵称' }), { nickname: '新昵称' })
  assert.deepEqual(users.buildUserPatch(original, { ...form, account: ' Other ', role: 'admin', password: ' password ' }), {
    account: 'other', role: 'admin', password: ' password ',
  })
  assert.throws(() => users.buildUserPatch(original, { ...form, role: 'owner' }), /角色无效/)
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('PATCH whitelists submitted fields, preserves explicit empty values, and returns server values', async () => {
  const users = await loadAPI('users')
  const response = { id: 2, account: 'member', nickname: '新昵称', role: 'user' }
  replies.push(response, response)
  assert.deepEqual(await users.updateUser(2, { nickname: ' 新昵称 ', id: 999, password_hash: 'forbidden' }), {
    id: 2, username: 'member', nickname: '新昵称', role: 'user',
  })
  assert.deepEqual(calls.shift(), { method: 'patch', args: ['/users/2', { nickname: '新昵称' }] })
  await users.updateUser(2, { nickname: '', password: '', account: undefined })
  assert.deepEqual(calls.shift(), { method: 'patch', args: ['/users/2', { nickname: '', password: '' }] })
  replies.push(new Error('账号已存在'))
  await assert.rejects(users.updateUser(2, { account: 'existing' }), /账号已存在/)
  calls.length = 0
})

// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('DELETE accepts an empty response and propagates failure', async () => {
  const users = await loadAPI('users')
  replies.push(undefined)
  assert.equal(await users.deleteUser(2), undefined)
  assert.deepEqual(calls.shift(), { method: 'delete', args: ['/users/2'] })
  replies.push(new Error('需要管理员权限'))
  await assert.rejects(users.deleteUser(2), /需要管理员权限/)
  calls.length = 0
})

// 验证对话请求携带配置与文本历史，并保留操作失败结果；参数：无；返回：异步完成。
// 契约测试回调校验下述 API 行为；参数：无；返回值：异步完成，断言失败终止测试；仅使用内存模拟请求。
test('AI chat preserves action results and uses a timeout covering the server run', async () => {
  const ai = await loadAPI('ai')
  const messages = [{ role: 'user', content: '列出用户' }]
  const result = { reply: '', actions: [{ name: 'user.list', success: true }], error: '模型暂时不可用' }
  replies.push(result)
  assert.deepEqual(await ai.sendChat(7, messages), result)
  assert.deepEqual(calls.shift(), { method: 'post', args: ['/ai/chat', { config_id: 7, messages }, { timeout: 100_000 }] })
})

// 财务契约回调校验草稿确认、幂等键及过滤参数；参数：无；返回值：完成 Promise，仅使用内存 HTTP，不修改真实余额。
test('finance preserves money strings, request IDs and explicit draft confirmation endpoints', async () => {
  const finance = await loadAPI('finance')
  const input = { requestId: 'expense-contract-001', accountId: 3, type: 'expense', amount: '0.10', transactionDate: '2026-09-26' }
  const posted = { ...input, id: 9, status: 'posted' }
  replies.push(posted, posted)
  assert.deepEqual(await finance.createTransaction(input), posted)
  assert.deepEqual(await finance.createTransaction(input), posted)
  assert.deepEqual(calls.splice(0), [
    { method: 'post', args: ['/finance/transactions', input] },
    { method: 'post', args: ['/finance/transactions', input] },
  ])
  const filter = { status: 'pending', limit: 100, offset: 100, minAmount: '0.01' }
  replies.push([], posted, { ...posted, status: 'voided' })
  assert.deepEqual(await finance.getTransactions(filter), [])
  assert.equal((await finance.confirmTransaction(9)).status, 'posted')
  assert.equal((await finance.voidTransaction(9)).status, 'voided')
  assert.deepEqual(calls.splice(0), [
    { method: 'get', args: ['/finance/transactions', { params: filter }] },
    { method: 'post', args: ['/finance/transactions/9/confirm'] },
    { method: 'post', args: ['/finance/transactions/9/void'] },
  ])
})

// 验证模型目录和删除使用最新契约；参数：无；返回值：异步完成，失败拒绝，不请求真实模型或删除数据。
test('AI model catalog forwards saved identity with a bounded timeout and delete preserves failures', async () => {
  const input = { config_id: 7, base_url: 'https://example.com/v1', provider_name: 'custom', api_key: '' }
  replies.push(['model-a', 'model-b'])
  assert.deepEqual(await aiConfig.getProviderModels(input), ['model-a', 'model-b'])
  assert.deepEqual(calls.shift(), { method: 'post', args: ['/setting/ai/models', input, { timeout: 20_000 }] })
  replies.push(null)
  assert.equal(await aiConfig.deleteProviderConfig(7), undefined)
  assert.deepEqual(calls.shift(), { method: 'delete', args: ['/setting/ai/provider_config/7'] })
  replies.push(new Error('需要管理权限'))
  await assert.rejects(aiConfig.deleteProviderConfig(7), /需要管理权限/)
  calls.length = 0
})
