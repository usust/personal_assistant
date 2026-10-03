import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { CreditCard, FinanceOverview, FinanceTransaction, FinancialAccount, Loan, Mortgage, MortgageInput, MortgageResult, TransactionCategory, TransactionFilter } from '@/types/finance'

// 解包统一响应；类型参数 T 为业务数据，request 为 HTTP Promise；返回值：数据 Promise，保留请求错误。
async function getData<T>(request: Promise<{ data: ApiResponse<T> }>) { return (await request).data.data }

export const getFinanceOverview = () => getData<FinanceOverview>(http.get('/finance/overview'))
export const getAccounts = () => getData<FinancialAccount[]>(http.get('/finance/accounts'))
export const createAccount = (payload: Partial<FinancialAccount>) => getData<FinancialAccount>(http.post('/finance/accounts', payload))
export const updateAccount = (id: number, payload: Partial<FinancialAccount>) => getData(http.patch(`/finance/accounts/${id}`, payload))
// 查询删除影响；参数：id 为账户 ID；返回值：流水、快照及待确认数量，无写入。
export const getAccountImpact = (id: number) => getData<{ transactions: number; snapshots: number; pending: number }>(http.get(`/finance/accounts/${id}/impact`))
// 软删除账户；参数：id 为已确认账户 ID；返回值：关联数量，历史记录保留，错误由 HTTP 层提示。
export const archiveAccount = (id: number) => getData<{ transactions: number; snapshots: number; pending: number }>(http.delete(`/finance/accounts/${id}`))

export const getTransactions = (params: TransactionFilter = {}) => getData<FinanceTransaction[]>(http.get('/finance/transactions', { params }))
export const createTransaction = (payload: Partial<FinanceTransaction>) => getData<FinanceTransaction>(http.post('/finance/transactions', payload))
export const getCategories = () => getData<TransactionCategory[]>(http.get('/finance/categories'))
export const createCategory = (payload: Partial<TransactionCategory>) => getData<TransactionCategory>(http.post('/finance/categories', payload))

export const getCreditCards = () => getData<CreditCard[]>(http.get('/finance/credit-cards'))
export const createCreditCard = (payload: Partial<CreditCard>) => getData<CreditCard>(http.post('/finance/credit-cards', payload))
export const getLoans = () => getData<Loan[]>(http.get('/finance/loans'))
export const createLoan = (payload: Partial<Loan>) => getData<Loan>(http.post('/finance/loans', payload))
export const getMortgages = () => getData<Mortgage[]>(http.get('/finance/mortgages'))
export const createMortgage = (payload: Partial<Mortgage>) => getData<Mortgage>(http.post('/finance/mortgages', payload))
export const calculateMortgage = (payload: MortgageInput) => getData<MortgageResult>(http.post('/finance/mortgage/calculate', payload))
export const simulatePrepayment = (payload: MortgageInput & { afterPeriod: number; prepaymentAmount: string; type: 'partial' | 'settle'; strategy: 'shorten_term' | 'lower_payment' }) => getData(http.post('/finance/mortgage/prepayment', payload))

// 确认 AI 草稿；参数：id 为待确认流水 ID；返回值：入账后的流水 Promise，服务端防止重复入账。
export const confirmTransaction = (id: number) => getData<FinanceTransaction>(http.post(`/finance/transactions/${id}/confirm`))
// 作废并冲销流水；参数：id 为流水 ID；返回值：作废后的流水 Promise，保留历史。
export const voidTransaction = (id: number) => getData<FinanceTransaction>(http.post(`/finance/transactions/${id}/void`))

// 统一试算固定利率贷款；参数：payload 为贷款资料；返回值：后端计算摘要，失败沿用 HTTP 错误提示，不写账本。
export const previewLoanAccount = (payload: import('@/types/finance').LoanAccountTerms) => getData<import('@/types/finance').LoanPlanSummary>(http.post('/finance/loan-preview', payload))

// 读取已保存的完整分期计划；参数：id 为当前用户贷款账户；返回值：含版本的计划，不重新解释历史利率。
export const getLoanAccountPlan = (id: number) => getData<import('@/types/finance').LoanPlanSummary>(http.get(`/finance/accounts/${id}/loan-plan`))
// 预览分期调整；参数：id 为贷款账户，payload 为版本及生效期设置；返回值：试算计划，无写入。
export const previewLoanAdjustment = (id: number, payload: import('@/types/finance').LoanAdjustmentRequest) => getData<import('@/types/finance').LoanPlanSummary>(http.post(`/finance/accounts/${id}/loan-adjustment-preview`, payload))
// 保存已预览的分期调整；参数：id 为贷款账户，payload 为同版本请求；返回值：新版本计划，过期版本由服务端拒绝。
export const saveLoanAdjustment = (id: number, payload: import('@/types/finance').LoanAdjustmentRequest) => getData<import('@/types/finance').LoanPlanSummary>(http.post(`/finance/accounts/${id}/loan-adjustments`, payload))

// 读取消费分期；参数：id 为原支出 ID；返回值：完整计划及入账进度，不修改账本。
export const getConsumptionInstallment = (id: number) => getData<import('@/types/finance').ConsumptionInstallmentPlan>(http.get(`/finance/transactions/${id}/installment`))
// 试算消费分期；参数：id 为原支出，payload 为规则；返回值：精确计划，不写数据库。
export const previewConsumptionInstallment = (id: number, payload: import('@/types/finance').ConsumptionInstallmentTerms) => getData<import('@/types/finance').ConsumptionInstallmentPlan>(http.post(`/finance/transactions/${id}/installment-preview`, payload))
// 原子转换消费分期；参数：id 为原支出，payload 为已预览规则；返回值：保存计划，同规则重试幂等。
export const createConsumptionInstallment = (id: number, payload: import('@/types/finance').ConsumptionInstallmentTerms) => getData<import('@/types/finance').ConsumptionInstallmentPlan>(http.post(`/finance/transactions/${id}/installment`, payload))

// 查询模板及周期计划；参数：无；返回值：当前用户的记录 Promise。
export const getFinancePresets = () => getData<import('@/types/finance').FinancePreset[]>(http.get('/finance/presets'))
// 保存模板或计划；参数：payload 为名称、稳定键、流水及周期；返回值：已保存记录，相同键重试不重复创建。
export const createFinancePreset = (payload: Partial<import('@/types/finance').FinancePreset>) => getData<import('@/types/finance').FinancePreset>(http.post('/finance/presets', payload))
// 更新名称或暂停状态；参数：id 为记录 ID，payload 为实际修改字段；返回值：更新记录。
export const updateFinancePreset = (id: number, payload: { name?: string; enabled?: boolean }) => getData(http.patch(`/finance/presets/${id}`, payload))
// 删除模板或计划；参数：id 为记录 ID；返回值：完成 Promise，保留历史流水。
export const deleteFinancePreset = (id: number) => getData(http.delete(`/finance/presets/${id}`))
// 补齐当前用户到期草稿；参数：无；返回值：完成 Promise，不改变余额。
export const materializeRecurring = () => getData(http.post('/finance/recurring/materialize', {}))
