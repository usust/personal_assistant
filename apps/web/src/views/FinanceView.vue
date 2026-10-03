<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Plus, Refresh } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { getAccounts, getCategories, getFinanceOverview } from '@/api/finance'
import OverviewTab from '@/finance/components/OverviewTab.vue'
import AccountsTab from '@/finance/components/AccountsTab.vue'
import TransactionsTab from '@/finance/components/TransactionsTab.vue'
import FinanceIcon from '@/finance/components/FinanceIcon.vue'
import type { FinanceOverview, FinancialAccount, TransactionCategory } from '@/types/finance'

const activeTab = ref('overview')
const loading = ref(true)
const accounts = ref<FinancialAccount[]>([])
const categories = ref<TransactionCategory[]>([])
const overview = ref<FinanceOverview>({ totalAssets: '0.00', totalLiabilities: '0.00', netWorth: '0.00', monthIncome: '0.00', monthExpense: '0.00', monthBalance: '0.00', savingsRate: null, debtRatio: null, accountCount: 0, assetStructure: [], netWorthTrend: [], cashFlow: [], expenseCategories: [], upcoming: [] })
const accountsTab = ref<InstanceType<typeof AccountsTab>>()
const transactionsTab = ref<InstanceType<typeof TransactionsTab>>()

// 刷新账户、分类和总览；参数：showMessage 是否显示成功提示；返回值：完成 Promise，错误由 HTTP 层展示。
async function loadAll(showMessage = false) {
  loading.value = true
  try {
    const [overviewData, accountData, categoryData] = await Promise.all([getFinanceOverview(), getAccounts(), getCategories()])
    overview.value = overviewData; accounts.value = accountData; categories.value = categoryData
    await transactionsTab.value?.load()
    if (showMessage) ElMessage.success('财务数据已刷新')
  } finally { loading.value = false }
}
// 刷新分类选项；参数：无；返回值：完成 Promise。
async function refreshCategories() { categories.value = await getCategories() }
// 切换账户页并打开弹窗；参数：无；返回值：无；动画回调无输入输出。
function addAccount() { activeTab.value = 'accounts'; requestAnimationFrame(() => accountsTab.value?.openCreate()) }
// 切换流水页并打开弹窗；参数：无；返回值：无；动画回调无输入输出。
function addTransaction() { activeTab.value = 'transactions'; requestAnimationFrame(() => transactionsTab.value?.openCreate()) }
onMounted(loadAll)
</script>

<template>
  <div class="finance-page" v-loading="loading">
    <div class="finance-page-header"><div><p class="eyebrow">PERSONAL FINANCE</p><h1>财务管理</h1><span>记录每一笔收支 · CNY · AI 草稿需确认入账</span></div><div><el-button :icon="Refresh" @click="loadAll(true)">刷新</el-button><el-button type="primary" :icon="Plus" @click="addTransaction">记录流水</el-button></div></div>
    <nav class="finance-tabs"><button v-for="tab in [{ key: 'overview', label: '总览', icon: 'wallet' }, { key: 'accounts', label: '账户', icon: 'bank' }, { key: 'transactions', label: '流水', icon: 'transfer' }]" :key="tab.key" :class="{ active: activeTab === tab.key }" @click="activeTab = tab.key"><FinanceIcon :kind="tab.icon" :size="22" />{{ tab.label }}</button></nav>
    <OverviewTab v-if="activeTab === 'overview'" :overview="overview" :accounts="accounts" @add-account="addAccount" @add-transaction="addTransaction" />
    <AccountsTab v-else-if="activeTab === 'accounts'" ref="accountsTab" :accounts="accounts" @changed="loadAll" />
    <TransactionsTab v-else-if="activeTab === 'transactions'" ref="transactionsTab" :accounts="accounts" :categories="categories" @changed="loadAll" @categories-changed="refreshCategories" />
  </div>
</template>
