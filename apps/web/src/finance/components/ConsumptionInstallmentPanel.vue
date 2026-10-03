<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { confirmInPanel } from '@/composables/workspacePanels'
import { getConsumptionInstallment, previewConsumptionInstallment, createConsumptionInstallment } from '@/api/finance'
import type { ConsumptionInstallmentPlan, FinanceTransaction } from '@/types/finance'
import { money, today } from '@/finance/utils/money'
const props = defineProps<{ bill: FinanceTransaction | null; accountName: string }>()
const emit = defineEmits<{ closed: []; changed: []; busy: [value: boolean] }>()
const visible = ref(false)
const busy = ref(false)
// 同步提交锁定；参数：value 为忙碌状态；返回值：无，阻止父列表在请求期间切换账单。
watch(busy, value => emit('busy', value), { flush: 'sync' })
const saved = ref(false)
const plan = ref<ConsumptionInstallmentPlan | null>(null)
const draft = reactive({ name: '', periods: 12, firstDate: today(), interest: '0.00', interestMode: 'spread', rounding: 'round', remainder: 'first' })
// 计算计划主账单 ID；参数：无；返回值：主账单 ID 或零，不修改数据。
const parentId = computed(() => props.bill?.installmentParentId ?? props.bill?.id ?? 0)
// 打开目标账单；参数：bill 为用户选中账单或空；返回值：完成 Promise，切换目标后不应用旧响应。
watch(() => props.bill, async bill => {
  if (!bill) return
  visible.value = true; plan.value = null
  saved.value = bill.status === 'installment' || !!bill.installmentParentId
  Object.assign(draft, { name: bill.counterparty || '消费分期', periods: 12, firstDate: bill.transactionDate, interest: '0.00', interestMode: 'spread', rounding: 'round', remainder: 'first' })
  if (saved.value) { busy.value = true; try { const result = await getConsumptionInstallment(parentId.value); if (props.bill === bill) plan.value = result } finally { busy.value = false } }
})
// 修改规则时撤销旧预览；参数：无；返回值：无，避免保存与屏幕不一致的计划。
watch(draft, () => { if (!saved.value) plan.value = null }, { flush: 'sync' })
// 请求精确试算；参数：无；返回值：完成 Promise，不写入账本。
async function preview() {
  if (busy.value) return
  busy.value = true; plan.value = null
  try { plan.value = await previewConsumptionInstallment(parentId.value, { ...draft }) } finally { busy.value = false }
}
// 确认并保存消费分期；参数：无；返回值：完成 Promise，取消不写入，保存期间禁止关闭。
async function save() {
  if (busy.value) return
  const id = parentId.value
  const payload = { ...draft }
  busy.value = true
  try {
    try { await confirmInPanel('原支出将冲回，每期到期自动入账后计入支出和欠款。', '保存消费分期') } catch { return }
    plan.value = await createConsumptionInstallment(id, payload); saved.value = true; emit('changed')
  } finally { busy.value = false }
}
</script>
<template>
  <WorkspacePanel v-model="visible" title="消费分期" :show-close="!busy" :close-on-press-escape="!busy" @closed="emit('closed')">
    <el-form v-if="!saved" label-position="top" :disabled="busy">
      <el-form-item label="分期名称"><el-input v-model="draft.name" maxlength="128" /></el-form-item>
      <el-descriptions :column="1"><el-descriptions-item label="分期本金">{{ money(bill?.amount || '0') }}</el-descriptions-item><el-descriptions-item label="分期账户">{{ accountName }}</el-descriptions-item><el-descriptions-item label="账单币种">人民币 (CNY)</el-descriptions-item></el-descriptions>
      <el-divider content-position="left">分期设置</el-divider>
      <el-form-item label="分期总期数"><el-input-number v-model="draft.periods" :min="2" :max="480" :precision="0" /></el-form-item>
      <el-form-item label="首期入账日期"><el-date-picker v-model="draft.firstDate" type="date" value-format="YYYY-MM-DD" /></el-form-item>
      <el-form-item label="欠款计入方式">分期计入</el-form-item>
      <el-form-item label="利息总额"><el-input v-model="draft.interest" inputmode="decimal" /></el-form-item>
      <el-form-item label="利息入账方式"><el-select v-model="draft.interestMode"><el-option label="分期入账" value="spread" /><el-option label="首期入账" value="first" /></el-select></el-form-item>
      <el-divider content-position="left">余数计算规则</el-divider>
      <el-form-item label="计算方式"><el-select v-model="draft.rounding"><el-option label="四舍五入" value="round" /><el-option label="向下取整" value="floor" /></el-select></el-form-item>
      <el-form-item label="计算精度">小数点后 2 位</el-form-item>
      <el-form-item label="分期后差额纳入"><el-select v-model="draft.remainder"><el-option label="首期" value="first" /><el-option label="末期" value="last" /></el-select></el-form-item>
    </el-form>
    <template v-if="plan">
      <h3>{{ saved ? plan.name : '分期试算' }}</h3>
      <p>本息 {{ money(plan.total) }} · 已入账 {{ plan.posted }} / {{ plan.periods }} 期</p>
      <article v-for="row in plan.rows" :key="row.period" class="installment-row">
        <div><strong>第 {{ row.period }} 期</strong><strong>{{ money(row.amount) }}</strong></div>
        <small>{{ row.date }} · 本金 {{ row.principal }} · 利息 {{ row.interest }}</small>
        <small v-if="saved && row.status === 'pending'">待入账</small>
        <small v-else-if="saved">{{ row.status === 'deleted' ? '已删除' : '已入账' }}</small>
      </article>
    </template>
    <template #footer>
      <el-button v-if="!saved" :loading="busy" @click="preview">试算分期</el-button>
      <el-button v-if="!saved && plan" type="primary" :disabled="busy" @click="save">保存分期</el-button>
    </template>
  </WorkspacePanel>
</template>
<style scoped>
.installment-row { padding: 14px 0; border-bottom: 1px solid var(--el-border-color-lighter); display: grid; gap: 8px; }
.installment-row > div { display: flex; justify-content: space-between; gap: 12px; }
.installment-row small { color: var(--el-text-color-secondary); }
.el-date-editor { max-width: 100%; }
</style>
