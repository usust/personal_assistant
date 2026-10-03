import kinds from './data/account-kinds.json'
import banks from './data/account-banks.json'
import type { AccountType } from '@/types/finance'

export interface AccountChoice {
  id: string; name: string; type: AccountType; institution: string; icon: string
  aliases: string[]; section: string; isCredit: boolean; route: string; searchKey?: string
}
export const accountSections = kinds.sections
export const accountKinds = kinds.items as AccountChoice[]
export const accountBanks: AccountChoice[] = banks.providers.map(item => ({ ...item, type: 'bank', section: 'funds', route: '' }))
const cardSuffix = '（信用卡）'
const creditSuffix = '（信用账户）'

/** 规范搜索文本；参数 value 为任意名称；返回去空白与重音的小写文本，无副作用。 */
function normalize(value: string) { return value.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/\s/g, '') }
/** 匹配目录项；参数 item 为机构、query 为空或多词搜索；返回是否全部词命中，无副作用。 */
export function matchesChoice(item: AccountChoice, query: string) {
  const text = normalize([item.name, item.institution, ...item.aliases, item.searchKey || ''].join(' '))
  return query.trim().split(/\s+/).every(word => text.includes(normalize(word)))
}
/** 将银行转换为信用卡；参数 bank 为已有银行选项；返回带可恢复标记的副本，无副作用，不表示发卡资格。 */
export function creditCardChoice(bank: AccountChoice): AccountChoice {
  if (bank.isCredit) return bank
  const name = bank.institution + cardSuffix
  return { ...bank, id: `credit-${bank.id}`, name: bank.name + '信用卡', institution: new TextEncoder().encode(name).length <= 128 ? name : bank.name + cardSuffix, section: 'credit', isCredit: true }
}
/** 解析已存账户；参数 type/institution 为服务端原值；返回展示选项，保留原始机构，不改写未知机构或零值。 */
export function resolveAccountChoice(type: AccountType, institution: string): AccountChoice {
  const exact = [...accountKinds.filter(item => !item.route), ...accountBanks].find(item => item.type === type && [item.name, item.institution, ...item.aliases].some(name => normalize(name) === normalize(institution)))
  if (exact) return { ...exact, institution }
  if (type === 'bank' && institution.endsWith(cardSuffix)) return { ...creditCardChoice(resolveAccountChoice(type, institution.slice(0, -cardSuffix.length))), institution }
  const credit = type === 'other' && institution.endsWith(creditSuffix)
  const icons: Partial<Record<AccountType, string>> = { bank: 'bank', alipay: 'alipay', wechat: 'wechat', cash: 'type-wallet', savings: 'type-bank', investment: 'type-chart' }
  return { id: `existing-${type}-${institution}`, name: (credit ? institution.slice(0, -creditSuffix.length) : institution) || '自定义账户', type, institution, icon: credit ? 'type-credit' : icons[type] || 'type-wallet', aliases: [], section: credit ? 'credit' : type === 'investment' ? 'investment' : 'funds', isCredit: credit, route: '' }
}
/** 创建自定义类型；参数 name 为非空名称、credit 表示欠款账户；返回有效选项或 null，限制含信用标记的 UTF-8 长度，无副作用。 */
export function customAccountChoice(name: string, credit: boolean): AccountChoice | null {
  const value = name.trim()
  const institution = value + (credit ? creditSuffix : '')
  if (!value || new TextEncoder().encode(institution).length > 128) return null
  return resolveAccountChoice('other', institution)
}
/** 生成白名单 PATCH；参数 original 为打开时原值，edited 为已验证表单；返回只含实际改变的字段，保留 false/空字符串，无副作用。 */
export function accountPatch(original: Record<string, unknown>, edited: Record<string, unknown>) {
  const fields = ['name', 'accountType', 'institution', 'maskedAccountNumber', 'includeInNetWorth', 'notes']
  return Object.fromEntries(fields.filter(key => key in edited && edited[key] !== original[key]).map(key => [key, edited[key]]))
}
