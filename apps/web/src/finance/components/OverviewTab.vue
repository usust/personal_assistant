<script setup lang="ts">
import { computed } from 'vue'
import FinanceBarChart from './FinanceBarChart.vue'
import FinanceDonut from './FinanceDonut.vue'
import FinanceIcon from './FinanceIcon.vue'
import { money, percent } from '@/finance/utils/money'
import type { FinanceOverview, FinancialAccount } from '@/types/finance'

const props = defineProps<{ overview: FinanceOverview; accounts: FinancialAccount[] }>()
const emit = defineEmits<{ addAccount: []; addTransaction: [] }>()
// 图表派生回调；参数：无，读取总览；返回值：月份及绘图数值，金额汇总仍由后端整数运算完成。
const cashFlow = computed(() => props.overview.cashFlow.map(
  // 转换单个月份；参数：item 为后端月度汇总；返回值：图表数据点，不写回财务金额。
  item => ({ label: item.month.slice(5) + '月', income: Number(item.income), expense: Number(item.expense), net: Number(item.net) }),
))
</script>

<template>
  <div class="finance-tab-stack">
    <el-alert title="统计范围：CNY 账户；月份按 UTC+8。仅统计已入账流水，转账不计入收支。贷款、房贷和信用卡账单尚未接入。" type="info" :closable="false" />
    <div class="finance-stat-grid">
      <article class="finance-stat-card"><FinanceIcon kind="wallet" :size="43" /><div><p>账户总资产</p><strong>{{ money(overview.totalAssets) }}</strong><small>{{ overview.accountCount }} 个账户，仅含勾选计入净资产的余额</small></div></article>
      <article class="finance-stat-card"><FinanceIcon kind="credit-card" :size="43" /><div><p>账户负余额合计</p><strong>{{ money(overview.totalLiabilities) }}</strong><small>不包含未接入的贷款及信用卡负债</small></div></article>
      <article class="finance-stat-card"><FinanceIcon kind="investment" :size="43" /><div><p>账户净资产</p><strong>{{ money(overview.netWorth) }}</strong><small>正余额减去负余额</small></div></article>
      <article class="finance-stat-card"><FinanceIcon kind="cash" :size="43" /><div><p>本月结余</p><strong>{{ money(overview.monthBalance) }}</strong><small>收入 {{ money(overview.monthIncome) }} · 支出 {{ money(overview.monthExpense) }} · 储蓄率 {{ percent(overview.savingsRate) }}</small></div></article>
    </div>
    <div class="finance-dashboard-grid">
      <article class="finance-panel finance-wide-panel"><header class="finance-panel-heading"><h3>近 6 个月收支</h3><el-button link type="primary" @click="emit('addTransaction')">记录流水</el-button></header><FinanceBarChart :data="cashFlow" /></article>
      <article class="finance-panel"><header class="finance-panel-heading"><h3>本月支出分类</h3></header><FinanceDonut :data="overview.expenseCategories" /></article>
    </div>
    <div class="finance-dashboard-grid">
      <article class="finance-panel"><header class="finance-panel-heading"><h3>资产结构</h3></header><FinanceDonut :data="overview.assetStructure" /></article>
      <article class="finance-panel"><header class="finance-panel-heading"><h3>账户概览</h3><el-button link type="primary" @click="emit('addAccount')">添加账户</el-button></header><div v-if="accounts.length" class="account-mini-list"><div v-for="item in accounts.slice(0, 5)" :key="item.id"><FinanceIcon :kind="item.accountType" :institution="item.institution" :size="32" /><span>{{ item.name }}</span><b>{{ money(item.balance) }}</b></div></div><div v-else class="finance-empty compact"><strong>先添加一个账户</strong><span>填写期初余额后，即可手动记账，或在 AI 对话中生成待确认流水。</span><el-button type="primary" @click="emit('addAccount')">添加账户</el-button></div></article>
    </div>
  </div>
</template>
