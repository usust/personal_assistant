<script setup lang="ts">
import { confirmInPanel } from '@/composables/workspacePanels'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, reactive, ref } from 'vue'
import { Delete, Edit, Plus } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { archiveAccount, createAccount, getAccountImpact, updateAccount } from '@/api/finance'
import { money, sumMoney } from '@/finance/utils/money'
import { accountKinds, accountSections, resolveAccountChoice, accountPatch, type AccountChoice } from '@/finance/accountCatalog'
import AccountTypePicker from './AccountTypePicker.vue'
import AccountChoiceIcon from './AccountChoiceIcon.vue'
import LoanAccountFields from './LoanAccountFields.vue'
import LoanAccountPlanPanel from './LoanAccountPlanPanel.vue'
import type { AccountType, FinancialAccount, LoanAccountTerms } from '@/types/finance'
import FinanceIcon from './FinanceIcon.vue'

const props = defineProps<{ accounts: FinancialAccount[] }>()
const emit = defineEmits<{ changed: [] }>()
const visible = ref(false)
const saving = ref(false)
const removing = ref(false)
const editingId = ref<number | null>(null)
const selected = ref<AccountChoice>(accountKinds[0]!)
const pickerVisible = ref(false)
const hasChoice = ref(false)
const original = ref<Record<string, unknown>>({})
const typeLabels: Record<AccountType, string> = { bank: '银行卡', alipay: '支付宝', wechat: '微信支付', cash: '现金', savings: '储蓄', investment: '其他资产', other: '其他' }
const draft = reactive({ creditLimit: '0.00', currentDebt: '0.00', billingDay: 0, repaymentDay: 0, billDayInclusive: true, selectable: true, reminderDays: -1, reminderTime: '10:00', name: '', accountType: 'bank' as AccountType, institution: '', maskedAccountNumber: '', balance: '0.00', availableBalance: '0.00', includeInNetWorth: true, notes: '' })
// 创建贷款草稿；参数无；返回可独立编辑的默认资料，无网络副作用。
function emptyLoan(): Required<LoanAccountTerms> { return { loanPrincipal: '', loanAnnualRate: '', loanMethod: 'annuity', loanPeriods: 12, loanPaidPeriods: 0, loanFirstPaymentDate: '', loanLender: '', loanReceivingAccountId: 0 } }
const loan = ref(emptyLoan())
const loanEnabled = ref(true)
const planAccount = ref<FinancialAccount | null>(null)
const planVisible = ref(false)
// 在第三栏查看已保存贷款计划；参数：item 为有效贷款账户；返回值：无，保留上一层编辑草稿。
function openPlan(item: FinancialAccount) { planAccount.value = item; planVisible.value = true }
// 判断贷款专属入口；参数无；返回是否使用贷款表单，不按名称猜测银行信用卡。
const isLoan = computed(() => selected.value.institution === '贷款')
// 反向转换账本余额；参数 value 为合法金额文本；返回欠款文本，保持小数精度。
function debtFromBalance(value: string) { return value.startsWith('-') ? value.slice(1) : Number(value) === 0 ? '0.00' : '-' + value }
// 构造白名单资料；参数无；返回新增或 PATCH 可用字段，仅编辑贷款发送显式剩余本金。
function accountFields(): Record<string, unknown> {
  const fields: Record<string, unknown> = { name: draft.name.trim(), accountType: draft.accountType, institution: draft.institution, maskedAccountNumber: draft.maskedAccountNumber, includeInNetWorth: draft.includeInNetWorth, notes: draft.notes, selectable: draft.selectable }
  if (isLoan.value) {
    if (loanEnabled.value) Object.assign(fields, loan.value)
    if (editingId.value) fields.currentDebt = draft.currentDebt
  } else if (selected.value.isCredit) Object.assign(fields, { currentDebt: draft.currentDebt, creditLimit: draft.creditLimit, billingDay: draft.billingDay, repaymentDay: draft.repaymentDay, billDayInclusive: draft.billDayInclusive })
  if (selected.value.isCredit) Object.assign(fields, { reminderDays: draft.reminderDays, reminderTime: draft.reminderTime })
  return fields
}
// 计算账户展示余额；参数：item 为账户；返回值：贷款剩余本息的负金额，旧摘要回退剩余本金，其他账户保留账本余额，无写入。
function accountBalance(item: FinancialAccount): string {
  return item.institution === '贷款' && item.loanPlan ? `-${item.loanPlan.remainingTotal ?? item.loanPlan.remainingPrincipal}` : item.balance
}
const total = computed(() => sumMoney(props.accounts.filter(item => item.includeInNetWorth).map(accountBalance)))
// 按产品用途汇总；输入无，输出六类账户分组，保留未知账户于资金类。
const grouped = computed(() => accountSections.map(section => ({ ...section, items: props.accounts.filter(item => resolveAccountChoice(item.accountType, item.institution).section === section.id) })).filter(group => group.items.length))

// 打开新账户选择；参数：无；返回值：无，重置草稿并在第三栏进入类型选择。
function openCreate() { loan.value = emptyLoan(); loanEnabled.value = true; Object.assign(draft, { creditLimit: '0.00', currentDebt: '0.00', billingDay: 0, repaymentDay: 0, billDayInclusive: true, selectable: true, reminderDays: -1, reminderTime: '10:00' }); editingId.value = null; selected.value = accountKinds[0]!; Object.assign(draft, { name: '', accountType: selected.value.type, institution: selected.value.institution, maskedAccountNumber: '', balance: '0.00', availableBalance: '0.00', includeInNetWorth: true, notes: '' }); original.value = {}; hasChoice.value = false; visible.value = true; pickerVisible.value = true }
// 打开账户编辑；参数：item 为选中账户；返回值：无，原始机构完整保留，不用目录匹配结果覆盖历史字段。
function openEdit(item: FinancialAccount) {
  editingId.value = item.id; selected.value = resolveAccountChoice(item.accountType, item.institution)
  Object.assign(draft, { name: item.name, accountType: item.accountType, institution: item.institution, maskedAccountNumber: item.maskedAccountNumber, balance: item.balance, availableBalance: item.availableBalance, includeInNetWorth: item.includeInNetWorth, notes: item.notes, creditLimit: item.creditLimit ?? '0.00', currentDebt: debtFromBalance(item.balance), billingDay: item.billingDay ?? 0, repaymentDay: item.repaymentDay ?? 0, billDayInclusive: item.billDayInclusive ?? true, selectable: item.selectable ?? true, reminderDays: item.reminderDays ?? -1, reminderTime: item.reminderTime || '10:00' })
  loanEnabled.value = Number(item.loanPrincipal || 0) > 0
  loan.value = { loanPrincipal: item.loanPrincipal || '', loanAnnualRate: item.loanAnnualRate || '', loanMethod: item.loanMethod || 'annuity', loanPeriods: item.loanPeriods || 12, loanPaidPeriods: item.loanPaidPeriods || 0, loanFirstPaymentDate: item.loanFirstPaymentDate || '', loanLender: item.loanLender || '', loanReceivingAccountId: item.loanReceivingAccountId || 0 }
  original.value = accountFields(); hasChoice.value = true; pickerVisible.value = false; visible.value = true
}
// 选用类型；参数：choice 为已确定的类型或银行；返回值：无，只改本地草稿，重复选择保留旧机构原文。
function selectChoice(choice: AccountChoice) { hasChoice.value = true; if (choice.id === selected.value.id) return; selected.value = choice; draft.accountType = choice.type; draft.institution = choice.institution }
// 关闭选择层；参数：value 为选择器显示状态；返回值：无，首次选择取消直接退出新增，重新选择取消保留表单。
function changePicker(value: boolean) { pickerVisible.value = value; if (!value && !hasChoice.value) visible.value = false }
// 保存账户；参数：无；返回值：完成 Promise，PATCH 只提交变化字段，金额和文本验证失败时不发送；错误由 HTTP 层展示。
async function save() {
  if (saving.value || !hasChoice.value) return
  const name = draft.name.trim()
  if (!name) { ElMessage.warning('请输入账户名称。'); return }
  // 统计 UTF-8 长度；输入为待保存文本，输出服务端实际校验字节数，无副作用。
  const bytes = (value: string) => new TextEncoder().encode(value).length
  if (bytes(name) > 128 || bytes(draft.institution) > 128 || bytes(draft.notes) > 2000) { ElMessage.warning('名称或备注过长，请缩短。'); return }
  const openingBalance = draft.balance.trim() || '0.00'
  if (!editingId.value && (!/^-?(0|[1-9]\d*)(\.\d{1,2})?$/.test(openingBalance) || Math.abs(Number(openingBalance)) > 1e12)) { ElMessage.warning('请输入有效余额，最多两位小数。'); return }
  const fields = accountFields()
  saving.value = true
  try {
    if (editingId.value) {
      const patch = accountPatch(original.value, fields)
      if (Object.keys(patch).length) await updateAccount(editingId.value, patch)
    } else await createAccount({ ...fields, ...(!selected.value.isCredit ? { balance: openingBalance } : {}) })
    ElMessage.success(editingId.value ? '账户资料已更新' : '账户已创建'); visible.value = false; emit('changed')
  } finally { saving.value = false }
}
// 删除账户；参数：item 为选中账户；返回值：完成 Promise，第三栏确认后软删除，保留历史；请求期间禁止重复操作。
async function remove(item: FinancialAccount) {
  if (removing.value) return
  removing.value = true
  try {
    const impact = await getAccountImpact(item.id)
    if (impact.pending > 0) { ElMessage.warning(`该账户有 ${impact.pending} 条待确认流水，请先在交易流水中确认或作废后再删除。`); return }
    try {
      await confirmInPanel(`当前余额 ${money(item.balance)}。删除后账户将从列表和当前资产统计中移除，关联的 ${impact.transactions} 条流水和 ${impact.snapshots} 条余额历史仍保留。`, `删除“${item.name}”`, { type: 'warning', confirmButtonText: '删除账户', cancelButtonText: '取消' })
    } catch { return }
    await archiveAccount(item.id)
    ElMessage.success('账户已删除，历史记录已保留'); emit('changed')
  } catch { /* HTTP 层已显示服务端错误；保留列表，允许重试。 */ }
  finally { removing.value = false }
}
defineExpose({ openCreate })
</script>

<template>
  <div class="finance-tab-stack">
    <div class="finance-inline-summary"><div><span>总资产</span><strong>{{ money(total) }}</strong></div><div><span>账户数量</span><strong>{{ accounts.length }}</strong></div><div><span>计入净资产</span><strong>{{ accounts.filter(item => item.includeInNetWorth).length }}</strong></div><el-button type="primary" :icon="Plus" @click="openCreate">添加账户</el-button></div>
    <div v-if="accounts.length" class="account-groups">
      <section v-for="group in grouped" :key="group.id"><header><h3>{{ group.title }}</h3><span>{{ group.items.length }} 个账户</span></header><div class="account-card-grid">
        <article v-for="item in group.items" :key="item.id" class="account-card"><div class="account-card-top"><AccountChoiceIcon :icon="resolveAccountChoice(item.accountType, item.institution).icon" :size="38" /><div><strong>{{ item.name }}</strong><small>{{ item.institution || typeLabels[item.accountType] }} {{ item.maskedAccountNumber }}</small></div><el-dropdown trigger="click"><button class="account-more">•••</button><template #dropdown><el-dropdown-menu><el-dropdown-item :icon="Edit" @click="openEdit(item)">编辑</el-dropdown-item><el-dropdown-item v-if="item.institution === '贷款' && item.loanPlan" @click="openPlan(item)">贷款计划 / 调整</el-dropdown-item><el-dropdown-item :icon="Delete" :disabled="removing" divided @click="remove(item)">删除账户</el-dropdown-item></el-dropdown-menu></template></el-dropdown></div><p>{{ item.institution === '贷款' ? '剩余欠款（含利息）' : '当前余额' }}</p><b>{{ money(accountBalance(item)) }}</b><p v-if="item.loanPlan?.totalPayment">总贷款：{{ money(item.loanPlan.totalPayment) }}</p><p v-if="item.loanPlan">{{ item.loanPlan.next ? `第${item.loanPlan.next.period}期 · ${item.loanPlan.next.date} · 应还 ${money(item.loanPlan.next.payment)}` : '计划期数已还清' }}</p><footer><span>{{ item.includeInNetWorth ? '计入净资产' : '不计入净资产' }}</span><time>更新于 {{ item.updatedAt.slice(0, 10) }}</time></footer></article>
      </div></section>
    </div>
    <div v-else class="finance-panel finance-empty"><FinanceIcon kind="wallet" :size="48" /><strong>暂无财务账户</strong><span>选择银行或账户，填写名称即可创建。</span><el-button type="primary" @click="openCreate">添加账户</el-button></div>

    <WorkspacePanel v-if="hasChoice" v-model="visible" :title="editingId ? '编辑账户' : '添加账户'" :show-close="!saving" :close-on-press-escape="!saving" destroy-on-close>
      <!-- 账户资料与统计设置按业务分组，同层即可完成填写；类型选择继续复用第三栏。 -->
      <el-form class="account-editor" label-position="top" :disabled="saving">
        <section class="form-group" aria-label="账户资料">
          <el-form-item label="账户类型" required><button type="button" class="account-type-row account-type-card" :disabled="saving" @click="pickerVisible = true"><AccountChoiceIcon :icon="selected.icon" /><strong>{{ selected.name }}</strong><span class="account-type-chevron" aria-hidden="true">›</span></button></el-form-item>
          <el-form-item label="账户名称" required><el-input v-model="draft.name" :placeholder="isLoan ? '如：住房贷款' : selected.isCredit ? '如：招商银行信用卡 6688' : '如：中国银行储蓄卡 6688'" autocomplete="off" /></el-form-item>
          <el-form-item label="账户备注（选填）"><el-input v-model="draft.notes" type="textarea" :autosize="{ minRows: 1, maxRows: 4 }" placeholder="点击填写备注" /></el-form-item>
        </section>
        <LoanAccountFields v-if="isLoan && loanEnabled" v-model="loan" :accounts="accounts" :editing-id="editingId" @plan="openPlan" />
        <el-button v-else-if="isLoan" @click="loanEnabled = true">补充还款计划</el-button>
        <section v-if="selected.isCredit" class="form-group" aria-label="借款与还款">
          <el-form-item v-if="!isLoan || editingId" :label="isLoan ? '剩余本金' : '当前欠款'"><el-input v-model="draft.currentDebt" inputmode="decimal" /></el-form-item>
          <template v-if="!isLoan">
            <el-form-item label="总信用额度"><el-input v-model="draft.creditLimit" inputmode="decimal" /></el-form-item>
            <el-form-item label="账单日"><el-select v-model="draft.billingDay"><el-option label="未设置" :value="0" /><el-option v-for="day in 31" :key="day" :label="`每月${day}日`" :value="day" /></el-select></el-form-item>
            <el-form-item label="还款日期"><el-select v-model="draft.repaymentDay"><el-option label="未设置" :value="0" /><el-option v-for="day in 31" :key="day" :label="`每月${day}日`" :value="day" /></el-select></el-form-item>
            <el-form-item label="出账日账单计入当期"><el-switch v-model="draft.billDayInclusive" /></el-form-item>
          </template>
          <el-form-item label="还款提醒"><el-select v-model="draft.reminderDays"><el-option label="不提醒" :value="-1" /><el-option label="当天提醒" :value="0" /><el-option v-for="day in [1,3,7]" :key="day" :label="`提前${day}天＋当天`" :value="day" /></el-select></el-form-item>
          <el-form-item v-if="draft.reminderDays >= 0" label="提醒时间"><el-time-select v-model="draft.reminderTime" start="00:00" end="23:59" step="00:01" /></el-form-item>
          <p v-if="draft.reminderDays >= 0" class="account-balance-help">提醒设置需在 iOS 刷新后生效；Web 不发送后台通知。</p>
        </section>
        <section class="form-group" aria-label="余额与统计">
          <el-form-item v-if="!selected.isCredit && !editingId" label="初始余额"><el-input v-model="draft.balance" inputmode="decimal" placeholder="0.00"><template #prefix>￥</template></el-input></el-form-item>
          <el-form-item v-else-if="!selected.isCredit" label="当前余额"><strong>{{ money(draft.balance) }}</strong></el-form-item>
          <el-form-item label="账户币种"><span>人民币（CNY）</span></el-form-item>
          <el-form-item label="计入净资产"><el-switch v-model="draft.includeInNetWorth" aria-label="计入净资产" /></el-form-item>
        </section>
        <el-form-item label="记账时可被选择"><el-switch v-model="draft.selectable" /></el-form-item>
      </el-form>
      <template #footer><el-button :disabled="saving" @click="visible = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">{{ editingId ? '保存修改' : '创建账户' }}</el-button></template>
    </WorkspacePanel>
    <AccountTypePicker v-if="visible" :model-value="pickerVisible" @update:model-value="changePicker" @select="selectChoice" />
    <LoanAccountPlanPanel v-if="planAccount" v-model="planVisible" :account="planAccount" @changed="emit('changed')" />
  </div>
</template>
<style scoped>.account-balance-help { color: var(--el-text-color-secondary); line-height: 1.65; font-size: 13px; margin: 0 0 16px; }</style>
