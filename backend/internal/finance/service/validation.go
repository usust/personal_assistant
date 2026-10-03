// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	domain "personal_assistant_server/internal/finance/model"
)

// 拒绝本次操作：财务参数无效。
var ErrInvalid = domain.ErrInvalid

// 拒绝本次操作：财务记录不存在。
var ErrNotFound = errors.New("财务记录不存在")

// 拒绝本次操作：财务操作冲突。
var ErrConflict = errors.New("财务操作冲突")

// invalid 构建公开校验错误；参数：s 为不含敏感信息的说明；返回值：可分类错误，无副作用。
func Invalid(s string) error { return fmt.Errorf("%w: %s", ErrInvalid, s) }

// decode 严格解析对象并拒绝未知字段、null 和多重 JSON；参数：raw 为原始输入，out 为非 nil DTO 指针；返回值：公开错误，无数据库副作用。
func Decode(raw json.RawMessage, out any) error {
	// 先拒绝无效 JSON，避免进入后续处理。
	if len(raw) == 0 || !json.Valid(raw) || bytes.TrimSpace(raw)[0] != '{' {
		// 拒绝本次操作：必须提交 JSON 对象。
		return Invalid("必须提交 JSON 对象")
	}
	// 为请求数据创建 JSON 解码器。
	dec := json.NewDecoder(bytes.NewReader(raw))
	// 拒绝未定义字段，避免客户端误传被静默忽略。
	dec.DisallowUnknownFields()
	// 解析输入数据，交给后续业务校验。
	if dec.Decode(out) != nil {
		// 拒绝本次操作：字段未知或类型无效。
		return Invalid("字段未知或类型无效")
	}
	return nil
}

// validDate 验证真实公历日期；参数：s 为 YYYY-MM-DD；返回值：有效为 true，无副作用。
func validDate(s string) bool {
	// 按业务格式解析日期或时间。
	d, e := time.Parse("2006-01-02", s)
	// 取得日期中的年份，供周期计算。
	return e == nil && d.Year() >= 1900 && d.Year() <= 9999
}

// validText 校验字符长度及必填；参数：s 为文本，max 为字节上限，required 表示禁止空白；返回值：有效为 true。
func validText(s string, max int, required bool) bool {
	// 规范化输入，避免首尾空白影响校验。
	return len(s) <= max && (!required || strings.TrimSpace(s) != "")
}

// accountFields 生成经过白名单校验的局部更新 map；参数：raw 为字段对象，create 表示允许期初余额；返回值：数据库字段 map 或错误，允许 false、0、空备注。
func accountFields(raw json.RawMessage, create bool) (map[string]any, error) {
	var body map[string]json.RawMessage
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(raw, &body); e != nil {
		return nil, e
	}
	if len(body) == 0 {
		// 拒绝本次操作：至少提交一个字段。
		return nil, Invalid("至少提交一个字段")
	}
	fields := map[string]any{}
	for k, v := range body {
		if string(v) == "null" {
			// 拒绝本次操作：账户字段不可为 null。
			return nil, Invalid("账户字段不可为 null")
		}
		switch k {
		case "cards":
			var cards []domain.AccountCard
			// 为请求数据创建 JSON 解码器。
			decoder := json.NewDecoder(bytes.NewReader(v))
			// 拒绝未定义字段，避免客户端误传被静默忽略。
			decoder.DisallowUnknownFields()
			// 解析输入数据，交给后续业务校验。
			if decoder.Decode(&cards) != nil || cards == nil || len(cards) > 30 {
				// 拒绝本次操作：卡片列表无效，最多 30 张。
				return nil, Invalid("卡片列表无效，最多 30 张")
			}
			ids := map[string]bool{}
			for i := range cards {
				card := &cards[i]
				// 规范化输入，避免首尾空白影响校验。
				card.Name = strings.TrimSpace(card.Name)
				// 构造当前操作需要的完整路径或文本。
				card.MaskedAccountNumber = strings.Join(strings.Fields(card.MaskedAccountNumber), "")
				// 检查字段是否符合约定格式。
				if !regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`).MatchString(card.ID) || ids[card.ID] || !validText(card.Name, 128, true) || !regexp.MustCompile(`^([0-9]{4}|[0-9]{12,19}|\*{4}[0-9]{4})$`).MatchString(card.MaskedAccountNumber) {
					// 拒绝本次操作：卡片名称、编号或卡号无效。
					return nil, Invalid("卡片名称、编号或卡号无效")
				}
				ids[card.ID] = true
				card.MaskedAccountNumber = "**** " + card.MaskedAccountNumber[len(card.MaskedAccountNumber)-4:]
			}
			// 卡片仅作为账户资料更新；空数组允许清空，未提交时不覆盖原卡片，额度与余额不变。
			encoded, err := json.Marshal(cards)
			if err != nil {
				return nil, err
			}
			fields["cards"] = string(encoded)
		case "name", "accountType", "institution", "maskedAccountNumber", "currency", "notes":
			var s string
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &s) != nil {
				// 拒绝本次操作：文本字段类型无效。
				return nil, Invalid("文本字段类型无效")
			}
			column := map[string]string{"name": "name", "accountType": "account_type", "institution": "institution", "maskedAccountNumber": "masked_account_number", "currency": "currency", "notes": "notes"}[k]
			max := 128
			if k == "notes" {
				max = 2000
			}
			// 检查文本长度与必填约束。
			if !validText(s, max, k == "name") {
				// 拒绝本次操作：账户文本长度或内容无效。
				return nil, Invalid("账户文本长度或内容无效")
			}
			// 检查输入是否包含指定内容。
			if k == "accountType" && !strings.Contains("|bank|alipay|wechat|cash|savings|investment|other|", "|"+s+"|") {
				// 拒绝本次操作：账户类型无效。
				return nil, Invalid("账户类型无效")
			}
			if k == "currency" && s != "CNY" {
				// 拒绝本次操作：当前仅支持 CNY，不自动换算币种。
				return nil, Invalid("当前仅支持 CNY，不自动换算币种")
			}
			if k == "maskedAccountNumber" {
				// 预编译业务字段校验规则。
				digits := regexp.MustCompile(`^[0-9* ]{0,24}$`)
				// 检查字段是否符合约定格式。
				if !digits.MatchString(s) {
					// 拒绝本次操作：卡号仅接受数字或脱敏符号。
					return nil, Invalid("卡号仅接受数字或脱敏符号")
				}
				if len(s) > 4 {
					s = "**** " + s[len(s)-4:]
				}
			}
			fields[column] = s
		case "reminderDays":
			var n int
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &n) != nil || (n != -1 && n != 0 && n != 1 && n != 3 && n != 7) {
				// 拒绝本次操作：还款提醒选项无效。
				return nil, Invalid("还款提醒选项无效")
			}
			fields["reminder_days"] = n
		case "reminderTime":
			var value string
			// 解析待校验字段，供后续校验与处理。
			if json.Unmarshal(v, &value) != nil {
				// 拒绝本次操作：提醒时间无效。
				return nil, Invalid("提醒时间无效")
			}
			// 按业务格式解析日期或时间。
			if _, err := time.Parse("15:04", value); err != nil || len(value) != 5 {
				// 拒绝本次操作：提醒时间必须为 HH:mm。
				return nil, Invalid("提醒时间必须为 HH:mm")
			}
			fields["reminder_time"] = value
		case "creditLimit", "currentDebt":
			var m domain.Money
			// 解析业务数据，供后续校验与处理。
			if e := json.Unmarshal(v, &m); e != nil {
				return nil, e
			}
			if k == "creditLimit" {
				if m < 0 {
					// 拒绝本次操作：信用额度不能为负数。
					return nil, Invalid("信用额度不能为负数")
				}
				fields["credit_limit"] = m
			} else {
				// 前端以正数表达欠款，负数表达溢缴款；账本始终采用资产余额符号。
				if _, exists := body["balance"]; exists {
					// 拒绝本次操作：欠款与余额不能同时提交。
					return nil, Invalid("欠款与余额不能同时提交")
				}
				fields["balance"] = -m
			}
		case "billingDay", "repaymentDay":
			var n int
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &n) != nil || n < 0 || n > 31 {
				// 拒绝本次操作：日期必须为 1 至 31，或用 0 清除。
				return nil, Invalid("日期必须为 1 至 31，或用 0 清除")
			}
			fields[map[string]string{"billingDay": "billing_day", "repaymentDay": "repayment_day"}[k]] = n
		case "billDayInclusive", "selectable":
			var b bool
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &b) != nil {
				// 拒绝本次操作：账户开关必须为布尔值。
				return nil, Invalid("账户开关必须为布尔值")
			}
			fields[map[string]string{"billDayInclusive": "bill_day_inclusive", "selectable": "selectable"}[k]] = b
		case "balance":
			if !create {
				// 拒绝本次操作：期初余额不可直接修改，请通过流水调整。
				return nil, Invalid("期初余额不可直接修改，请通过流水调整")
			}
			var m domain.Money
			// 解析业务数据，供后续校验与处理。
			if e := json.Unmarshal(v, &m); e != nil {
				return nil, e
			}
			fields["balance"] = m
		case "includeInNetWorth":
			var b bool
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &b) != nil {
				// 拒绝本次操作：includeInNetWorth 必须为布尔值。
				return nil, Invalid("includeInNetWorth 必须为布尔值")
			}
			fields["include_in_net_worth"] = b
		case "sortOrder":
			var n int
			// 解析业务数据，供后续校验与处理。
			if json.Unmarshal(v, &n) != nil || n < 0 || n > 1000000 {
				// 拒绝本次操作：排序值无效。
				return nil, Invalid("排序值无效")
			}
			fields["sort_order"] = n
		case "loanPrincipal", "loanAnnualRate", "loanMethod", "loanPeriods", "loanPaidPeriods", "loanFirstPaymentDate", "loanLender", "loanReceivingAccountId":
			// 校验并转换贷款字段变更。
			column, value, err := loanFields(k, v)
			if err != nil {
				return nil, err
			}
			fields[column] = value
		default:
			// 拒绝本次操作：不允许更新账户字段: 。
			return nil, Invalid("不允许更新账户字段: " + k)
		}
	}
	if create {
		if _, ok := fields["name"]; !ok {
			// 拒绝本次操作：账户名称必填。
			return nil, Invalid("账户名称必填")
		}
	}
	return fields, nil
}

// validate 校验流水结构；参数：无；返回值：字段错误，不访问数据库；关联记录权限在事务中另行验证。
func validateTransactionInput(in domain.TransactionInput) error {
	// 检查流水时间是否有效。
	if !validTransactionTime(in.TransactionTime) {
		// 拒绝本次操作：交易时间须为 HH:mm。
		return Invalid("交易时间须为 HH:mm")
	}
	// 支出优惠只能减免本笔金额，不作为收入或转账返现，实付必须为正。
	if in.Discount < 0 || (in.Discount > 0 && (in.Type != "expense" || in.Discount >= in.Amount)) {
		// 拒绝本次操作：优惠仅用于支出且须小于原金额。
		return Invalid("优惠仅用于支出且须小于原金额")
	}
	// 检查日期是否满足业务格式。
	if in.AccountID == 0 || in.Amount <= 0 || in.Amount > maxMoney || !validDate(in.TransactionDate) {
		// 拒绝本次操作：账户、正数金额或交易日期无效。
		return Invalid("账户、正数金额或交易日期无效")
	}
	if in.Type != "income" && in.Type != "expense" && in.Type != "transfer" {
		// 拒绝本次操作：流水类型无效。
		return Invalid("流水类型无效")
	}
	if in.TargetCreditCardID != nil {
		// 拒绝本次操作：信用卡还款尚未启用。
		return Invalid("信用卡还款尚未启用")
	}
	if in.Fee < 0 || in.Fee > maxMoney || (in.Type != "transfer" && in.Fee != 0) {
		// 拒绝本次操作：手续费只能用于转账，且不能为负数。
		return Invalid("手续费只能用于转账，且不能为负数")
	}
	// 优惠是独立返现，不能用负手续费或减少转账本金表示；零优惠不得携带到账设置。
	if in.Rebate < 0 || in.Rebate > maxMoney || (in.Type != "transfer" && in.Rebate != 0) || (in.Rebate == 0 && (in.RebateAccountID != nil || in.RebatePending)) || (in.RebateAccountID != nil && *in.RebateAccountID == 0) {
		// 拒绝本次操作：优惠仅用于转账，金额必须非负且到账设置须有优惠金额。
		return Invalid("优惠仅用于转账，金额必须非负且到账设置须有优惠金额")
	}
	if in.Type == "transfer" {
		if in.TargetAccountID == nil || *in.TargetAccountID == 0 || *in.TargetAccountID == in.AccountID || in.CategoryID != nil {
			// 拒绝本次操作：转账必须指定不同的目标账户且不得设置分类。
			return Invalid("转账必须指定不同的目标账户且不得设置分类")
		}
	} else if in.TargetAccountID != nil {
		// 拒绝本次操作：收支不能设置转入账户。
		return Invalid("收支不能设置转入账户")
	}
	// 检查文本长度与必填约束。
	if !validText(in.Counterparty, 128, false) || !validText(in.Description, 2000, false) {
		// 拒绝本次操作：流水文本过长。
		return Invalid("流水文本过长")
	}
	// 检查字段是否符合约定格式。
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{8,96}$`).MatchString(in.RequestID) {
		// 拒绝本次操作：requestId 需为 8 至 96 位字母、数字、下划线或连字符；重试请复用。
		return Invalid("requestId 需为 8 至 96 位字母、数字、下划线或连字符；重试请复用")
	}
	return nil
}

// validTransactionTime 校验交易当地时分；参数：value 为 HH:mm 或表示未知的空字符串；返回值：格式及时分范围是否合法，无副作用。
func validTransactionTime(value string) bool {
	// 检查字段是否符合约定格式。
	return value == "" || regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`).MatchString(value)
}

// maxMoney 保持金额模型与业务校验使用同一上限。
const maxMoney = domain.MaxMoney
