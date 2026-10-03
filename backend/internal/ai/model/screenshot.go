// 文件职责：定义AI领域模型与协议契约。

package model

import ()

// ScreenshotInput 只允许已授权配置与内嵌图片；不接受图片 URL、工具、提示词或账本写入命令。
type ScreenshotInput struct {
	ConfigID      uint     `json:"configId"`
	ConfigVersion string   `json:"configVersion"`
	Image         string   `json:"image"`
	Categories    []string `json:"categories,omitempty"`
}

// ScreenshotResult 是只读识别结果；空字段表示未知，needsReview 必须由模型明确提供。
type ScreenshotResult struct {
	Channel          string `json:"channel"`
	Status           string `json:"status"`
	Kind             string `json:"kind"`
	Currency         string `json:"currency"`
	Amount           string `json:"amount"`
	Merchant         string `json:"merchant"`
	Date             string `json:"date"`
	Time             string `json:"time"`
	PaymentMethod    string `json:"paymentMethod"`
	PaymentCardLast4 string `json:"paymentCardLast4"`
	OrderID          string `json:"orderId"`
	Category         string `json:"category"`
	Note             string `json:"note,omitempty"`
	AmountEvidence   string `json:"amountEvidence"`
	PaymentEvidence  string `json:"paymentEvidence"`
	NeedsReview      *bool  `json:"needsReview"`
	Reason           string `json:"reason"`
}
