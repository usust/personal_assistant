import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

const source = await readFile(new URL('../src/finance/utils/reimbursement.ts', import.meta.url), 'utf8')
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
})
const { buildReimbursementFields, canEditReimbursement, reimbursementStatus } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`)
const expense = { type: 'expense', status: 'posted', amount: '100.00', reimbursable: true, reimbursedAmount: '0.00' }

// 验证到账金额使用精确分而非浮点，并限制金额格式和支出上限；参数：无；返回值：无，断言失败终止测试，无外部副作用。
test('reimbursement accepts exact cents and rejects negative, invalid and excessive receipts', () => {
  assert.deepEqual(buildReimbursementFields(true, ' 000.1 ', '0.10'), { reimbursable: true, reimbursedAmount: '0.10' })
  assert.deepEqual(buildReimbursementFields(true, '', '0.10'), { reimbursable: true, reimbursedAmount: '0.00' })
  assert.deepEqual(buildReimbursementFields(true, '9007199254740993.01', '9007199254740993.01'), { reimbursable: true, reimbursedAmount: '9007199254740993.01' })
  // 错误输入回调：参数无（使用本轮 input）；返回值为校验字段，预期抛错以验证不允许的格式。
  for (const input of ['-0.01', '0.001', '1e2', 'NaN']) assert.throws(() => buildReimbursementFields(true, input, '100.00'), /非负金额/)
  // 分位超额回调：参数无；返回值为校验字段，预期抛错，不写入任何账本。
  assert.throws(() => buildReimbursementFields(true, '0.11', '0.10'), /不能超过/)
  // 大额分位超额回调：参数无；返回值为校验字段，验证超出安全整数范围后仍精确拒绝。
  assert.throws(() => buildReimbursementFields(true, '9007199254740993.02', '9007199254740993.01'), /不能超过/)
  // 零额支出回调：参数无；返回值为校验字段，预期拒绝非正数支出。
  assert.throws(() => buildReimbursementFields(true, '0.00', '0.00'), /正数支出/)
})

// 验证取消标记与模板、周期、草稿不会继承到账金额；参数：无；返回值：无，断言失败终止测试，无外部副作用。
test('unmarked expenses and non-posted copies always clear received reimbursement amounts', () => {
  assert.deepEqual(buildReimbursementFields(false, '80.00', '100.00'), { reimbursable: false, reimbursedAmount: '0.00' })
  assert.deepEqual(buildReimbursementFields(true, '80.00', '100.00', false), { reimbursable: true, reimbursedAmount: '0.00' })
})

// 验证支出资格与列表进度表达；参数：无；返回值：无，断言失败终止测试；不根据退款前原额推断是否全部完成。
test('only positive pending or posted expenses can be edited and receipt status preserves partial progress', () => {
  assert.equal(canEditReimbursement(expense), true)
  assert.equal(canEditReimbursement({ ...expense, status: 'pending' }), true)
  assert.equal(canEditReimbursement({ ...expense, installmentParentId: 7 }), true)
  for (const changes of [{ type: 'income' }, { type: 'transfer' }, { status: 'voided' }, { status: 'installment' }, { amount: '0.00' }, { amount: '-10.00' }, { refundParentId: 7 }, { rebateParentId: 7 }]) assert.equal(canEditReimbursement({ ...expense, ...changes }), false)
  assert.equal(reimbursementStatus({ ...expense, reimbursable: false }), '不报销')
  assert.equal(reimbursementStatus(expense), '待报销')
  assert.equal(reimbursementStatus({ ...expense, reimbursedAmount: '0.01' }), '已报销')
  assert.equal(reimbursementStatus({ ...expense, refundParentId: 7 }), '不报销')
  assert.equal(reimbursementStatus({ ...expense, amount: '-10.00' }), '不报销')
})
