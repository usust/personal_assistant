export type AccountType = 'bank' | 'alipay' | 'wechat' | 'cash' | 'savings' | 'investment' | 'other'
export type TransactionType = 'income' | 'expense' | 'transfer'
export type MortgageType = 'commercial' | 'fund' | 'combined'
export type RepaymentMethod = 'annuity' | 'equal_principal'

export interface LoanAccountTerms {
  loanPrincipal?: string; loanAnnualRate?: string; loanMethod?: string; loanPeriods?: number
  loanPaidPeriods?: number; loanFirstPaymentDate?: string; loanLender?: string; loanReceivingAccountId?: number
}
export interface LoanPlanSummary {
  paidPrincipal?: string; paidInterest?: string; paidTotal?: string; remainingInterest?: string; remainingTotal?: string; totalPayment?: string
  revision?: number; paidPeriods?: number; lastPaymentPeriod?: number; schedule?: LoanPayment[]
  remainingPrincipal: string; totalInterest: string
  next: LoanPayment | null
}
export interface LoanPayment {
  period: number; date: string; principal: string; interest: string; payment: string; remaining: string
  annualRate?: string; customPayment?: boolean; paymentOverridden?: boolean
}
export type LoanAdjustmentRequest = { revision: number; fromPeriod: number } & (
  { kind: 'rate'; annualRate: string } | { kind: 'reprice'; scope: 'period'; payment: string; annualRate: string }
)
export interface FinancialAccount extends LoanAccountTerms {
  loanPlan?: LoanPlanSummary
  loanRevision?: number; loanPlanLocked?: boolean
  installmentCredit?: string;
  installmentInterestReserved?: string;
  creditLimit?: string; currentDebt?: string; billingDay?: number; repaymentDay?: number
  billDayInclusive?: boolean; selectable?: boolean; reminderDays?: number; reminderTime?: string
  id: number
  name: string
  accountType: AccountType
  institution: string
  maskedAccountNumber: string
  balance: string
  availableBalance: string
  currency: string
  includeInNetWorth: boolean
  sortOrder: number
  notes: string
  createdAt: string
  updatedAt: string
}

export interface FinanceTransaction {
  rebate?: string
  rebateAccountId?: number | null
  rebatePending?: boolean
  rebateParentId?: number
  fee?: string
  installmentParentId?: number
  installmentPeriod?: number
  requestId: string
  status: 'pending' | 'posted' | 'voided' | 'installment'
  source: 'http' | 'ai' | 'recurring'
  id: number
  accountId: number
  targetAccountId: number | null
  targetCreditCardId: number | null
  type: TransactionType
  amount: string
  categoryId: number | null
  counterparty: string
  transactionDate: string
  description: string
  createdAt: string
  updatedAt: string
}

export interface TransactionCategory { id: number; name: string; type: 'income' | 'expense'; color: string; isDefault: boolean }

export interface CreditCard {
  id: number; name: string; institution: string; maskedAccountNumber: string
  creditLimit: string; currentDebt: string; statementAmount: string; minimumPayment: string
  billingDay: number; repaymentDay: number; nextPaymentDate: string; hasInstallment: boolean; notes: string
}

export interface Loan {
  id: number; name: string; loanType: string; principal: string; remainingPrincipal: string
  annualInterestRate: string; termMonths: number; repaymentMethod: RepaymentMethod
  startDate: string; endDate: string; monthlyPayment: string; nextPaymentDate: string; lender: string; notes: string
}

export interface Mortgage {
  id: number; name: string; mortgageType: MortgageType; commercialPrincipal: string; commercialRate: string
  fundPrincipal: string; fundRate: string; remainingPrincipal: string; termMonths: number
  repaymentMethod: RepaymentMethod; startDate: string; nextPaymentDate: string; monthlyPayment: string; notes: string
}

export interface PaymentItem { period: number; paymentDate: string; payment: string; principal: string; interest: string; remainingPrincipal: string }
export interface MortgageInput {
  mortgageType: MortgageType; commercialPrincipal: string; commercialRate: string
  fundPrincipal: string; fundRate: string; termMonths: number; repaymentMethod: RepaymentMethod; startDate: string
}
export interface MortgageResult {
  totalPrincipal: string; firstPayment: string; lastPayment: string; totalInterest: string
  totalRepayment: string; termMonths: number; schedule: PaymentItem[]
}

export interface AssetSlice { name: string; amount: string }
export interface MonthlyCashFlow { month: string; income: string; expense: string; net: string }
export interface NetWorthPoint { date: string; assets: string; liabilities: string; netWorth: string }
export interface CategoryMetric { name: string; amount: string; color: string }
export interface UpcomingPayment { id: number; name: string; amount: string; date: string; kind: string; status: 'normal' | 'soon' | 'today' | 'overdue' }
export interface FinanceOverview {
  totalAssets: string; totalLiabilities: string; netWorth: string
  monthIncome: string; monthExpense: string; monthBalance: string
  savingsRate: string | null; debtRatio: string | null; accountCount: number
  assetStructure: AssetSlice[]; netWorthTrend: NetWorthPoint[]; cashFlow: MonthlyCashFlow[]; expenseCategories: CategoryMetric[]; upcoming: UpcomingPayment[]
}

export interface TransactionFilter { status?: 'pending' | 'posted' | 'voided' | 'installment' | ''; limit?: number; offset?: number; startDate?: string; endDate?: string; type?: TransactionType | ''; accountId?: number; categoryId?: number; minAmount?: string; maxAmount?: string; keyword?: string }

export interface ConsumptionInstallmentTerms {
  name: string
  periods: number
  firstDate: string
  interest: string
  interestMode: string
  rounding: string
  remainder: string
}
export interface ConsumptionInstallmentPlan extends ConsumptionInstallmentTerms {
  principal: string
  total: string
  posted: number
  rows: { period: number; date: string; principal: string; interest: string; amount: string; transactionId: number; status: string }[]
}

export interface FinancePreset {
  id: number
  key: string
  name: string
  transaction: Partial<FinanceTransaction>
  frequency: '' | 'daily' | 'weekly' | 'monthly' | 'yearly'
  startDate: string
  endDate: string
  nextDate: string
  enabled: boolean
  lastError: string
}
