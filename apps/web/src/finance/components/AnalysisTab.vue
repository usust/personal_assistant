<script setup lang="ts">
import { computed, ref } from 'vue'
import { DataAnalysis, InfoFilled } from '@element-plus/icons-vue'
import FinanceBarChart from './FinanceBarChart.vue'
import FinanceDonut from './FinanceDonut.vue'
import { money, percent, ratio, sumMoney } from '@/finance/utils/money'
import type { CreditCard, FinanceOverview, Loan, Mortgage } from '@/types/finance'

const props = defineProps<{ overview: FinanceOverview; cards: CreditCard[]; loans: Loan[]; mortgages: Mortgage[] }>()
const range = ref('6months')
const visibleCashFlow = computed(() => range.value === 'month' ? props.overview.cashFlow.slice(-1) : range.value === '3months' ? props.overview.cashFlow.slice(-3) : props.overview.cashFlow)
const cashFlow = computed(() => visibleCashFlow.value.map(item => ({ label: item.month.slice(5) + '月', income: Number(item.income), expense: Number(item.expense), net: Number(item.net) })))
const monthlyDebt = computed(() => sumMoney([...props.loans.map(item => item.monthlyPayment), ...props.mortgages.map(item => item.monthlyPayment), ...props.cards.filter(item => item.hasInstallment).map(item => item.minimumPayment)]))
const debtBurden = computed(() => Number(props.overview.monthIncome) > 0 ? ratio(monthlyDebt.value, props.overview.monthIncome) : null)
const futureNeed = computed(() => sumMoney(props.overview.upcoming.map(item => item.amount)))
const largestExpense = computed(() => props.overview.expenseCategories[0])
</script>

<template>
  <div class="finance-tab-stack">
    <div class="analysis-toolbar"><div><p>财务分析</p><h2>基于真实记录的财务事实</h2></div><el-radio-group v-model="range" size="small"><el-radio-button value="month">本月</el-radio-button><el-radio-button value="3months">近 3 个月</el-radio-button><el-radio-button value="6months">近 6 个月</el-radio-button></el-radio-group></div>
    <div class="finance-stat-grid analysis-stat-grid"><article class="finance-metric"><span>当前净资产</span><strong :class="{ negative: Number(overview.netWorth) < 0 }">{{ money(overview.netWorth) }}</strong><small>资产 {{ money(overview.totalAssets) }} - 负债 {{ money(overview.totalLiabilities) }}</small></article><article class="finance-metric"><span>本月结余</span><strong>{{ money(overview.monthBalance) }}</strong><small>储蓄率 {{ percent(overview.savingsRate) }}</small></article><article class="finance-metric"><span>资产负债率</span><strong>{{ percent(overview.debtRatio) }}</strong><small v-if="overview.debtRatio === null">总资产为 0，暂不计算</small></article><article class="finance-metric"><span>未来 30 天资金需求</span><strong>{{ money(futureNeed) }}</strong><small>{{ overview.upcoming.length }} 个资金项目</small></article></div>
    <div class="finance-dashboard-grid"><article class="finance-panel finance-wide-panel"><header class="finance-panel-heading"><div><p>Cash Flow</p><h3>收入、支出与净现金流</h3></div><span class="finance-chart-key"><i class="income" />收入 <i class="expense" />支出</span></header><FinanceBarChart :data="cashFlow" /><div v-if="!overview.cashFlow.some(item => Number(item.income) || Number(item.expense))" class="chart-data-note"><InfoFilled />积累更多流水后可查看长期趋势。</div></article><article class="finance-panel"><header class="finance-panel-heading"><div><p>本月支出</p><h3>分类构成</h3></div></header><FinanceDonut :data="overview.expenseCategories" /></article></div>
    <div class="analysis-bottom-grid"><article class="finance-panel"><header class="finance-panel-heading"><div><p>固定偿债</p><h3>月度债务压力</h3></div></header><div v-if="debtBurden !== null" class="debt-burden"><strong>{{ debtBurden.toFixed(1) }}%</strong><span>固定偿债 {{ money(monthlyDebt) }} / 本月收入 {{ money(overview.monthIncome) }}</span><div class="finance-progress"><i :style="{ width: `${Math.min(100, debtBurden)}%` }" :class="{ risk: debtBurden > 50 }" /></div></div><div v-else class="finance-empty compact"><DataAnalysis /><strong>暂无足够收入数据</strong><span>记录收入后才能计算偿债负担比例。</span></div></article><article class="finance-panel"><header class="finance-panel-heading"><div><p>数据事实</p><h3>本期观察</h3></div></header><ul class="finance-facts"><li>本月收入 <b>{{ money(overview.monthIncome) }}</b>，支出 <b>{{ money(overview.monthExpense) }}</b>，净现金流 <b>{{ money(overview.monthBalance) }}</b>。</li><li v-if="largestExpense">最大支出分类为 <b>{{ largestExpense.name }}</b>，金额 <b>{{ money(largestExpense.amount) }}</b>。</li><li>未来 30 天及当前逾期项目合计 <b>{{ money(futureNeed) }}</b>。</li><li v-if="!largestExpense">当前没有足够的分类支出数据，不生成推测性结论。</li></ul></article></div>
  </div>
</template>
