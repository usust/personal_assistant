// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	domain "personal_assistant_server/internal/finance/model"
)

// TestBankStatementReprice 验证截图的等额本金调息、账单利息校准与保存重读；参数：t 为测试上下文；返回值：无，仅写临时数据库。
func TestBankStatementReprice(t *testing.T) {
	s := fixture(t)
	body := loanBody()
	body["loanPrincipal"], body["loanAnnualRate"], body["loanMethod"] = "650000.00", "3.3", "equal_principal"
	body["loanPeriods"], body["loanPaidPeriods"], body["loanFirstPaymentDate"] = 360, 45, "2022-11-18"
	a := must(t, s, "finance.account.create", 0, body).(domain.Account)
	before := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan)
	change := map[string]any{"revision": before.Revision, "kind": "reprice", "scope": "period", "fromPeriod": 39, "annualRate": "3.2", "payment": "3376.92"}
	preview := must(t, s, "finance.loan.adjustment.preview", a.ID, change).(*domain.LoanPlan)
	if !reflect.DeepEqual(before.Schedule[:38], preview.Schedule[:38]) {
		t.Fatal("调息改写此前期次")
	}
	for i, want := range []domain.Money{337692, 335112, 334630, 334149, 333667, 333186, 332704, 332223} {
		row := preview.Schedule[38+i]
		if row.Payment != want || row.Principal != 180556 || row.AnnualRate != "3.2" || row.Payment != row.Principal+row.Interest {
			t.Fatalf("第 %d 期不符: %+v, 应还 %d", row.Period, row, want)
		}
	}
	if preview.Schedule[38].Interest != 157136 {
		t.Fatal("未按银行账单校准本期利息")
	}
	for i, row := range preview.Schedule {
		if row.Remaining != before.Schedule[i].Remaining {
			t.Fatal("调息改变本金摊销", i)
		}
	}
	if unchanged := must(t, s, "finance.loan.plan", a.ID, nil).(*domain.LoanPlan); !reflect.DeepEqual(before, unchanged) {
		t.Fatal("预览产生写入")
	}
	saved := must(t, s, "finance.loan.adjustment.save", a.ID, change).(*domain.LoanPlan)
	preview.Revision++
	if !reflect.DeepEqual(preview, saved) || !reflect.DeepEqual(saved, must(t, s, "finance.loan.plan", a.ID, nil)) {
		t.Fatal("预览保存重读不一致")
	}
}

// TestBankStatementRepriceGuards 验证联合调整的金额、利率及范围边界；参数：t 为测试上下文；返回值：无，不写数据库。
func TestBankStatementRepriceGuards(t *testing.T) {
	a := domain.Account{LoanTerms: loanFixture()}
	before, err := accountLoanPlan(a)
	if err != nil {
		t.Fatal(err)
	}
	v := 0
	amount := domain.Money(1)
	in := domain.LoanAdjustmentInput{Revision: &v, Kind: "reprice", Scope: "period", FromPeriod: 4, AnnualRate: "3.2", Payment: &amount}
	if _, err = adjustedLoanPlan(a, before, in); err == nil {
		t.Fatal("允许负利息")
	}
	amount = before.Schedule[3].Payment
	for _, rate := range []string{"", "-1", "100.0001"} {
		in.AnnualRate = rate
		if _, err = adjustedLoanPlan(a, before, in); err == nil {
			t.Fatal("接受非法利率", rate)
		}
	}
	in.AnnualRate, in.Scope = "3.2", "future"
	if _, err = adjustedLoanPlan(a, before, in); err == nil {
		t.Fatal("接受错误范围")
	}
}

// TestBankStatementPreviewFixture 验证 iOS 只读账单样本与后端计算结果一致。
// 参数：t 为测试上下文，要求当前工作目录为本测试包目录；返回值：无，只读仓库样本文件，读取或校验失败时标记测试失败。
func TestBankStatementPreviewFixture(t *testing.T) {
	// 使用当前仓库的 iOS 资源目录，避免本机残留的旧目录掩盖干净检出中的路径错误。
	const root = "../../../../apps/iOS/PersonalAssistant/Resources/"
	raw, err := os.ReadFile(root + "LoanUIPreview.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Account domain.Account  `json:"account"`
		Plan    domain.LoanPlan `json:"plan"`
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	raw, err = os.ReadFile(root + "LoanAdjustmentUIPreview.json")
	if err != nil {
		t.Fatal(err)
	}
	var samples []struct {
		Request domain.LoanAdjustmentInput `json:"request"`
		Plan    domain.LoanPlan            `json:"plan"`
	}
	if err = json.Unmarshal(raw, &samples); err != nil {
		t.Fatal(err)
	}
	for _, sample := range samples {
		if sample.Request.Kind != "reprice" {
			continue
		}
		fixture.Account.LoanRevision = *sample.Request.Revision
		actual, err := adjustedLoanPlan(fixture.Account, &fixture.Plan, sample.Request)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(actual, &sample.Plan) {
			t.Fatal("iOS 账单样本与计算器不一致")
		}
	}
}
