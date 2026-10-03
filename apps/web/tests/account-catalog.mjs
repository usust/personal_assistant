import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'
const kindsText = await readFile(new URL('../src/finance/data/account-kinds.json', import.meta.url), 'utf8')
const banksText = await readFile(new URL('../src/finance/data/account-banks.json', import.meta.url), 'utf8')
let source = await readFile(new URL('../src/finance/accountCatalog.ts', import.meta.url), 'utf8')
source = source.replace("import kinds from './data/account-kinds.json'", `const kinds = ${kindsText}`)
  .replace("import banks from './data/account-banks.json'", `const banks = ${banksText}`)
const { outputText } = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 } })
const catalog = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`)
// 跨端一致性回调；参数无，返回完成 Promise；校验真实打包资源，不连接服务端。
test('iOS and web ship the same six sections and 66 types with only 161 banks', async () => {
  const canonical = JSON.parse(await readFile(new URL('../../../shared/finance/account-kinds.json', import.meta.url), 'utf8'))
  const ios = JSON.parse(await readFile(new URL('../../iOS/PersonalAssistant/Resources/AccountKinds.json', import.meta.url), 'utf8'))
  assert.deepEqual(canonical, JSON.parse(kindsText)); assert.deepEqual(canonical, ios)
  assert.equal(catalog.accountKinds.length, 66); assert.equal(catalog.accountSections.length, 6)
  assert.equal(catalog.accountBanks.length, 161)
  assert.equal(new Set(catalog.accountKinds.map(item => item.id)).size, 66)
})
// 类型恢复回调；参数无，返回无；确保充值／理财／应收应付等保存重开不会丢失用途。
test('every concrete account kind round-trips through existing API fields', () => {
  for (const kind of catalog.accountKinds.filter(item => !item.route)) {
    const restored = catalog.resolveAccountChoice(kind.type, kind.institution)
    assert.equal(restored.id, kind.id); assert.equal(restored.section, kind.section)
    assert.equal(restored.isCredit, kind.isCredit)
  }
})
// 历史与信用卡回调；参数无，返回无；重复选择保留旧机构，未知机构不会变成默认银行。
test('legacy institutions, credit cards and custom accounts remain intact', () => {
  const bank = catalog.resolveAccountChoice('bank', '工行')
  assert.equal(bank.institution, '工行'); assert.equal(bank.icon, 'brand-icbc')
  const card = catalog.creditCardChoice(bank)
  assert.equal(catalog.resolveAccountChoice(card.type, card.institution).id, card.id)
  assert.equal(catalog.resolveAccountChoice('bank', '旧地方银行').institution, '旧地方银行')
  assert.equal(catalog.customAccountChoice(' ', false), null)
  assert.equal(catalog.customAccountChoice('银'.repeat(43), false), null)
  assert.equal(catalog.customAccountChoice('临时欠款', true).isCredit, true)
  assert.equal(catalog.matchesChoice(bank, 'icbc'), true)
})
// 局部更新回调；参数无，返回无；验证 false 和空备注保留、未改机构不提交、非白名单字段被排除。
test('account edits submit only actual whitelist changes', () => {
  assert.deepEqual(catalog.accountPatch({ institution: '旧地方银行', notes: '旧', includeInNetWorth: true }, { institution: '旧地方银行', notes: '', includeInNetWorth: false, balance: '999' }), { notes: '', includeInNetWorth: false })
})
// 图标完整性回调；参数无，返回完成 Promise；检查每个可选类型和银行的两端真实资源，防止空图标上线。
test('every selectable bank and account kind has bundled icons on both clients', async () => {
  const icons = new Set([...catalog.accountKinds, ...catalog.accountBanks].map(item => item.icon))
  for (const icon of icons) {
    const webRoot = new URL('../src/finance/assets/icons/', import.meta.url)
    const data = await readFile(new URL(`${icon}.svg`, webRoot)).catch(() => readFile(new URL(`${icon}.png`, webRoot)))
    assert.ok(data.length, icon)
    const base = new URL(`../../iOS/PersonalAssistant/Assets.xcassets/finance-${icon}.imageset/`, import.meta.url)
    const contents = JSON.parse(await readFile(new URL('Contents.json', base), 'utf8'))
    const filenames = contents.images.map(image => image.filename).filter(Boolean)
    assert.ok(filenames.length, icon)
    for (const filename of filenames) assert.ok((await readFile(new URL(filename, base))).length, icon)
  }
})
// 品牌覆盖回调；参数无，返回 Promise；验证所有可选银行均绑定有出处的品牌素材且两端内容一致。
test('all selectable banks use sourced brand assets with matching client bytes', async () => {
  const manifest = JSON.parse(await readFile(new URL('../../../shared/finance/brand-icons.json', import.meta.url), 'utf8'))
  assert.equal(manifest.banks.length, catalog.accountBanks.length)
  for (const bank of catalog.accountBanks) {
    const entry = manifest.banks.find(item => item.id === bank.id)
    assert.ok(entry?.source.startsWith('https://'), bank.name)
    assert.equal(bank.icon, entry.icon)
  }
  for (const entry of [...manifest.banks, ...manifest.products]) {
    const data = await readFile(new URL(`../src/finance/assets/icons/${entry.file}`, import.meta.url))
    const ext = entry.file.split('.').pop()
    const ios = await readFile(new URL(`../../iOS/PersonalAssistant/Assets.xcassets/finance-${entry.icon}.imageset/icon.${ext}`, import.meta.url))
    assert.deepEqual(ios, data, entry.name)
  }
})
