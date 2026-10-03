<script setup lang="ts">
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, reactive, ref } from 'vue'
import { Plus } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { calculateMortgage, createMortgage, simulatePrepayment } from '@/api/finance'
import { money, ratio, sumMoney, today } from '@/finance/utils/money'
import type { Mortgage, MortgageInput, MortgageResult, MortgageType, RepaymentMethod } from '@/types/finance'
import FinanceIcon from './FinanceIcon.vue'

const props = defineProps<{ mortgages: Mortgage[] }>()
const emit = defineEmits<{ changed: [] }>()
const calculating = ref(false)
const result = ref<MortgageResult | null>(null)
const annuityResult = ref<MortgageResult | null>(null)
const principalResult = ref<MortgageResult | null>(null)
const page = ref(1)
const pageSize = 12
const saveVisible = ref(false)
const prepaymentVisible = ref(false)
const prepaymentResult = ref<Record<string, string | number> | null>(null)
const saveDraft = reactive({ name: '我的房贷', notes: '' })
const prepayment = reactive({ afterPeriod: 12, prepaymentAmount: '', type: 'partial' as 'partial' | 'settle', strategy: 'shorten_term' as 'shorten_term' | 'lower_payment' })
const input = reactive<MortgageInput>({ mortgageType: 'commercial', commercialPrincipal: '1000000', commercialRate: '3.10', fundPrincipal: '0', fundRate: '2.60', termMonths: 360, repaymentMethod: 'annuity', startDate: today() })
const pageRows = computed(() => result.value?.schedule.slice((page.value - 1) * pageSize, page.value * pageSize) ?? [])
const interestDifference = computed(() => {
  if (!annuityResult.value || !principalResult.value) return '0.00'
  return sumMoney([annuityResult.value.totalInterest, `-${principalResult.value.totalInterest}`]).replace(/^-/, '')
})
const principalShare = computed(() => result.value ? ratio(result.value.totalPrincipal, result.value.totalRepayment) : 0)
const interestShare = computed(() => result.value ? ratio(result.value.totalInterest, result.value.totalRepayment) : 0)
const typeLabels: Record<MortgageType, string> = { commercial: '商业贷款', fund: '公积金贷款', combined: '组合贷款' }
const methodLabels: Record<RepaymentMethod, string> = { annuity: '等额本息', equal_principal: '等额本金' }

async function calculate() { calculating.value = true; try { const base = { ...input }; const [current, annuity, principal] = await Promise.all([calculateMortgage(base), calculateMortgage({ ...base, repaymentMethod: 'annuity' }), calculateMortgage({ ...base, repaymentMethod: 'equal_principal' })]); result.value = current; annuityResult.value = annuity; principalResult.value = principal; page.value = 1 } finally { calculating.value = false } }
async function saveMortgage() { if (!result.value || !saveDraft.name.trim()) return; await createMortgage({ ...input, ...saveDraft, remainingPrincipal: result.value.totalPrincipal, monthlyPayment: result.value.firstPayment }); ElMessage.success('房贷与完整还款计划已保存'); saveVisible.value = false; emit('changed') }
async function runPrepayment() { if (!prepayment.prepaymentAmount) { ElMessage.warning('请输入提前还款金额'); return }; prepaymentResult.value = await simulatePrepayment({ ...input, ...prepayment }) as Record<string, string | number> }
calculate()
</script>

<template>
  <div class="finance-tab-stack">
    <section v-if="mortgages.length"><div class="finance-section-heading"><div><p>已保存</p><h2>我的房贷</h2></div></div><div class="mortgage-list"><article v-for="item in mortgages" :key="item.id"><FinanceIcon class="mortgage-icon" kind="mortgage" :size="34" /><div><strong>{{ item.name }}</strong><small>{{ typeLabels[item.mortgageType] }} · {{ methodLabels[item.repaymentMethod] }} · {{ item.termMonths }} 期</small></div><span><small>剩余本金</small><b>{{ money(item.remainingPrincipal) }}</b></span><span><small>当前月供</small><b>{{ money(item.monthlyPayment) }}</b></span><span><small>下次还款</small><b>{{ item.nextPaymentDate || '--' }}</b></span></article></div></section>
    <section class="mortgage-calculator">
      <div class="mortgage-input-panel"><div class="finance-section-heading"><div><p>测算工具</p><h2>房贷计算器</h2></div></div><el-form label-position="top"><el-form-item label="贷款类型"><el-radio-group v-model="input.mortgageType"><el-radio-button value="commercial">商业</el-radio-button><el-radio-button value="fund">公积金</el-radio-button><el-radio-button value="combined">组合贷款</el-radio-button></el-radio-group></el-form-item><div class="finance-form-grid"><template v-if="input.mortgageType !== 'fund'"><el-form-item label="商业贷款金额"><el-input v-model="input.commercialPrincipal"><template #prepend>￥</template></el-input></el-form-item><el-form-item label="商业贷款年利率"><el-input v-model="input.commercialRate"><template #append>%</template></el-input></el-form-item></template><template v-if="input.mortgageType !== 'commercial'"><el-form-item label="公积金贷款金额"><el-input v-model="input.fundPrincipal"><template #prepend>￥</template></el-input></el-form-item><el-form-item label="公积金年利率"><el-input v-model="input.fundRate"><template #append>%</template></el-input></el-form-item></template><el-form-item label="贷款期限"><el-select v-model="input.termMonths"><el-option label="5 年（60 期）" :value="60" /><el-option label="10 年（120 期）" :value="120" /><el-option label="15 年（180 期）" :value="180" /><el-option label="20 年（240 期）" :value="240" /><el-option label="25 年（300 期）" :value="300" /><el-option label="30 年（360 期）" :value="360" /></el-select></el-form-item><el-form-item label="开始日期"><el-date-picker v-model="input.startDate" value-format="YYYY-MM-DD" type="date" /></el-form-item></div><el-form-item label="还款方式"><el-radio-group v-model="input.repaymentMethod"><el-radio value="annuity">等额本息</el-radio><el-radio value="equal_principal">等额本金</el-radio></el-radio-group></el-form-item><el-alert title="利率由你自行录入，系统不会将某个政策利率永久写死。结果仅供测算，银行实际结算规则可能不同。" type="info" :closable="false" show-icon /><el-button class="mortgage-calculate-button" type="primary" :loading="calculating" @click="calculate">开始计算</el-button></el-form></div>
      <div class="mortgage-result-panel"><template v-if="result"><header><div><p>计算结果</p><h2>{{ typeLabels[input.mortgageType] }}</h2></div><div><el-button @click="prepaymentVisible = true">提前还款测算</el-button><el-button type="primary" :icon="Plus" @click="saveVisible = true">保存房贷</el-button></div></header><div class="mortgage-result-hero"><span>{{ input.repaymentMethod === 'annuity' ? '每月月供' : '首月月供' }}</span><strong>{{ money(result.firstPayment) }}</strong><small v-if="input.repaymentMethod === 'equal_principal'">末期 {{ money(result.lastPayment) }}</small></div><div class="mortgage-result-metrics"><span><small>贷款总额</small><b>{{ money(result.totalPrincipal) }}</b></span><span><small>总利息</small><b>{{ money(result.totalInterest) }}</b></span><span><small>本息合计</small><b>{{ money(result.totalRepayment) }}</b></span><span><small>贷款期限</small><b>{{ result.termMonths }} 期</b></span></div><div class="principal-interest-bar"><i :style="{ width: `${principalShare}%` }" /><span>本金 {{ principalShare.toFixed(1) }}%</span><span>利息 {{ interestShare.toFixed(1) }}%</span></div></template></div>
    </section>

    <section v-if="annuityResult && principalResult" class="finance-panel"><div class="finance-section-heading"><div><p>客观对比</p><h2>还款方式对比</h2></div></div><div class="repayment-comparison"><article><span>等额本息</span><strong>{{ money(annuityResult.firstPayment) }}<small>/ 月</small></strong><div><p>总利息 <b>{{ money(annuityResult.totalInterest) }}</b></p><p>总还款 <b>{{ money(annuityResult.totalRepayment) }}</b></p></div></article><article><span>等额本金</span><strong>{{ money(principalResult.firstPayment) }}<small>首月</small></strong><div><p>末期月供 <b>{{ money(principalResult.lastPayment) }}</b></p><p>总利息 <b>{{ money(principalResult.totalInterest) }}</b></p></div></article><div class="interest-difference"><span>总利息差额</span><strong>{{ money(interestDifference) }}</strong><small>仅展示同金额、期限、利率下的计算差异，不构成选择建议。</small></div></div></section>

    <section v-if="result" class="finance-panel finance-table-panel"><div class="finance-section-heading"><div><p>共 {{ result.schedule.length }} 期</p><h2>还款计划</h2></div></div><el-table :data="pageRows"><el-table-column prop="period" label="期数" width="80" /><el-table-column prop="paymentDate" label="还款日期" /><el-table-column label="月供" align="right"><template #default="scope">{{ money(scope.row.payment) }}</template></el-table-column><el-table-column label="本金" align="right"><template #default="scope">{{ money(scope.row.principal) }}</template></el-table-column><el-table-column label="利息" align="right"><template #default="scope">{{ money(scope.row.interest) }}</template></el-table-column><el-table-column label="剩余本金" align="right"><template #default="scope">{{ money(scope.row.remainingPrincipal) }}</template></el-table-column></el-table><el-pagination v-model:current-page="page" :page-size="pageSize" :total="result.schedule.length" layout="prev, pager, next, total" /></section>

    <WorkspacePanel v-model="saveVisible" title="保存房贷"><el-form label-position="top"><el-form-item label="房贷名称"><el-input v-model="saveDraft.name" /></el-form-item><el-form-item label="备注"><el-input v-model="saveDraft.notes" type="textarea" /></el-form-item></el-form><template #footer><el-button @click="saveVisible = false">取消</el-button><el-button type="primary" @click="saveMortgage">保存</el-button></template></WorkspacePanel>
    <WorkspacePanel v-model="prepaymentVisible" title="提前还款模拟"><el-form label-position="top"><div class="finance-form-grid"><el-form-item label="已还期数"><el-input-number v-model="prepayment.afterPeriod" :min="0" :max="Math.max(0, input.termMonths - 1)" /></el-form-item><el-form-item label="提前还款金额"><el-input v-model="prepayment.prepaymentAmount"><template #prepend>￥</template></el-input></el-form-item><el-form-item label="提前还款类型"><el-select v-model="prepayment.type"><el-option label="部分提前还款" value="partial" /><el-option label="一次性结清" value="settle" /></el-select></el-form-item><el-form-item label="部分还款策略"><el-select v-model="prepayment.strategy" :disabled="prepayment.type === 'settle'"><el-option label="缩短贷款期限" value="shorten_term" /><el-option label="保持期限，降低月供" value="lower_payment" /></el-select></el-form-item></div><el-alert v-if="input.mortgageType === 'combined'" title="组合贷款需分别遵循两部分的银行规则，当前模拟器仅支持单一贷款。" type="warning" :closable="false" /><div v-if="prepaymentResult" class="prepayment-result"><span><small>原剩余利息</small><b>{{ money(String(prepaymentResult.originalRemainingInterest)) }}</b></span><span><small>新剩余利息</small><b>{{ money(String(prepaymentResult.newRemainingInterest)) }}</b></span><span><small>预计节省利息</small><b class="positive">{{ money(String(prepaymentResult.interestSaved)) }}</b></span><span><small>预计缩短</small><b>{{ prepaymentResult.monthsSaved }} 期</b></span></div></el-form><template #footer><el-button @click="prepaymentVisible = false">关闭</el-button><el-button type="primary" :disabled="input.mortgageType === 'combined'" @click="runPrepayment">开始测算</el-button></template></WorkspacePanel>
  </div>
</template>
