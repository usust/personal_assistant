// 文件职责：定义记账领域模型与协议契约。

package model

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const MaxMoney Money = 100_000_000_000_000

// 预编译业务字段校验规则。
var moneyPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]{0,12})(\.[0-9]{1,2})?$`)

// ParseMoney 解析金额；参数：s 为不含指数、空白且至多两位小数的十进制字符串；返回值：分及格式/范围错误，无副作用。
func ParseMoney(s string) (Money, error) {
	// 检查字段是否符合约定格式。
	if !moneyPattern.MatchString(s) {
		// 拒绝本次操作：金额必须是至多两位小数的字符串。
		return 0, invalid("金额必须是至多两位小数的字符串")
	}
	// 检查输入是否符合预期前缀。
	neg := strings.HasPrefix(s, "-")
	// 去除协议或字段前缀后再解析。
	s = strings.TrimPrefix(s, "-")
	// 拆分复合输入，供后续逐项处理。
	parts := strings.Split(s, ".")
	// 将输入字段解析为整数。
	whole, _ := strconv.ParseInt(parts[0], 10, 64)
	frac := int64(0)
	if len(parts) == 2 {
		// 将输入字段解析为整数。
		frac, _ = strconv.ParseInt((parts[1] + "00")[:2], 10, 64)
	}
	n := Money(whole*100 + frac)
	if n > MaxMoney {
		// 拒绝本次操作：金额超出上限。
		return 0, invalid("金额超出上限")
	}
	if neg {
		n = -n
	}
	return n, nil
}

// ErrInvalid 是金额与记账业务共用的输入错误标识。
var ErrInvalid = errors.New("财务参数无效")

// invalid 构造金额校验错误；参数：s 为可公开说明；返回值：带业务分类的错误；无副作用。
func invalid(s string) error { return fmt.Errorf("%w: %s", ErrInvalid, s) }

// Money 以分存储，JSON 始终为两位小数字符串，避免浮点误差。
type Money int64

// String 格式化精确金额；参数：无；返回值：两位小数字符串，无副作用。
func (m Money) String() string {
	sign := ""
	if m < 0 {
		sign = "-"
		m = -m
	}
	// 生成当前操作需要的展示或协议文本。
	return fmt.Sprintf("%s%d.%02d", sign, m/100, m%100)
}

// MarshalJSON 保持前端字符串契约；参数：无；返回值：JSON 字节及编码错误，无副作用。
func (m Money) MarshalJSON() ([]byte, error) { return json.Marshal(m.String()) }

// UnmarshalJSON 拒绝浮点和 null；参数：b 为 JSON 字符串；返回值：校验错误，成功设置接收者金额。
func (m *Money) UnmarshalJSON(b []byte) error {
	var s string
	// 解析业务数据，供后续校验与处理。
	if string(b) == "null" || json.Unmarshal(b, &s) != nil {
		// 拒绝本次操作：金额必须为字符串。
		return invalid("金额必须为字符串")
	}
	// 按精确金额格式解析输入。
	n, e := ParseMoney(s)
	if e == nil {
		*m = n
	}
	return e
}
