<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { previewLoanAccount } from '@/api/finance'
import { money } from '@/finance/utils/money'
import type { FinancialAccount, LoanAccountTerms, LoanPlanSummary } from '@/types/finance'
const draft = defineModel<Required<LoanAccountTerms>>({ required: true })
const props = defineProps<{ accounts: FinancialAccount[]; editingId: number | null }>()
const emit = defineEmits<{ plan: [account: FinancialAccount] }>()
const account = computed(() => props.accounts.find(item => item.id === props.editingId))
const contractLocked = computed(() => account.value?.loanPlanLocked || (account.value?.loanPaidPeriods ?? 0) > 0)
const preview = ref<LoanPlanSummary | null>(null)
const calculating = ref(false)
// 变更回调输入新旧草稿（未使用）、返回无；立即丢弃旧试算，避免保存前误读旧结果。
watch(draft, () => { preview.value = null }, { deep: true })
// 请求只读试算；参数无；返回完成 Promise；失败由统一 HTTP 层显示，草稿变更后忽略旧响应。
async function calculate() {
  if (calculating.value) return
  const snapshot = JSON.stringify(draft.value)
  calculating.value = true
  try { const result = await previewLoanAccount({ ...draft.value }); if (snapshot === JSON.stringify(draft.value)) preview.value = result }
  finally { calculating.value = false }
}
</script>
<template>
  <section class="form-group" aria-label="贷款资料">
    <el-form-item label="贷款本金" required><el-input v-model="draft.loanPrincipal" :disabled="contractLocked" inputmode="decimal"><template #prefix>￥</template></el-input></el-form-item>
    <el-form-item label="贷款机构"><el-input v-model="draft.loanLender" maxlength="128" /></el-form-item>
    <el-form-item label="初始年利率" required><el-input v-model="draft.loanAnnualRate" :disabled="contractLocked" inputmode="decimal"><template #suffix>%</template></el-input></el-form-item>
    <el-form-item label="还款方式" required><el-select v-model="draft.loanMethod" :disabled="contractLocked"><el-option label="等额本息" value="annuity" /><el-option label="等额本金" value="equal_principal" /><el-option label="先息后本" value="interest_only" /></el-select></el-form-item>
    <el-form-item label="贷款期数" required><el-input-number v-model="draft.loanPeriods" :disabled="contractLocked" :min="1" :max="480" :precision="0" /></el-form-item>
    <el-form-item label="已还期数"><el-input-number v-model="draft.loanPaidPeriods" :min="0" :max="draft.loanPeriods" :precision="0" /></el-form-item>
    <el-form-item label="首次还款日" required><el-date-picker v-model="draft.loanFirstPaymentDate" :disabled="contractLocked" type="date" value-format="YYYY-MM-DD" /></el-form-item>
    <el-form-item label="关联收款账户"><el-select v-model="draft.loanReceivingAccountId"><el-option label="不关联" :value="0" /><el-option v-for="item in props.accounts.filter(item => item.id !== editingId)" :key="item.id" :label="item.name" :value="item.id" /><el-option v-if="draft.loanReceivingAccountId && !accounts.some(item => item.id === draft.loanReceivingAccountId)" label="账户已删除" :value="draft.loanReceivingAccountId" /></el-select></el-form-item>
    <p class="loan-note">仅关联，不自动入账</p>
    <el-button v-if="account && contractLocked" @click="emit('plan', account)">查看计划与分期调整</el-button>
    <el-button v-else :loading="calculating" @click="calculate">还款试算</el-button>
    <dl v-if="preview" class="loan-preview"><dt>计划剩余本金</dt><dd>{{ money(preview.remainingPrincipal) }}</dd><dt>预计总利息</dt><dd>{{ money(preview.totalInterest) }}</dd><template v-if="preview.next"><dt>下期还款日</dt><dd>{{ preview.next.date }}</dd><dt>下期应还</dt><dd>{{ money(preview.next.payment) }}</dd><dt>本金 / 利息</dt><dd>{{ money(preview.next.principal) }} / {{ money(preview.next.interest) }}</dd></template><template v-else><dt>状态</dt><dd>已还清全部期数</dd></template></dl>
    <p v-if="preview" class="loan-note">固定利率试算，不含手续费及提前还款</p>
  </section>
</template>
<style scoped>
.loan-note { color: var(--el-text-color-secondary); font-size: 12px; }
.loan-preview { display: grid; grid-template-columns: auto 1fr; gap: 8px; font-size: 13px; }
.loan-preview dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
</style>
