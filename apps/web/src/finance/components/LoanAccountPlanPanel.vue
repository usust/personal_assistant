<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { getLoanAccountPlan, previewLoanAdjustment, saveLoanAdjustment } from '@/api/finance'
import { money, sumMoney } from '@/finance/utils/money'
import type { FinancialAccount, LoanAdjustmentRequest, LoanPayment, LoanPlanSummary } from '@/types/finance'

const visible = defineModel<boolean>({ required: true })
const props = defineProps<{ account: FinancialAccount }>()
const emit = defineEmits<{ changed: [] }>()
const plan = ref<LoanPlanSummary | null>(null)
const preview = ref<LoanPlanSummary | null>(null)
const loading = ref(false)
const busy = ref(false)
const adjusting = ref(false)
const error = ref('')
let generation = 0
const filter = ref('all')
const draft = reactive({ kind: 'rate' as 'rate' | 'payment', fromPeriod: 1, annualRate: '', payment: '' })
// 筛选回调无参数；返回已还倒序、全部与待还原顺序的列表，不改变原计划或已还状态。
const rows = computed(() => {
  const filtered = (plan.value?.schedule ?? []).filter(row => filter.value === 'all' || (filter.value === 'paid' ? row.period <= (plan.value?.paidPeriods ?? 0) : row.period > (plan.value?.paidPeriods ?? 0)))
  return filter.value === 'paid' ? filtered.sort((a, b) => b.period - a.period) : filtered
})
const eligible = computed(() => (plan.value?.schedule ?? []).filter(canAdjust))
// 校验只检查当前操作的字段；参数无；返回可否预览，不要求用户填写另一功能的隐藏值。
const valid = computed(() => ( /^(0|[1-9]\d{0,2})(\.\d{1,4})?$/.test(draft.annualRate) && Number(draft.annualRate) <= 100
  && (draft.kind === 'rate' || ( /^(0|[1-9]\d*)(\.\d{1,2})?$/.test(draft.payment) && Number(draft.payment) > 0 && Number(draft.payment) <= 1e12)))
  && eligible.value.some(row => row.period === draft.fromPeriod))
// 预览回调无参数；返回生效期起最多三期，末期不足三期时不补造数据。
const previewRows = computed(() => (preview.value?.schedule ?? []).filter(row => row.period >= draft.fromPeriod).slice(0, 3))
const adjustmentTitle = computed(() => draft.kind === 'rate' ? '调整利率' : '调整金额')

// 目标变化回调输入账户 ID 或关闭状态、返回无；使旧请求失效，避免快速切换账户时串入另一账户的计划。
watch(() => visible.value ? props.account.id : null, id => {
  generation++; loading.value = false; busy.value = false; adjusting.value = false; preview.value = null; plan.value = null
  if (id !== null) void load()
}, { immediate: true })
// 草稿变化回调输入新旧值（未使用）、返回无；过期预览不得继续保存。
watch(draft, () => { preview.value = null; error.value = '' })
// 切换期次回调输入新期次、返回无；金额预填当前行，避免沿用上一期的修改值。
watch(() => draft.fromPeriod, period => {
  if (draft.kind === 'payment') {
    const row = plan.value?.schedule?.find(row => row.period === period)
    draft.payment = row?.payment ?? ''
    draft.annualRate = row?.annualRate ?? props.account.loanAnnualRate ?? '0'
  }
})

// 计算单期修正差额；参数 row 为权威分期；返回展示金额，不改变计划本金或利息。
function paymentCorrection(row: LoanPayment) {
  const difference = sumMoney([row.payment, `-${row.principal}`, `-${row.interest}`])
  return `${difference.startsWith('-') ? '' : '+'}${money(difference)}`
}

// 判断分期可否调整；参数：row 为权威分期；返回值：期初仍有本金，已还期次也可修正，不改真实流水。
function canAdjust(row: LoanPayment) { return Number(row.remaining) + Number(row.principal) > 0 }
// 读取权威计划；参数无；返回完成 Promise；失败显示可重试错误，不伪造计划。
async function load() {
  if (loading.value || busy.value) return
  const requestGeneration = ++generation
  loading.value = true; error.value = ''; preview.value = null
  try { const result = await getLoanAccountPlan(props.account.id); if (requestGeneration === generation) plan.value = result }
  catch { if (requestGeneration === generation) error.value = '加载计划失败，请重试' }
  finally { if (requestGeneration === generation) loading.value = false }
}
// 打开调整层；参数：kind 为金额或利率，row 为点击期次，省略时优先本月起未还期次、逾期未还、最后首个历史期次；返回无，第三栏保留上一层状态。
function openAdjustment(kind: 'rate' | 'payment', row?: LoanPayment) {
  const today = new Date(); const month = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}`
  const unpaid = eligible.value.filter(item => item.period > (plan.value?.paidPeriods ?? 0))
  const target = row ?? unpaid.find(item => item.date.slice(0, 7) >= month) ?? unpaid[0] ?? eligible.value[0]
  if (!target || !canAdjust(target)) return
  Object.assign(draft, { kind, fromPeriod: target.period, annualRate: target.annualRate ?? props.account.loanAnnualRate ?? '0', payment: target.payment })
  preview.value = null; error.value = ''; adjusting.value = true
}
// 构造白名单请求；参数无；返回带版本的变更，reprice 明确表示调息并校准本期账单，旧服务端拒绝未知操作。
function payload(): LoanAdjustmentRequest {
  const base = { revision: plan.value?.revision ?? 0, fromPeriod: draft.fromPeriod }
  return draft.kind === 'rate'
    ? { ...base, kind: 'rate', annualRate: draft.annualRate }
    : { ...base, kind: 'reprice', scope: 'period', payment: draft.payment, annualRate: draft.annualRate }
}
// 预览当前输入；参数无；返回完成 Promise；表单锁定避免预览期间变更草稿。
async function calculate() {
  if (busy.value || !valid.value) return
  const requestGeneration = ++generation
  busy.value = true; error.value = ''; preview.value = null
  try { const result = await previewLoanAdjustment(props.account.id, payload()); if (requestGeneration === generation) preview.value = result }
  catch { if (requestGeneration === generation) error.value = '试算未完成，请检查输入；计划有变化时请刷新' }
  finally { if (requestGeneration === generation) busy.value = false }
}
// 保存已预览请求；参数无；返回完成 Promise；保存失败清除预览，成功更新第三栏并通知列表刷新。
async function save() {
  if (busy.value || !preview.value) return
  const requestGeneration = ++generation
  busy.value = true; error.value = ''
  try { const result = await saveLoanAdjustment(props.account.id, payload()); if (requestGeneration === generation) { plan.value = result; adjusting.value = false; ElMessage.success('贷款计划已调整'); emit('changed') } }
  catch { if (requestGeneration === generation) { preview.value = null; error.value = '保存未完成，请刷新计划后重新试算' } }
  finally { if (requestGeneration === generation) busy.value = false }
}
</script>

<template>
  <WorkspacePanel v-model="visible" title="贷款计划" :show-close="!busy" :close-on-press-escape="!busy">
    <div v-loading="loading" class="loan-plan-stack">
      <template v-if="plan">
        <section class="loan-plan-card"><strong>{{ account.name }}</strong><dl><dt>贷款本金</dt><dd>{{ money(account.loanPrincipal || '0') }}</dd><dt>计划剩余本金</dt><dd>{{ money(plan.remainingPrincipal) }}</dd><dt>预计总利息</dt><dd>{{ money(plan.totalInterest) }}</dd><dt>已还期数</dt><dd>{{ plan.paidPeriods }} / {{ plan.schedule?.length }}</dd></dl></section>
        <el-radio-group v-model="filter"><el-radio-button value="all">全部</el-radio-button><el-radio-button value="paid">已还</el-radio-button><el-radio-button value="remaining">待还</el-radio-button></el-radio-group>
        <section v-for="row in rows" :key="row.period" class="loan-plan-card loan-period">
          <span class="loan-period-top"><strong>第 {{ row.period }} 期</strong><b>{{ money(row.payment) }}</b></span>
          <small>{{ row.date }} · {{ row.period <= (plan.paidPeriods || 0) ? '已还' : Number(row.payment) === 0 ? '无需还款' : '待还' }}</small>
          <span class="loan-preview-metrics">本金 {{ money(row.principal) }} · 利息 {{ money(row.interest) }} · 年利率 {{ row.annualRate ?? account.loanAnnualRate }}%</span>
          <small v-if="row.customPayment">自定义月供</small>
          <small v-if="row.paymentOverridden && sumMoney([row.payment, `-${row.principal}`, `-${row.interest}`]) !== '0.00'">本期金额修正 {{ paymentCorrection(row) }}</small>
          <div v-if="canAdjust(row)" class="loan-period-actions"><el-button size="small" @click="openAdjustment('payment', row)">金额</el-button><el-button size="small" @click="openAdjustment('rate', row)">利率</el-button></div>
        </section>
      </template>
      <el-alert v-if="error && !adjusting" :title="error" type="error" :closable="false" />
      <el-button v-if="error && !adjusting" @click="load">重试</el-button>
    </div>
  </WorkspacePanel>
  <WorkspacePanel v-model="adjusting" :title="adjustmentTitle" :show-close="!busy && !loading" :close-on-press-escape="!busy && !loading">
    <el-form label-position="top" :disabled="busy || loading" class="loan-plan-stack">
      <el-form-item :label="draft.kind === 'rate' ? '生效期次' : '调整期次'"><el-select v-model="draft.fromPeriod"><el-option v-for="row in eligible" :key="row.period" :value="row.period" :label="`第 ${row.period} 期 · ${row.date}`" /></el-select></el-form-item>
      <el-form-item label="调整后年利率"><el-input v-model="draft.annualRate" inputmode="decimal"><template #suffix>%</template></el-input></el-form-item>
      <el-form-item v-if="draft.kind === 'payment'" label="本期应还金额"><el-input v-model="draft.payment" inputmode="decimal"><template #prefix>￥</template></el-input></el-form-item>
      <p v-if="draft.kind === 'rate'" class="loan-plan-note">从第 {{ draft.fromPeriod }} 期起调整利率，此前各期保持不变。</p>
      <p v-else class="loan-plan-note">本期按账单校准，后续按年利率重算。</p>
      <p v-if="draft.fromPeriod <= (plan?.paidPeriods ?? 0)" class="loan-plan-note">包含已还期次，不改动实际流水和余额。</p>
      <el-button :disabled="!valid" :loading="busy" @click="calculate">预览调整结果</el-button>
      <template v-if="previewRows.length">
        <strong class="loan-preview-title">调整后近 {{ previewRows.length }} 期</strong>
        <section v-for="row in previewRows" :key="row.period" class="loan-plan-card loan-period loan-preview-card">
          <span class="loan-period-top"><strong>第 {{ row.period }} 期</strong><b>{{ money(row.payment) }}</b></span>
          <span class="loan-period-top"><small>{{ row.date }}</small><small>原应还 {{ money(plan?.schedule?.find(item => item.period === row.period)?.payment || '0') }}</small></span>
          <span class="loan-preview-metrics">本金 {{ money(row.principal) }} · 利息 {{ money(row.interest) }} · 年利率 {{ row.annualRate ?? account.loanAnnualRate }}%</span>
          <small v-if="row.paymentOverridden && sumMoney([row.payment, `-${row.principal}`, `-${row.interest}`]) !== '0.00'">本期金额修正 {{ paymentCorrection(row) }}</small>
        </section>
        <p v-if="preview?.lastPaymentPeriod && preview.lastPaymentPeriod < (preview.schedule?.length || 0)" class="loan-plan-note">第 {{ preview.lastPaymentPeriod }} 期结清</p>
      </template>
      <el-alert v-if="error" :title="error" type="error" :closable="false" /><el-button v-if="error" @click="load">刷新计划</el-button>
    </el-form>
    <template #footer><el-button :disabled="busy || loading" @click="adjusting = false">返回</el-button><el-button type="primary" :disabled="!preview || loading" :loading="busy" @click="save">保存调整</el-button></template>
  </WorkspacePanel>
</template>

<style scoped>
.loan-plan-stack { display: grid; gap: 14px; }
.loan-plan-card { background: var(--el-bg-color); padding: 16px; border: 1px solid var(--el-border-color-lighter); border-radius: 16px; min-width: 0; }
.loan-plan-card dl { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr); gap: 10px; font-size: 13px; }
.loan-plan-card dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.loan-period { display: grid; gap: 8px; text-align: left; color: var(--el-text-color-primary); font: inherit; cursor: default; }
.loan-period-actions { display: flex; justify-content: flex-end; gap: 8px; }
.loan-period-actions :deep(.el-button + .el-button) { margin-left: 0; }
.loan-preview-card .loan-period-top b { color: var(--el-color-primary); font-size: 18px; }
.loan-preview-title { font-size: 14px; margin-top: 8px; }
.loan-preview-metrics { white-space: nowrap; overflow-x: auto; }
.loan-period-top { display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; font-variant-numeric: tabular-nums; }
.loan-period small, .loan-period > span:not(.loan-period-top), .loan-plan-note { font-size: 12px; color: var(--el-text-color-secondary); margin: 0; line-height: 1.6; }
.loan-plan-stack :deep(.el-form-item) { margin-bottom: 0; }
.loan-plan-stack :deep(.el-radio-group) { flex-wrap: wrap; }
</style>
