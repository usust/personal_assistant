// 文件职责：封装模型服务 HTTP 请求与上游协议转换。

package repository

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"

	domain "personal_assistant_server/internal/ai/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
)

// goodScreenshot 返回完整模型输出；参数：无；返回值：固定 JSON 文本，无外部数据。
func goodScreenshot() string {
	return `{"channel":"wechat","status":"paid","kind":"expense","currency":"CNY","amount":"20.50","merchant":"午餐店","date":"2026-09-29","time":"12:30","paymentMethod":"招商1234","orderId":"O123","category":"餐饮","amountEvidence":"实付20.50","paymentEvidence":"支付成功","needsReview":false,"reason":""}`
}

// TestScreenshotValidation 验证模型字段严格边界；参数：t 为测试上下文；返回值：无，不调用真实模型。
func TestScreenshotValidation(t *testing.T) {
	value, err := parseScreenshot(goodScreenshot())
	if err != nil || *value.NeedsReview {
		t.Fatalf("有效识别失败: %+v %v", value, err)
	}
	for _, raw := range []string{
		strings.Replace(goodScreenshot(), `"20.50"`, `"0"`, 1), strings.Replace(goodScreenshot(), `"20.50"`, `"-1"`, 1), strings.Replace(goodScreenshot(), `"20.50"`, `"1e2"`, 1),
		strings.Replace(goodScreenshot(), `"20.50"`, `"1.001"`, 1), strings.Replace(goodScreenshot(), `"2026-09-29"`, `"2026-02-30"`, 1),
		strings.Replace(goodScreenshot(), `"12:30"`, `"25:00"`, 1), strings.Replace(goodScreenshot(), `"needsReview":false,`, "", 1),
		strings.Replace(goodScreenshot(), `"merchant":"午餐店"`, `"merchant":null`, 1),
		strings.Replace(goodScreenshot(), `"reason":""`, `"reason":"","accountId":123`, 1), goodScreenshot() + goodScreenshot(), "```json\n" + goodScreenshot() + "\n```",
	} {
		if _, err := parseScreenshot(raw); err == nil {
			t.Fatalf("接受了非法输出: %s", raw)
		}
	}
	for _, raw := range []string{strings.Replace(goodScreenshot(), `"CNY"`, `"USD"`, 1), strings.Replace(goodScreenshot(), `"paid"`, `"refund"`, 1), strings.Replace(goodScreenshot(), `"expense"`, `"transfer"`, 1), strings.Replace(goodScreenshot(), `"12:30"`, `""`, 1), strings.Replace(goodScreenshot(), `"paymentEvidence":"支付成功"`, `"paymentEvidence":""`, 1)} {
		value, err := parseScreenshot(raw)
		if err != nil || !*value.NeedsReview {
			t.Fatalf("未强制核对: %+v %v", value, err)
		}
	}
}

// TestScreenshotNote 验证商品备注及旧协议兼容；参数：t 为测试上下文；返回值：无，不访问真实 AI。
func TestScreenshotNote(t *testing.T) {
	for _, note := range []string{`"面筋年糕各两串等3件商品"`, `""`, `null`, `123`, `"` + strings.Repeat("a", 1501) + `"`} {
		raw := strings.Replace(goodScreenshot(), `"reason":""`, `"reason":"","note":`+note+`,"paymentCardLast4":"5510"`, 1)
		value, err := parseScreenshot(raw)
		valid := note == `"面筋年糕各两串等3件商品"` || note == `""`
		if (err == nil) != valid {
			t.Fatalf("备注校验错误: %v", err)
		}
		if valid && note != `""` && value.Note != "面筋年糕各两串等3件商品" {
			t.Fatal("备注未保留")
		}
	}
	if value, err := parseScreenshot(goodScreenshot()); err != nil || value.Note != "" {
		t.Fatal("旧结果应兼容空备注")
	}
}

// TestScreenshotCardLast4 验证尾号协议及英文原始证据；参数：t 为测试上下文；返回值：无，不访问真实 AI。
func TestScreenshotCardLast4(t *testing.T) {
	for _, suffix := range []string{`"1234"`, `""`, `"12345"`, `"12x4"`, `1234`, `null`} {
		raw := strings.Replace(goodScreenshot(), `"reason":""`, `"reason":"","paymentCardLast4":`+suffix, 1)
		raw = strings.Replace(raw, `支付成功`, `Payment successful`, 1)
		value, err := parseScreenshot(raw)
		valid := suffix == `"1234"` || suffix == `""`
		if (err == nil) != valid {
			t.Fatalf("尾号校验错误: %s %v", suffix, err)
		}
		if valid && value.PaymentEvidence != "Payment successful" {
			t.Fatal("不应翻译原始证据")
		}
	}
}

// TestScreenshotImageLimits 验证图片类型、格式及尺寸边界；参数：t 为测试上下文；返回值：无，只生成内存图片。
func TestScreenshotImageLimits(t *testing.T) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	valid := "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes())
	if err := ValidateScreenshot(valid); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"https://example.com/image.png", "data:image/png;base64,broken", "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes()[:33]), strings.Replace(valid, "image/png", "image/jpeg", 1), "data:image/png;base64," + strings.Repeat("A", (4<<20)+1)} {
		if ValidateScreenshot(raw) == nil {
			t.Fatal("接受无效图片")
		}
	}
	// JPEG 与 PNG 均为公开支持格式，验证完整文件而非只核对 data URL 前缀。
	var jpegBuffer bytes.Buffer
	if err := jpeg.Encode(&jpegBuffer, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		t.Fatal(err)
	}
	if err := ValidateScreenshot("data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(jpegBuffer.Bytes())); err != nil {
		t.Fatal(err)
	}
	buf.Reset()
	if err := png.Encode(&buf, image.NewGray(image.Rect(0, 0, 4097, 1))); err != nil {
		t.Fatal(err)
	}
	if ValidateScreenshot("data:image/png;base64,"+base64.StdEncoding.EncodeToString(buf.Bytes())) == nil {
		t.Fatal("接受超宽图片")
	}
}

type screenshotTransport func(*http.Request) (*http.Response, error)

// RoundTrip 使用内存上游替身；参数：r 为真实编码请求；返回值：替身响应及错误，不联网。
func (f screenshotTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// TestScreenshotModelProtocol 验证无工具请求、密钥、结果校验和禁止跳转；参数：t 为测试上下文；返回值：无，不外发截图。
func TestScreenshotModelProtocol(t *testing.T) {
	calls := 0
	// 传输回调输入模型请求、返回内存响应；检查专用接口未携带工具并限制重定向。
	transport := screenshotTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer secret" {
			t.Fatal("连接协议错误")
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["tools"] != nil {
			t.Fatal("图片接口不应有工具")
		}
		if calls == 1 {
			messages := body["messages"].([]any)
			prompt := messages[0].(map[string]any)["content"].(string)
			if !strings.Contains(prompt, screenshotLanguagePrompt) || !strings.Contains(prompt, screenshotWechatPrompt) {
				t.Fatal("缺少中文输出及卡尾号识别要求")
			}
			content := messages[1].(map[string]any)["content"].([]any)
			imageURL := content[0].(map[string]any)["image_url"].(map[string]any)
			if imageURL["detail"] != "high" {
				t.Fatal("账单小字应使用高精度识别")
			}
			payload, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": goodScreenshot()}}}})
			return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(payload))}, nil
		}
		return &http.Response{StatusCode: 307, Header: http.Header{"Location": []string{"https://other.invalid/steal"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
	})
	client := NewHTTPClient(&http.Client{Transport: transport})
	config := aiconfigservice.Connection{BaseURL: "https://model.invalid/v1", ModelName: "vision-test", APIKey: "secret"}
	if _, err := client.RecognizeScreenshot(context.Background(), config, domain.ScreenshotInput{Image: "data:image/png;base64,test"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RecognizeScreenshot(context.Background(), config, domain.ScreenshotInput{}); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatal("跳转应拒绝且错误脱敏")
	}
	if calls != 2 {
		t.Fatal("不应重试或跟随跳转")
	}
}

// TestScreenshotChannelOptional 验证渠道未知或非微信支付宝不会阻止识别；参数：t 为测试上下文；返回值：无，不调用真实模型。
func TestScreenshotChannelOptional(t *testing.T) {
	for _, channel := range []string{"unknown", "other", "bank", ""} {
		raw := strings.Replace(goodScreenshot(), `"channel":"wechat"`, `"channel":"`+channel+`"`, 1)
		result, err := parseScreenshot(raw)
		if err != nil || *result.NeedsReview || result.Channel != channel {
			t.Fatalf("渠道 %q 不应阻止识别：%+v %v", channel, result, err)
		}
	}
	if strings.Contains(screenshotPrompt, "只识别微信或支付宝") {
		t.Fatal("提示词仍限制支付来源")
	}
}

// TestScreenshotDefaultCurrency 验证缺省币种按人民币处理且保留独立字段；参数：t 为测试上下文；返回值：无，不联网。
func TestScreenshotDefaultCurrency(t *testing.T) {
	raw := strings.Replace(goodScreenshot(), `"currency":"CNY"`, `"currency":""`, 1)
	raw = strings.Replace(raw, `"time":"12:30"`, `"time":""`, 1)
	result, err := parseScreenshot(raw)
	if err != nil || result.Currency != "CNY" || result.Amount != "20.50" || result.Merchant != "午餐店" || result.Date != "2026-09-29" || !*result.NeedsReview {
		t.Fatalf("缺失时间不能丢弃其余资料：%+v %v", result, err)
	}
	foreign, err := parseScreenshot(strings.Replace(goodScreenshot(), `"CNY"`, `"USD"`, 1))
	if err != nil || foreign.Currency != "USD" || !*foreign.NeedsReview {
		t.Fatalf("明确外币不可默认人民币：%+v %v", foreign, err)
	}
}
