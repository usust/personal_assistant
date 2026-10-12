import type { FinanceTransaction } from '@/types/finance'

type ReimbursementTransaction = Pick<FinanceTransaction, 'type' | 'status' | 'amount' | 'refundParentId' | 'rebateParentId' | 'reimbursable' | 'reimbursedAmount'>
export interface ReimbursementFields { reimbursable: boolean; reimbursedAmount: string }

// 读取精确金额；参数：value 为最多两位小数的非负十进制字符串；返回值：整数分，无效输入返回 null；无副作用。
function cents(value: string): bigint | null {
  const match = value.trim().match(/^(\d+)(?:\.(\d{1,2}))?$/)
  if (!match) return null
  return BigInt(match[1]!) * 100n + BigInt(`${match[2] ?? ''}00`.slice(0, 2))
}

// 判断流水能否编辑报销；参数：item 为当前用户流水；返回值：正支出且待确认或已入账时为 true，退款、优惠及分期主项为 false；无副作用。
export function canEditReimbursement(item: ReimbursementTransaction): boolean {
  return item.type === 'expense' && (item.status === 'posted' || item.status === 'pending')
    && !item.refundParentId && !item.rebateParentId && (cents(item.amount) ?? 0n) > 0n
}

// 校验并规范报销字段；参数：marked 为需报销标记，received 为已报销金额，amount 为正支出金额，allowReceived 为是否已入账并允许登记到账；返回值：完整报销字段；金额格式或上限无效时抛出中文错误，无副作用。
export function buildReimbursementFields(marked: boolean, received: string, amount: string, allowReceived = true): ReimbursementFields {
  // 取消标记及模板、周期、待确认草稿均不继承已报销金额，避免重复累计到账进度。
  if (!marked) return { reimbursable: false, reimbursedAmount: '0.00' }
  if (!allowReceived) return { reimbursable: true, reimbursedAmount: '0.00' }
  const value = cents(received.trim() || '0.00')
  const total = cents(amount)
  if (value === null) throw new Error('已报销金额须为非负金额，最多两位小数')
  if (total === null || total <= 0n) throw new Error('报销仅支持正数支出')
  if (value > total) throw new Error('已报销金额不能超过支出金额')
  return { reimbursable: true, reimbursedAmount: `${value / 100n}.${String(value % 100n).padStart(2, '0')}` }
}

// 获取流水报销状态；参数：item 为流水；返回值：不报销、待报销或已报销文字；到账金额由界面单独展示，避免以退款前金额误判完成进度；无副作用。
export function reimbursementStatus(item: ReimbursementTransaction): string {
  if (!item.reimbursable || item.type !== 'expense' || item.refundParentId || item.rebateParentId || item.status === 'installment' || (cents(item.amount) ?? 0n) <= 0n) return '不报销'
  const received = cents(item.reimbursedAmount || '0.00') ?? 0n
  return received > 0n ? '已报销' : '待报销'
}
