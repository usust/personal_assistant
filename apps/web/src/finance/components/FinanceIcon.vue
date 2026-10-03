<script setup lang="ts">
import { computed } from 'vue'
import { financeIconAsset, financeIconSource, financeProviderById } from '@/finance/providers'

const props = withDefaults(defineProps<{ kind: string; provider?: string; institution?: string; size?: number; label?: string }>(), { provider: '', institution: '', size: 38, label: '' })
const normalized = computed(() => props.kind.replaceAll('_', '-'))
const iconKind = computed(() => props.provider
  ? financeProviderById(props.provider).icon
  : financeIconAsset(normalized.value, props.institution))
const source = computed(() => props.provider
  ? financeIconSource(financeProviderById(props.provider).id)
  : financeIconSource(normalized.value, props.institution))
const accessibleLabel = computed(() => props.label || ({
  bank: '银行', alipay: '支付宝', wechat: '微信支付', cash: '现金', savings: '储蓄',
  investment: '投资', other: '其他账户', wallet: '钱包', 'credit-card': '信用卡',
  loan: '贷款', mortgage: '房贷', income: '收入', expense: '支出', transfer: '转账', recurring: '周期账单'
} as Record<string, string>)[normalized.value] || '财务')
</script>

<template>
  <span class="finance-icon" :class="[`finance-icon--${normalized}`, `finance-icon--asset-${iconKind}`]" :style="{ '--finance-icon-size': `${size}px` }" role="img" :aria-label="accessibleLabel">
    <img :src="source" alt="" aria-hidden="true" />
  </span>
</template>

<style scoped>
.finance-icon { --finance-icon-bg: #f4f5fb; display: inline-grid; width: var(--finance-icon-size); height: var(--finance-icon-size); flex: 0 0 var(--finance-icon-size); place-items: center; overflow: hidden; border-radius: calc(var(--finance-icon-size) * .27); background: var(--finance-icon-bg); }
.finance-icon img { width: 100%; height: 100%; object-fit: contain; }
.finance-icon[class*="finance-icon--asset-bank-"] { background: transparent; }
.finance-icon[class*="finance-icon--asset-bank-"] img { transform: scale(1.5); }
.finance-icon--asset-alipay, .finance-icon--asset-wechat { background: transparent; }
.finance-icon--cash, .finance-icon--recurring { --finance-icon-bg: #fff3d4; }
.finance-icon--savings, .finance-icon--income { --finance-icon-bg: #e6f5ef; }
.finance-icon--investment { --finance-icon-bg: #f0eafe; }
.finance-icon--credit-card, .finance-icon--expense { --finance-icon-bg: #ffebef; }
.finance-icon--loan { --finance-icon-bg: #fff0e7; }
</style>
