import { resolveAccountChoice } from './accountCatalog'
import type { AccountType, FinancialAccount } from '@/types/finance'

export interface FinanceProvider {
  id: string
  name: string
  group: '常用银行' | '支付与其他账户'
  accountType: AccountType
  institution: string
  icon: string
  aliases: string[]
}

export const financeProviders: FinanceProvider[] = [
  { id: 'cmb', name: '招商银行', group: '常用银行', accountType: 'bank', institution: '招商银行', icon: 'bank-cmb', aliases: ['招商', 'cmb', 'cmbchina'] },
  { id: 'icbc', name: '中国工商银行', group: '常用银行', accountType: 'bank', institution: '中国工商银行', icon: 'bank-icbc', aliases: ['工商银行', '工行', 'icbc'] },
  { id: 'ccb', name: '中国建设银行', group: '常用银行', accountType: 'bank', institution: '中国建设银行', icon: 'bank-ccb', aliases: ['建设银行', '建行', 'ccb'] },
  { id: 'abc', name: '中国农业银行', group: '常用银行', accountType: 'bank', institution: '中国农业银行', icon: 'bank-abc', aliases: ['农业银行', '农行', 'abc', 'abchina'] },
  { id: 'boc', name: '中国银行', group: '常用银行', accountType: 'bank', institution: '中国银行', icon: 'bank-boc', aliases: ['中行', 'boc'] },
  { id: 'bocom', name: '交通银行', group: '常用银行', accountType: 'bank', institution: '交通银行', icon: 'bank-bocom', aliases: ['交行', 'bocom', 'bankcomm'] },
  { id: 'psbc', name: '中国邮政储蓄银行', group: '常用银行', accountType: 'bank', institution: '中国邮政储蓄银行', icon: 'bank-psbc', aliases: ['邮储银行', '邮政储蓄', '邮储', 'psbc'] },
  { id: 'spdb', name: '浦发银行', group: '常用银行', accountType: 'bank', institution: '浦发银行', icon: 'bank-spdb', aliases: ['上海浦东发展银行', '浦发', 'spdb'] },
  { id: 'cib', name: '兴业银行', group: '常用银行', accountType: 'bank', institution: '兴业银行', icon: 'bank-cib', aliases: ['兴业', 'cib'] },
  { id: 'citic', name: '中信银行', group: '常用银行', accountType: 'bank', institution: '中信银行', icon: 'bank-citic', aliases: ['中信', 'citic'] },
  { id: 'pingan', name: '平安银行', group: '常用银行', accountType: 'bank', institution: '平安银行', icon: 'bank-pingan', aliases: ['平安', 'pingan'] },
  { id: 'cmbc', name: '中国民生银行', group: '常用银行', accountType: 'bank', institution: '中国民生银行', icon: 'bank-cmbc', aliases: ['民生银行', '民生', 'cmbc'] },
  { id: 'cgb', name: '广发银行', group: '常用银行', accountType: 'bank', institution: '广发银行', icon: 'bank-cgb', aliases: ['广东发展银行', '广发', 'cgb', 'cgbchina'] },
  { id: 'ceb', name: '中国光大银行', group: '常用银行', accountType: 'bank', institution: '中国光大银行', icon: 'bank-ceb', aliases: ['光大银行', '光大', 'ceb', 'cebbank'] },
  { id: 'bank', name: '其他银行卡', group: '常用银行', accountType: 'bank', institution: '其他银行', icon: 'bank', aliases: [] },
  { id: 'alipay', name: '支付宝', group: '支付与其他账户', accountType: 'alipay', institution: '支付宝', icon: 'alipay', aliases: ['alipay'] },
  { id: 'wechat', name: '微信支付', group: '支付与其他账户', accountType: 'wechat', institution: '微信支付', icon: 'wechat', aliases: ['微信', '零钱', 'wechat', 'weixin'] },
  { id: 'cash', name: '现金', group: '支付与其他账户', accountType: 'cash', institution: '现金', icon: 'cash', aliases: [] },
  { id: 'savings', name: '储蓄账户', group: '支付与其他账户', accountType: 'savings', institution: '储蓄账户', icon: 'savings', aliases: ['储蓄'] },
  { id: 'investment', name: '投资账户', group: '支付与其他账户', accountType: 'investment', institution: '投资账户', icon: 'investment', aliases: ['证券', '基金', '股票', '投资'] },
  { id: 'other', name: '其他账户', group: '支付与其他账户', accountType: 'other', institution: '其他账户', icon: 'wallet', aliases: ['其他'] }
]

export const financeProviderGroups = ['常用银行', '支付与其他账户'] as const

const iconModules = import.meta.glob('./assets/icons/*.{svg,png}', {
  eager: true,
  import: 'default',
  query: '?url'
}) as Record<string, string>

const normalize = (value: string) => value.trim().toLowerCase().replaceAll(/\s+/g, '')

export function financeProviderById(id: string) {
  return financeProviders.find(item => item.id === id) ?? financeProviders[0]
}

export function financeProviderForAccount(account: Pick<FinancialAccount, 'name' | 'institution' | 'accountType'>) {
  const haystack = normalize(`${account.institution} ${account.name}`)
  const exactType = financeProviders.filter(item => item.accountType === account.accountType)
  return exactType.find(item => [item.institution, item.name, ...item.aliases].some(alias => alias && haystack.includes(normalize(alias))))
    ?? exactType.find(item => item.id === account.accountType)
    ?? financeProviders.find(item => item.id === 'other')!
}

/** 选择本地图标；参数 kind 为财务类型，institution 为可选原始机构；返回素材标识，无副作用，账户产品优先统一目录。 */
export function financeIconAsset(kind: string, institution = '') {
  if (institution && ['bank', 'alipay', 'wechat', 'cash', 'savings', 'investment', 'other'].includes(kind)) return resolveAccountChoice(kind as AccountType, institution).icon
  const normalizedKind = kind.replaceAll('_', '-')
  const provider = institution
    ? financeProviderForAccount({ name: '', institution, accountType: (normalizedKind === 'credit-card' ? 'bank' : normalizedKind) as AccountType })
    : financeProviders.find(item => item.id === normalizedKind)
  return provider?.icon ?? (normalizedKind === 'other' ? 'wallet' : normalizedKind)
}

/** 解析本地品牌图标；参数 kind 为类型、institution 为机构原值；返回 SVG 或 PNG 地址，无网络请求。 */
export function financeIconSource(kind: string, institution = '') {
  const icon = financeIconAsset(kind, institution)
  return iconModules[`./assets/icons/${icon}.svg`] ?? iconModules[`./assets/icons/${icon}.png`] ?? iconModules['./assets/icons/wallet.svg']
}
