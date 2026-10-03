<script setup lang="ts">
import { confirmInPanel } from '@/composables/workspacePanels'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, reactive, ref, watch, nextTick } from 'vue'
import { Plus, Search } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { getFinancePresets, createFinancePreset, updateFinancePreset, deleteFinancePreset, materializeRecurring, confirmTransaction, voidTransaction, createCategory, createTransaction, getTransactions } from '@/api/finance'
import { money, sumMoney, today } from '@/finance/utils/money'
import type { FinancePreset, FinanceTransaction, FinancialAccount, TransactionCategory, TransactionFilter, TransactionType } from '@/types/finance'
import FinanceIcon from './FinanceIcon.vue'
import ConsumptionInstallmentPanel from './ConsumptionInstallmentPanel.vue'
const installmentBill = ref<FinanceTransaction | null>(null)
const installmentBusy = ref(false)
const presets = ref<FinancePreset[]>([])
const presetsVisible = ref(false)
const saveMode = ref('transaction')
const presetName = ref('')
const frequency = ref<FinancePreset['frequency']>('monthly')
const endDate = ref('')
const frequencyNames = { daily: '每天', weekly: '每周', monthly: '每月', yearly: '每年' }
// 读取模板并补齐到期草稿；参数无；返回值完成 Promise，失败沿用全局错误提示。
async function loadPresets() { presets.value = await getFinancePresets() }
// 打开模板及周期管理；参数无；返回值完成 Promise。
async function openPresets() { await loadPresets(); presetsVisible.value = true }
// 应用模板到新流水；参数 item 为自己的模板；返回值完成 Promise，等待类型监听清空后填入关联字段。
async function usePreset(item: FinancePreset) { openCreate(); draft.type = item.transaction.type || 'expense'; await nextTick(); Object.assign(draft, item.transaction, { transactionDate: today() }); presetsVisible.value = false }
// 暂停或恢复周期；参数 item 为计划；返回值完成 Promise，恢复后补齐草稿。
async function togglePreset(item: FinancePreset) { if (saving.value) return; saving.value = true; try { await updateFinancePreset(item.id, { enabled: !item.enabled }); await materializeRecurring(); await loadPresets(); await load() } finally { saving.value = false } }
// 删除计划或模板；参数 item 为记录；返回值完成 Promise，确认取消不删除，既有流水保留。
async function removePreset(item: FinancePreset) { try { await confirmInPanel(`删除“${item.name}”？已生成的流水将保留。`, '删除') } catch { return }; saving.value = true; try { await deleteFinancePreset(item.id); await loadPresets() } finally { saving.value = false } }


const props = defineProps<{ accounts: FinancialAccount[]; categories: TransactionCategory[] }>()
const emit = defineEmits<{ changed: []; categoriesChanged: [] }>()
const items = ref<FinanceTransaction[]>([])
const loading = ref(false)
const visible = ref(false)
const saving = ref(false)
const acting = ref(false)
const page = ref(0)
const pageSize = 100
const requestId = ref('')
const requestPayload = ref('')
const categoryVisible = ref(false)
const filter = reactive<TransactionFilter>({ startDate: '', endDate: '', type: '', accountId: undefined, categoryId: undefined, minAmount: '', maxAmount: '', keyword: '' })
const draft = reactive({ accountId: 0, targetAccountId: undefined as number | undefined, type: 'expense' as TransactionType, amount: '', fee: '0.00', rebate: '0.00', rebateAccountId: undefined as number | undefined, rebatePending: false, categoryId: undefined as number | undefined, counterparty: '', transactionDate: today(), description: '' })
const categoryDraft = reactive({ name: '', type: 'expense' as 'income' | 'expense', color: '#5658cf' })
const accountMap = computed(() => Object.fromEntries(props.accounts.map(item => [item.id, item.name])))
const categoryMap = computed(() => Object.fromEntries(props.categories.map(item => [item.id, item.name])))
const visibleCategories = computed(() => props.categories.filter(item => item.type === draft.type))
// 收支派生回调：无参数，返回当前页已入账收入；筛选回调接收流水、返回布尔值，映射回调接收流水、返回金额。
const income = computed(() => sumMoney(items.value.filter(item => item.type === 'income' && item.status === 'posted').map(item => item.amount)))
// 支出派生回调：无参数，返回当前页已入账支出；筛选和映射回调分别返回状态匹配值与金额。
const expense = computed(() => sumMoney(items.value.filter(item => item.status === 'posted').flatMap(item => [item.type === 'expense' ? item.amount : '0.00', item.fee || '0.00'])))
const net = computed(() => sumMoney([income.value, `-${expense.value}`]))

// 读取一页流水；参数：无；返回值：完成 Promise，失败时保留原列表。
async function load() { loading.value = true; try { items.value = await getTransactions({ ...filter, limit: pageSize, offset: page.value * pageSize }) } finally { loading.value = false } }
// 应用筛选并返回第一页；参数：无；返回值：加载 Promise。
async function search() { page.value = 0; await load() }
// 翻页；参数：delta 为 -1 或 1；返回值：加载 Promise，失败回退页码。
async function turnPage(delta: number) { page.value += delta; try { await load() } catch (error) { page.value -= delta; throw error } }
// 用户确认或作废流水；参数：item 为选中流水，action 为确认或作废；返回值：完成 Promise，取消不改变余额。
async function act(item: FinanceTransaction, action: 'confirm' | 'void') {
  try { await confirmInPanel(`${action === 'confirm' ? '确认入账' : '作废'} ${item.transactionDate} 的 ${money(item.amount)} ${item.type === 'income' ? '收入' : item.type === 'expense' ? '支出' : '转账'}，账户：${accountMap.value[item.accountId] || '已归档账户'}${item.targetAccountId ? ' → ' + (accountMap.value[item.targetAccountId] || '已归档账户') : ''}，${item.counterparty || item.description || '无说明'}${Number(item.fee) ? '，手续费 ' + money(item.fee || '0.00') : ''}${Number(item.rebate) ? '，关联优惠 ' + money(item.rebate || '0.00') + (action === 'void' ? ' 将一并撤销' : '') : ''}${item.rebateParentId && action === 'confirm' ? '，优惠按今天到账入账' : ''}？`, '核对流水', { type: 'warning' }) } catch { return }
  acting.value = true
  try { action === 'confirm' ? await confirmTransaction(item.id) : await voidTransaction(item.id); await load(); emit('changed'); emit('categoriesChanged') } finally { acting.value = false }
}
// 打开第三栏记账表单；参数：无；返回值：无，新的填写流程重置幂等键。
function openCreate() { saveMode.value = 'transaction'; presetName.value = ''; endDate.value = ''; requestId.value = ''; requestPayload.value = '';  Object.assign(draft, { accountId: props.accounts.find(item => item.selectable !== false)?.id ?? 0, targetAccountId: undefined, type: 'expense', amount: '', fee: '0.00', rebate: '0.00', rebateAccountId: undefined as number | undefined, rebatePending: false, categoryId: undefined, counterparty: '', transactionDate: today(), description: '' }); visible.value = true }
// 保存流水、模板或周期计划；参数：无；返回值：完成 Promise，相同载荷失败重试复用幂等键，内容修改生成新键。
async function save() {
  if (saving.value) return
  if (!draft.accountId || !draft.amount || !draft.transactionDate) { ElMessage.warning('请填写账户、金额和日期'); return }
  if (draft.type === 'transfer' && !draft.targetAccountId) { ElMessage.warning('请选择转入账户'); return }
  if (saveMode.value !== 'transaction' && !presetName.value.trim()) { ElMessage.warning('请填写名称'); return }
  const payload = { ...draft, rebate: draft.type === 'transfer' ? (draft.rebate || '0.00') : '0.00', rebateAccountId: draft.type === 'transfer' && Number(draft.rebate) > 0 ? (draft.rebateAccountId || draft.accountId) : null, rebatePending: draft.type === 'transfer' && Number(draft.rebate) > 0 && draft.rebatePending, fee: draft.type === 'transfer' ? (draft.fee || '0.00') : '0.00', categoryId: draft.type === 'transfer' ? null : (draft.categoryId ?? null), targetAccountId: draft.type === 'transfer' ? (draft.targetAccountId ?? null) : null, targetCreditCardId: null }
  const canonical = JSON.stringify({ payload, mode: saveMode.value, name: presetName.value, frequency: frequency.value, endDate: endDate.value })
  if (canonical !== requestPayload.value) { requestId.value = crypto.randomUUID(); requestPayload.value = canonical }
  saving.value = true
  try {
    if (saveMode.value === 'transaction') { await createTransaction({ ...payload, requestId: requestId.value }); ElMessage.success('流水已入账') }
    else { await createFinancePreset({ key: requestId.value, name: presetName.value, transaction: payload, frequency: saveMode.value === 'recurring' ? frequency.value : '', startDate: draft.transactionDate, endDate: endDate.value || '' }); await materializeRecurring(); ElMessage.success('已保存'); await loadPresets() }
 visible.value = false; await search(); emit('changed'); emit('categoriesChanged') } finally { saving.value = false }
}
// 创建个人分类；参数：无；返回值：完成 Promise，成功后刷新父页面选项。
async function saveCategory() { if (!categoryDraft.name.trim()) return; await createCategory(categoryDraft); ElMessage.success('分类已添加'); categoryVisible.value = false; categoryDraft.name = ''; emit('categoriesChanged') }
// 类型监听：读取类型并清除不兼容关联；回调无参数、无返回值。
watch(() => draft.type, () => { draft.categoryId = undefined; draft.targetAccountId = undefined; draft.rebate = '0.00'; draft.rebateAccountId = undefined; draft.rebatePending = false })
// 账户监听：读取账户数量并选择默认账户；回调无参数、无返回值。
watch(() => props.accounts.length, () => { if (!draft.accountId) draft.accountId = props.accounts.find(item => item.selectable !== false)?.id ?? 0 }, { immediate: true })
// 初始化补齐到期草稿后读取列表；回调参数无，返回加载 Promise。
materializeRecurring().then(() => load())
defineExpose({ openCreate, load })
</script>

<template>
  <div class="finance-tab-stack">
    <div class="finance-filter-panel">
      <div class="finance-filters"><el-date-picker v-model="filter.startDate" value-format="YYYY-MM-DD" type="date" placeholder="开始日期" /><el-date-picker v-model="filter.endDate" value-format="YYYY-MM-DD" type="date" placeholder="结束日期" /><el-select v-model="filter.accountId" clearable placeholder="全部账户"><el-option v-for="item in accounts" :key="item.id" :label="item.name" :value="item.id" /></el-select><el-select v-model="filter.type" placeholder="全部类型"><el-option label="全部类型" value="" /><el-option label="收入" value="income" /><el-option label="支出" value="expense" /><el-option label="转账" value="transfer" /></el-select><el-select v-model="filter.categoryId" clearable placeholder="全部分类"><el-option v-for="item in categories" :key="item.id" :label="item.name" :value="item.id" /></el-select><el-input v-model="filter.minAmount" placeholder="最低金额" /><el-input v-model="filter.maxAmount" placeholder="最高金额" /><el-input v-model="filter.keyword" class="keyword-filter" clearable placeholder="商户或说明"><template #prefix><Search /></template></el-input><el-select v-model="filter.status" clearable placeholder="全部状态"><el-option label="待确认" value="pending" /><el-option label="已入账" value="posted" /><el-option label="已作废" value="voided" /><el-option label="分期主账单" value="installment" /></el-select><el-button @click="search">筛选</el-button><el-button @click="openPresets">模板与周期</el-button><el-button type="primary" :icon="Plus" @click="openCreate">记录流水</el-button></div>
      <div class="transaction-summary"><span>当前页已入账合计（不含草稿和作废）</span><div><small>收入</small><b class="positive">+{{ money(income) }}</b></div><div><small>支出</small><b class="negative">-{{ money(expense) }}</b></div><div><small>净流入</small><b :class="Number(net) >= 0 ? 'positive' : 'negative'">{{ money(net) }}</b></div></div>
    </div>
    <article class="finance-panel finance-table-panel">
      <el-table v-if="items.length || loading" v-loading="loading" :data="items" table-layout="fixed"><el-table-column prop="transactionDate" label="日期" width="115" /><el-table-column label="账户" min-width="130"><template #default="scope">{{ accountMap[scope.row.accountId] || '已归档账户' }}<span v-if="scope.row.targetAccountId"> → {{ accountMap[scope.row.targetAccountId] || '已归档账户' }}</span></template></el-table-column><el-table-column label="类型" width="105"><template #default="scope"><span class="transaction-type" :class="scope.row.type"><FinanceIcon :kind="scope.row.type" :size="22" />{{ scope.row.type === 'income' ? '收入' : scope.row.type === 'expense' ? '支出' : '转账' }}</span></template></el-table-column><el-table-column label="分类" width="110"><template #default="scope">{{ scope.row.rebateParentId ? '还款优惠' : scope.row.type === 'transfer' ? '内部转账' : categoryMap[scope.row.categoryId] || '未分类' }}</template></el-table-column><el-table-column label="商户 / 对方" min-width="140"><template #default="scope">{{ scope.row.counterparty || '--' }}</template></el-table-column><el-table-column prop="description" label="说明" min-width="180" show-overflow-tooltip /><el-table-column label="金额" width="140" align="right"><template #default="scope"><strong :class="scope.row.type === 'income' ? 'positive' : scope.row.type === 'expense' ? 'negative' : ''">{{ scope.row.type === 'income' ? '+' : scope.row.type === 'expense' ? '-' : '' }}{{ money(scope.row.amount) }}</strong></template></el-table-column><el-table-column label="手续费" width="110"><template #default="scope">{{ Number(scope.row.fee) ? money(scope.row.fee) : '—' }}</template></el-table-column><el-table-column label="优惠" min-width="160"><template #default="scope"><span v-if="Number(scope.row.rebate)">{{ money(scope.row.rebate) }} → {{ accountMap[scope.row.rebateAccountId || scope.row.accountId] || '已归档账户' }}</span><span v-else-if="scope.row.rebateParentId">转账 #{{ scope.row.rebateParentId }}</span><span v-else>—</span></template></el-table-column><el-table-column label="状态" width="100"><template #default="scope">{{ scope.row.status === 'installment' ? '分期主账单' : scope.row.status === 'pending' ? (scope.row.installmentParentId ? '待入账' : '待确认') : scope.row.status === 'voided' ? '已作废' : '已入账' }}<small v-if="scope.row.source === 'ai'"> · AI</small><small v-if="scope.row.source === 'recurring'"> · 周期</small></template></el-table-column><el-table-column label="操作" width="190"><template #default="scope"><el-button v-if="scope.row.status === 'pending' && !scope.row.installmentParentId" link type="primary" :disabled="acting" @click="act(scope.row, 'confirm')">确认入账</el-button><el-button v-if="scope.row.status !== 'voided' && scope.row.status !== 'installment' && !scope.row.installmentParentId && !scope.row.rebateParentId" link type="danger" :disabled="acting" @click="act(scope.row, 'void')">作废</el-button><el-button v-if="scope.row.status === 'installment' || scope.row.installmentParentId || (scope.row.type === 'expense' && scope.row.status === 'posted')" link type="primary" :disabled="installmentBusy" @click="installmentBill = scope.row">{{ scope.row.status === 'installment' || scope.row.installmentParentId ? '查看分期' : '转为分期' }}</el-button></template></el-table-column></el-table>
      <div v-else class="finance-empty"><FinanceIcon kind="transfer" :size="48" /><strong>暂无收支流水</strong><span>记录第一笔收入、支出或内部转账，开始形成现金流分析。</span><el-button type="primary" @click="openCreate">记录流水</el-button></div>
      <div class="finance-inline-summary"><el-button :disabled="page === 0 || loading" @click="turnPage(-1)">上一页</el-button><span>第 {{ page + 1 }} 页 · 每页 {{ pageSize }} 条</span><el-button :disabled="items.length < pageSize || loading" @click="turnPage(1)">下一页</el-button></div>
    </article>

    <ConsumptionInstallmentPanel :bill="installmentBill" :account-name="accountMap[installmentBill?.accountId || 0] || '已归档账户'" @busy="installmentBusy = $event" @closed="installmentBill = null" @changed="load(); emit('changed')" />
    <WorkspacePanel v-model="visible" title="记录流水" :show-close="!saving" :close-on-press-escape="!saving"><el-form label-position="top" :disabled="saving">
      <el-form-item label="保存为"><el-radio-group v-model="saveMode"><el-radio-button value="transaction">流水</el-radio-button><el-radio-button value="template">模板</el-radio-button><el-radio-button value="recurring">周期计划</el-radio-button></el-radio-group></el-form-item>
      <el-form-item v-if="saveMode !== 'transaction'" label="名称" required><el-input v-model="presetName" maxlength="40" /></el-form-item>
      <template v-if="saveMode === 'recurring'"><el-form-item label="重复周期"><el-select v-model="frequency"><el-option v-for="(name, key) in frequencyNames" :key="key" :label="name" :value="key" /></el-select></el-form-item><el-form-item label="截止日期"><el-date-picker v-model="endDate" value-format="YYYY-MM-DD" placeholder="不限" /></el-form-item><p>到期生成待确认流水。</p></template><el-form-item label="类型" required><el-radio-group v-model="draft.type"><el-radio-button value="expense">支出</el-radio-button><el-radio-button value="income">收入</el-radio-button><el-radio-button value="transfer">内部转账</el-radio-button></el-radio-group></el-form-item><div class="finance-form-grid"><el-form-item :label="draft.type === 'transfer' ? '转出账户' : '账户'" required><el-select v-model="draft.accountId"><el-option v-for="item in accounts.filter(item => item.selectable !== false)" :key="item.id" :label="`${item.name} ${item.maskedAccountNumber}`" :value="item.id" /></el-select></el-form-item><el-form-item :label="draft.type === 'transfer' ? '转入金额' : '金额'" required><el-input v-model="draft.amount" inputmode="decimal"><template #prepend>￥</template></el-input></el-form-item><template v-if="draft.type === 'transfer'"><el-form-item label="手续费（转出账户支付）"><el-input v-model="draft.fee" inputmode="decimal" /></el-form-item><el-form-item label="优惠金额"><el-input v-model="draft.rebate" inputmode="decimal" /></el-form-item><template v-if="Number(draft.rebate) > 0"><el-form-item label="优惠到账账户"><el-select v-model="draft.rebateAccountId" clearable placeholder="转出账户"><el-option v-for="item in accounts.filter(item => item.selectable !== false)" :key="item.id" :label="item.name" :value="item.id" /></el-select></el-form-item><el-form-item label="优惠到账状态"><el-radio-group v-model="draft.rebatePending"><el-radio-button :value="false">已到账</el-radio-button><el-radio-button :value="true">待到账</el-radio-button></el-radio-group></el-form-item></template><el-form-item label="转入账户"><el-select v-model="draft.targetAccountId" clearable placeholder="普通内部转账"><el-option v-for="item in accounts.filter(item => item.id !== draft.accountId && item.selectable !== false)" :key="item.id" :label="item.name" :value="item.id" /></el-select></el-form-item></template><template v-else><el-form-item label="分类"><div class="category-field"><el-select v-model="draft.categoryId" clearable><el-option v-for="item in visibleCategories" :key="item.id" :label="item.name" :value="item.id" /></el-select><el-button @click="categoryDraft.type = draft.type as 'income' | 'expense'; categoryVisible = true">自定义</el-button></div></el-form-item><el-form-item label="商户 / 对方"><el-input v-model="draft.counterparty" /></el-form-item></template><el-form-item :label="saveMode === 'recurring' ? '开始日期' : '交易日期'" required><el-date-picker v-model="draft.transactionDate" value-format="YYYY-MM-DD" type="date" /></el-form-item></div><el-form-item label="说明"><el-input v-model="draft.description" type="textarea" :rows="2" /></el-form-item></el-form><template #footer><el-button :disabled="saving" @click="visible = false">取消</el-button><el-button type="primary" :loading="saving" @click="save">保存</el-button></template></WorkspacePanel>
    <WorkspacePanel v-model="presetsVisible" title="模板与周期" :show-close="!saving" :close-on-press-escape="!saving">
      <el-empty v-if="!presets.length" description="暂无模板或周期计划" />
      <article v-for="item in presets" :key="item.id" class="finance-panel" style="padding:16px;margin-bottom:12px">
        <strong>{{ item.name }}</strong><p>{{ money(item.transaction.amount || '0') }} · {{ item.frequency ? frequencyNames[item.frequency] : '模板' }}</p>
        <p v-if="item.frequency">{{ item.enabled ? '下期：' + item.nextDate : '已暂停 / 结束' }}</p><p v-if="item.lastError" class="negative">{{ item.lastError }}</p>
        <el-button v-if="!item.frequency" :disabled="saving" @click="usePreset(item)">使用模板</el-button>
        <el-button v-else :disabled="saving" @click="togglePreset(item)">{{ item.enabled ? '暂停' : '恢复' }}</el-button>
        <el-button type="danger" link :disabled="saving" @click="removePreset(item)">删除</el-button>
      </article>
      <template #footer><el-button :disabled="saving" @click="openCreate(); saveMode = 'template'">新建模板</el-button><el-button type="primary" :disabled="saving" @click="openCreate(); saveMode = 'recurring'">新建周期</el-button></template>
    </WorkspacePanel>
    <WorkspacePanel v-model="categoryVisible" title="添加自定义分类"><el-form label-position="top"><el-form-item label="分类名称"><el-input v-model="categoryDraft.name" /></el-form-item><el-form-item label="类型"><el-radio-group v-model="categoryDraft.type"><el-radio value="income">收入</el-radio><el-radio value="expense">支出</el-radio></el-radio-group></el-form-item></el-form><template #footer><el-button @click="categoryVisible = false">取消</el-button><el-button type="primary" @click="saveCategory">添加</el-button></template></WorkspacePanel>
  </div>
</template>
