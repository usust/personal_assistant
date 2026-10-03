// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// adjustmentBody 构造合法变更；参数：version 为计划版本，period 为生效期，rate 为新年利率；返回值：独立请求字典，无副作用。
func adjustmentBody(version, period int, rate string) map[string]any {
	return map[string]any{"revision": version, "fromPeriod": period, "annualRate": rate, "paymentMode": "auto"}
}

// TestLoanAdjustmentHistory 验证两次调息、逐项历史不变和保存重读；参数：t 为测试上下文；返回值：无，只写临时数据库。
func TestLoanAdjustmentHistory(t *testing.T) {
	s := fixture(t)
	body := loanBody()
	body["loanAnnualRate"] = "12"
	a := must(t, s, "finance.account.create", 0, body).(domain.Account)
	before := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	change := adjustmentBody(before.Revision, 4, "6")
	preview := must(t, s, "finance.loan.adjustment.preview", a.ID, change).(*domain.LoanPlan)
	if !reflect.DeepEqual(before.Schedule[:3], preview.Schedule[:3]) || preview.Schedule[3].Interest != before.Schedule[3].Interest/2 {
		t.Fatal("调息改写历史或利息未变化")
	}
	unchanged := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	if !reflect.DeepEqual(before, unchanged) {
		t.Fatal("试算产生写入")
	}
	after := must(t, s, "finance.loan.adjustment.save", a.ID, change).(*domain.LoanPlan)
	if after.Revision != before.Revision+1 {
		t.Fatal("版本未递增")
	}
	reloaded := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	if !reflect.DeepEqual(after, reloaded) {
		t.Fatal("保存后计划不一致")
	}
	// 旧版本不能再次覆盖其他客户端的调整；既有计划必须保持完整。
	if _, err := execute(s, 1, "finance.loan.adjustment.save", a.ID, change, "http"); !errors.Is(err, ErrConflict) {
		t.Fatal("未拦截过期保存", err)
	}
	again := must(t, s, "finance.loan.adjustment.save", a.ID, adjustmentBody(after.Revision, 6, "0")).(*domain.LoanPlan)
	if !reflect.DeepEqual(after.Schedule[:5], again.Schedule[:5]) || again.Schedule[5].Interest != 0 || again.Schedule[11].Remaining != 0 {
		t.Fatal("二次调息未保留前段或零利率失效")
	}
	rows := must(t, s, "finance.account.list", 0, nil).([]domain.Account)
	if rows[0].Balance != a.Balance || rows[0].LoanPaidPeriods != 3 || rows[0].LoanPlan.Next.AnnualRate != "6" || rows[0].LoanPlan.Schedule != nil {
		t.Fatal("调息改动账本或列表摘要错误")
	}
	var transactions, snapshots, events int64
	s.db.Model(&domain.Transaction{}).Count(&transactions)
	s.db.Model(&domain.Snapshot{}).Count(&snapshots)
	s.db.Model(&domain.Event{}).Count(&events)
	if transactions != 0 || snapshots != 1 || events != 3 {
		t.Fatal("只读操作产生审计写入或调整生成了流水", transactions, snapshots, events)
	}
}

// TestLoanAdjustmentMethods 验证三种方法、月末日期及本金守恒；参数：t 为测试上下文；返回值：无，无外部副作用。
func TestLoanAdjustmentMethods(t *testing.T) {
	for _, method := range []string{"annuity", "equal_principal", "interest_only"} {
		terms := loanFixture()
		terms.LoanMethod = method
		terms.LoanPaidPeriods = 1
		a := domain.Account{LoanTerms: terms, LoanRevision: 1}
		before, _ := accountLoanPlan(a)
		v := 1
		after, err := adjustedLoanPlan(a, before, domain.LoanAdjustmentInput{Revision: &v, FromPeriod: 2, AnnualRate: "6", PaymentMode: "auto"})
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(before.Schedule[:1], after.Schedule[:1]) || after.Schedule[1].Date != "2028-02-29" || after.Schedule[2].Date != "2028-03-31" {
			t.Fatal("生效于二月造成历史或日期漂移")
		}
		var principal domain.Money
		for _, row := range after.Schedule {
			principal += row.Principal
			if row.Payment != row.Principal+row.Interest {
				t.Fatal("本金利息不匹配")
			}
		}
		if principal != terms.LoanPrincipal {
			t.Fatal("本金不守恒")
		}
	}
}

// TestLoanCustomPayments 验证自定义每期本息、最后一期补差及提前结清；参数：t 为测试上下文；返回值：无，无数据库副作用。
func TestLoanCustomPayments(t *testing.T) {
	terms := loanFixture()
	terms.LoanPaidPeriods = 3
	a := domain.Account{LoanTerms: terms}
	before, _ := accountLoanPlan(a)
	v := 0
	for _, amount := range []domain.Money{1000, 50000} {
		after, err := adjustedLoanPlan(a, before, domain.LoanAdjustmentInput{Revision: &v, FromPeriod: 4, AnnualRate: "6", PaymentMode: "fixed", Payment: &amount})
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(before.Schedule[:3], after.Schedule[:3]) || after.Schedule[3].Payment != amount {
			t.Fatal("固定月供或历史错误")
		}
		if amount == 1000 && after.Schedule[11].Payment <= amount {
			t.Fatal("小月供未保留末期补差")
		}
		if amount == 50000 && (after.Schedule[11].Payment != 0 || after.LastPaymentPeriod >= 12) {
			t.Fatal("大月供结清后未归零")
		}
		if amount == 50000 {
			closedAccount := a
			closedAccount.LoanPaidPeriods = after.LastPaymentPeriod
			closed, err := summarizeLoanPlan(closedAccount, after.Schedule)
			if err != nil || closed.Next != nil || closed.RemainingPrincipal != 0 {
				t.Fatal("计划提前结清后仍有下一期", err)
			}
		}
		if after.Schedule[11].Remaining != 0 {
			t.Fatal("末期本金未清偿")
		}
	}
	bad := domain.Money(1)
	if _, err := adjustedLoanPlan(a, before, domain.LoanAdjustmentInput{Revision: &v, FromPeriod: 4, AnnualRate: "12", PaymentMode: "fixed", Payment: &bad}); err == nil {
		t.Fatal("负摊销通过")
	}
}

// TestLoanAdjustmentGuards 验证权限、期次边界、非法输入、合同旁路及事务回滚；参数：t 为测试上下文；返回值：无，仅写临时数据库。
func TestLoanAdjustmentGuards(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, loanBody()).(domain.Account)
	before := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	for _, patch := range []map[string]any{{"fromPeriod": 0}, {"fromPeriod": -1}, {"fromPeriod": 13}, {"annualRate": "100.0001"}, {"annualRate": ""}, {"paymentMode": "fixed", "payment": "0"}, {"paymentMode": "fixed", "payment": nil}, {"paymentMode": "auto", "payment": "100"}, {"revision": nil}, {"ownerId": 2}} {
		body := adjustmentBody(before.Revision, 4, "3")
		for k, v := range patch {
			body[k] = v
		}
		if _, err := execute(s, 1, "finance.loan.adjustment.save", a.ID, body, "http"); err == nil {
			t.Fatal("非法输入被接受", body)
		}
	}
	for _, op := range []string{"finance.loan.plan", "finance.loan.adjustment.preview", "finance.loan.adjustment.save"} {
		if _, err := execute(s, 2, op, a.ID, adjustmentBody(before.Revision, 4, "3"), "http"); !errors.Is(err, ErrNotFound) {
			t.Fatal("越权未被拦截", op, err)
		}
		if _, err := execute(s, 1, op, a.ID, adjustmentBody(before.Revision, 4, "3"), "ai"); err == nil {
			t.Fatal("AI 越过写入边界")
		}
	}
	if _, err := execute(s, 1, "finance.account.update", a.ID, map[string]any{"name": "不应写入", "loanPaidPeriods": 0, "loanAnnualRate": "3"}, "http"); err == nil {
		t.Fatal("PATCH 绕过历史保护")
	}
	persisted, _ := account(s.db, 1, a.ID, true)
	if persisted.Name != a.Name || persisted.LoanPaidPeriods != 3 {
		t.Fatal("失败更新没有回滚")
	}
	after := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("失败操作修改计划")
	}
	must(t, s, "finance.account.update", a.ID, map[string]any{"loanPaidPeriods": 0, "notes": "允许修改资料"})
	if _, err := execute(s, 1, "finance.account.update", a.ID, map[string]any{"loanAnnualRate": "3"}, "http"); err == nil {
		t.Fatal("清零已还期数后绕过历史保护")
	}
	// 直接伪造持久化快照或版本必须被字段白名单拒绝。
	for _, key := range []string{"loanScheduleJSON", "loanRevision"} {
		if _, err := execute(s, 1, "finance.account.update", a.ID, map[string]any{key: 1}, "http"); err == nil {
			t.Fatal("允许直接修改内部字段")
		}
	}
	must(t, s, "finance.account.archive", a.ID, nil)
	if _, err := execute(s, 1, "finance.loan.plan", a.ID, nil, "http"); !errors.Is(err, ErrNotFound) {
		t.Fatal("删除账户仍可访问")
	}
}

// TestLoanPaidPeriodCorrection 验证计划已还期次可修正且不改更早期次及真实账本；参数：t 为测试上下文；返回值：无，仅写临时数据库。
func TestLoanPaidPeriodCorrection(t *testing.T) {
	s := fixture(t)
	a := must(t, s, "finance.account.create", 0, loanBody()).(domain.Account)
	// 放入真实已入账流水，避免仅凭空流水数量无法发现修正计划误改交易的回归。
	must(t, s, "finance.transaction.create", 0, transactionBody("paid-plan-correction", a.ID, "expense", "50.00"))
	ledgerBefore, err := account(s.db, 1, a.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	var snapshotsBefore []domain.Snapshot
	if err = s.db.Order("id").Find(&snapshotsBefore).Error; err != nil {
		t.Fatal(err)
	}
	var transactionsBefore []domain.Transaction
	if err = s.db.Order("id").Find(&transactionsBefore).Error; err != nil {
		t.Fatal(err)
	}
	before := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	change := adjustmentBody(before.Revision, 2, "6")
	change["paymentMode"], change["payment"] = "fixed", "1100.00"
	preview := must(t, s, "finance.loan.adjustment.preview", a.ID, change).(*domain.LoanPlan)
	if preview.Schedule[0] != before.Schedule[0] || preview.Schedule[1].Payment != 110000 || preview.Schedule[1].AnnualRate != "6" || preview.PaidPeriods != 3 {
		t.Fatal("已还期次不能调整、改写更早期次或改动已还状态")
	}
	if unchanged := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan); !reflect.DeepEqual(before, unchanged) {
		t.Fatal("历史修正预览产生写入")
	}
	after := must(t, s, "finance.loan.adjustment.save", a.ID, change).(*domain.LoanPlan)
	preview.Revision++
	if !reflect.DeepEqual(preview, after) || after.Next == nil || after.Next.Period != 4 || after.RemainingPrincipal != after.Schedule[2].Remaining {
		t.Fatal("保存结果与预览或已还期次摘要不一致")
	}
	if reloaded := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan); !reflect.DeepEqual(after, reloaded) {
		t.Fatal("已还期次修正未持久化")
	}
	ledgerAfter, err := account(s.db, 1, a.ID, true)
	if err != nil || ledgerAfter.Balance != ledgerBefore.Balance || ledgerAfter.LoanPaidPeriods != ledgerBefore.LoanPaidPeriods || ledgerAfter.LoanTerms != ledgerBefore.LoanTerms {
		t.Fatal("修正计划改动真实余额或合同资料", err)
	}
	var transactions []domain.Transaction
	var snapshotsAfter []domain.Snapshot
	if err = s.db.Order("id").Find(&transactions).Error; err != nil {
		t.Fatal(err)
	}
	if err = s.db.Order("id").Find(&snapshotsAfter).Error; err != nil {
		t.Fatal(err)
	}
	if len(transactions) != 1 || !reflect.DeepEqual(transactionsBefore, transactions) || !reflect.DeepEqual(snapshotsBefore, snapshotsAfter) {
		t.Fatal("修正计划改动了已有流水或余额快照")
	}
	// 全部标为计划已还后仍可纠正首期；已还状态不因重新计算而倒退。
	must(t, s, "finance.account.update", a.ID, map[string]any{"loanPaidPeriods": 12})
	closed := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	corrected := must(t, s, "finance.loan.adjustment.save", a.ID, adjustmentBody(closed.Revision, 1, "0")).(*domain.LoanPlan)
	if corrected.PaidPeriods != 12 || corrected.Next != nil || corrected.TotalInterest != 0 || corrected.RemainingPrincipal != 0 {
		t.Fatal("全部计划已还时不能修正或被错误恢复为待还")
	}
}

// TestIndependentLoanAdjustments 验证金额不改分段利率、利率保留分段自定义月供；参数：t 为测试上下文；返回值：无，不写外部数据库。
func TestIndependentLoanAdjustments(t *testing.T) {
	a := domain.Account{LoanTerms: loanFixture()}
	before, err := accountLoanPlan(a)
	if err != nil {
		t.Fatal(err)
	}
	v := 0
	amount := domain.Money(9000)
	segmented, err := adjustedLoanPlan(a, before, domain.LoanAdjustmentInput{Revision: &v, FromPeriod: 7, AnnualRate: "6", PaymentMode: "fixed", Payment: &amount})
	if err != nil {
		t.Fatal(err)
	}
	newAmount := domain.Money(10000)
	paid, err := adjustedLoanPlan(a, segmented, domain.LoanAdjustmentInput{Revision: &v, Kind: "payment", Scope: "period", FromPeriod: 4, Payment: &newAmount})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(paid.Schedule[:3], segmented.Schedule[:3]) || !reflect.DeepEqual(paid.Schedule[4:], segmented.Schedule[4:]) || paid.Schedule[3].Payment != newAmount {
		t.Fatal("单期金额修正改变了其他期次")
	}
	for i, row := range paid.Schedule {
		if row.AnnualRate != segmented.Schedule[i].AnnualRate {
			t.Fatal("仅调整金额覆盖了已有分段利率", i)
		}
	}
	rated, err := adjustedLoanPlan(a, segmented, domain.LoanAdjustmentInput{Revision: &v, Kind: "rate", FromPeriod: 4, AnnualRate: "0"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(rated.Schedule[:3], segmented.Schedule[:3]) || rated.Schedule[6].Payment != amount || rated.Schedule[3].CustomPayment {
		t.Fatal("独立利率调整覆盖了已有月供设置或历史")
	}
	for _, row := range rated.Schedule[3:] {
		if row.AnnualRate != "0" || row.Interest != 0 {
			t.Fatal("新利率未覆盖生效期及以后")
		}
	}
	for _, invalidInput := range []domain.LoanAdjustmentInput{
		{Kind: "rate", AnnualRate: "3", PaymentMode: "auto"},
		{Kind: "payment", AnnualRate: "3", PaymentMode: "auto"},
		{Kind: "rate", AnnualRate: ""},
		{Kind: "payment", PaymentMode: "fixed"},
		{Kind: "unknown"},
	} {
		invalidInput.Revision, invalidInput.FromPeriod = &v, 4
		if _, err := adjustedLoanPlan(a, segmented, invalidInput); err == nil {
			t.Fatal("独立操作接受跨功能字段或非法输入", invalidInput)
		}
	}
}

// TestLoanScheduleStorageLimit 验证最大计划可持久化并往返；参数：t 为测试上下文；返回值：无，仅写临时数据库。
func TestLoanScheduleStorageLimit(t *testing.T) {
	s := fixture(t)
	body := loanBody()
	body["loanPeriods"] = 480
	a := must(t, s, "finance.account.create", 0, body).(domain.Account)
	plan := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	after := must(t, s, "finance.loan.adjustment.save", a.ID, adjustmentBody(plan.Revision, 4, "3.1234")).(*domain.LoanPlan)
	b, _ := json.Marshal(after)
	stored := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	c, _ := json.Marshal(stored)
	if string(b) != string(c) || len(stored.Schedule) != 480 {
		t.Fatal("长期计划存储截断")
	}
}
