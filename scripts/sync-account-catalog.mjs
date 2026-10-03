import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolve, dirname } from 'node:path'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const kinds = JSON.parse(readFileSync(resolve(root, 'shared/finance/account-kinds.json'), 'utf8'))
const banks = JSON.parse(readFileSync(resolve(root, 'apps/iOS/PersonalAssistant/Resources/AccountProviders.json'), 'utf8'))
const brands = JSON.parse(readFileSync(resolve(root, 'shared/finance/brand-icons.json'), 'utf8'))
// 品牌资源独立于监管快照；重导银行名录后同步仍能恢复已核对的图标绑定。
for (const entry of brands.banks) {
  const bank = banks.providers.find(item => item.id === entry.id)
  if (!bank) throw new Error(`品牌图标对应的银行不存在：${entry.name}`)
  bank.icon = entry.icon
}
for (const entry of brands.products) {
  const kind = kinds.items.find(item => item.id === entry.id)
  if (!kind) throw new Error(`品牌图标对应的类型不存在：${entry.name}`)
  kind.icon = entry.icon
}
const groups = new Set(['national', 'jointStock', 'digital', 'city'])
// 同步单个资源；参数：path 为仓库相对路径，value 为可序列化目录；返回无；--check 仅校验，过期时抛错，不覆盖用户文件。
function sync(path, value) {
  const target = resolve(root, path)
  const content = JSON.stringify(value, null, 2) + '\n'
  if (process.argv.includes('--check')) {
    if (readFileSync(target, 'utf8') !== content) throw new Error(`跨端账户目录未同步：${path}`)
  } else writeFileSync(target, content)
}
sync('apps/iOS/PersonalAssistant/Resources/AccountKinds.json', kinds)
sync('shared/finance/account-kinds.json', kinds)
sync('apps/iOS/PersonalAssistant/Resources/AccountProviders.json', banks)
sync('apps/web/src/finance/data/account-kinds.json', kinds)
sync('apps/web/src/finance/data/account-banks.json', { asOf: banks.asOf, providers: banks.providers.filter(item => item.type === 'bank' && groups.has(item.group)) })
console.log(`账户目录${process.argv.includes('--check') ? '一致' : '已同步'}：${kinds.items.length} 种账户类型`)
