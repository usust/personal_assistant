// 文件职责：验证餐食视觉解析的严格字段、数值与无工具网络边界，全部使用内存替身。
package repository

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	healthmodel "personal_assistant_server/internal/health/model"
)

// validMealAnalysis 返回固定合法估算；参数：无；返回值：JSON文本；不访问网络。
func validMealAnalysis() string {
	return `{"recognized":true,"items":[{"name":"米饭","grams":150,"calories":174}],"note":"照片估算，份量和隐藏油、酱料不确定，请核对。"}`
}

// TestMealAnalysisParser 验证结果严格边界；参数：t 为测试上下文；返回值：无；不使用真实AI。
func TestMealAnalysisParser(t *testing.T) {
	if result, err := parseMealAnalysis(validMealAnalysis()); err != nil || !result.Recognized || len(result.Items) != 1 {
		t.Fatalf("valid: %#v %v", result, err)
	}
	if result, err := parseMealAnalysis(`{"recognized":false,"items":[],"note":"非食物照片，无法判断"}`); err != nil || result.Recognized || result.Items == nil {
		t.Fatalf("nonfood: %#v %v", result, err)
	}
	bad := []string{
		`null`, `{}`, validMealAnalysis() + `{}`, "```json\n" + validMealAnalysis() + "\n```",
		strings.Replace(validMealAnalysis(), `"recognized":true`, `"recognized":false`, 1),
		`{"recognized":true,"items":[],"note":""}`,
		`{"recognized":false,"items":null,"note":""}`,
		strings.Replace(validMealAnalysis(), `"recognized":true`, `"recognized":null`, 1),
		strings.Replace(validMealAnalysis(), `"recognized":true`, `"recognized":true,"recognized":false`, 1),
		strings.Replace(validMealAnalysis(), `"recognized":true,`, ``, 1),
		strings.Replace(validMealAnalysis(), `"grams":150`, `"grams":null`, 1),
		strings.Replace(validMealAnalysis(), `"calories":174`, `"calories":null`, 1),
		strings.Replace(validMealAnalysis(), `"name":"米饭"`, `"name":null`, 1),
		strings.Replace(validMealAnalysis(), `"name":"米饭"`, `"name":" "`, 1),
		strings.Replace(validMealAnalysis(), `"grams":150`, `"grams":0`, 1),
		strings.Replace(validMealAnalysis(), `"grams":150`, `"grams":-1`, 1),
		strings.Replace(validMealAnalysis(), `"grams":150`, `"grams":10001`, 1),
		strings.Replace(validMealAnalysis(), `"grams":150`, `"grams":1e999`, 1),
		strings.Replace(validMealAnalysis(), `"calories":174`, `"calories":20001`, 1),
		strings.Replace(validMealAnalysis(), `"calories":174`, `"calories":"174"`, 1),
		strings.Replace(validMealAnalysis(), `"calories":174`, `"calories":174,"tool":"create"`, 1),
		strings.Replace(validMealAnalysis(), `"name":"米饭"`, `"name":"`+strings.Repeat("饭", 41)+`"`, 1),
		`{"recognized":false,"items":[],"note":"` + strings.Repeat("a", 1501) + `"}`,
		`{"recognized":false,"items":[],"note":null}`,
		`{"recognized":false,"items":[],"note":"","user_id":2}`,
		strings.Repeat(" ", 32<<10) + validMealAnalysis(),
	}
	items := []healthmodel.MealItem{}
	for i := 0; i < 21; i++ {
		items = append(items, healthmodel.MealItem{Name: "米饭", Grams: 1, Calories: 1})
	}
	raw, err := json.Marshal(healthmodel.MealAnalysis{Recognized: true, Items: items})
	if err != nil {
		t.Fatal(err)
	}
	bad = append(bad, string(raw))
	for i, raw := range bad {
		if _, err := parseMealAnalysis(raw); err == nil {
			t.Fatalf("invalid case %d accepted", i)
		}
	}
}

// TestMealModelProtocol 验证专用提示词、请求无工具、响应限额、脱敏与禁止跳转；参数：t 为测试上下文；返回值：无；使用内存HTTP传输，不调用真实AI。
func TestMealModelProtocol(t *testing.T) {
	config := aiconfigservice.Connection{BaseURL: "https://vision.invalid/v1", ModelName: "vision", APIKey: "private-key"}
	input := healthmodel.MealAnalysisInput{Image: "data:image/jpeg;base64,test"}
	calls := 0
	status, responseBody := 200, ""
	// 传输回调验证编码请求；参数r为HTTP请求；返回内存响应和nil错误，不访问网络。
	transport := screenshotTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer private-key" {
			t.Fatal("wrong connection")
		}
		var request map[string]json.RawMessage
		if json.NewDecoder(r.Body).Decode(&request) != nil {
			t.Fatal("bad body")
		}
		if _, ok := request["tools"]; ok {
			t.Fatal("tools supplied")
		}
		if !strings.Contains(string(request["messages"]), "不可信资料") || strings.Contains(string(request["messages"]), "支付截图") || !strings.Contains(string(request["messages"]), "隐藏油") {
			t.Fatal("wrong prompt")
		}
		header := make(http.Header)
		if status == 302 {
			header.Set("Location", "https://other.invalid/leak")
		}
		return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(responseBody))}, nil
	})
	client := NewHTTPClient(&http.Client{Transport: transport})
	good, err := json.Marshal(map[string]any{"choices": []any{map[string]any{"finish_reason": "stop", "message": map[string]any{"content": validMealAnalysis()}}}})
	if err != nil {
		t.Fatal(err)
	}
	responseBody = string(good)
	if _, err := client.AnalyzeMeal(context.Background(), config, input); err != nil {
		t.Fatal(err)
	}
	for _, extra := range []map[string]any{{"tool_calls": []any{map[string]any{"id": "tool", "function": map[string]any{"name": "save"}}}}, {"function_call": map[string]any{"name": "save"}}} {
		extra["content"] = validMealAnalysis()
		raw, err := json.Marshal(map[string]any{"choices": []any{map[string]any{"message": extra}}})
		if err != nil {
			t.Fatal(err)
		}
		responseBody = string(raw)
		if _, err := client.AnalyzeMeal(context.Background(), config, input); err == nil {
			t.Fatal("accepted tool call")
		}
	}
	for _, raw := range []string{strings.Repeat("x", (64<<10)+1), `{"choices":[]}`, string(good) + `{}`, `private-key upstream failure`} {
		responseBody = raw
		if _, err := client.AnalyzeMeal(context.Background(), config, input); err == nil || strings.Contains(err.Error(), "private-key") {
			t.Fatal("bad response or secret leaked")
		}
	}
	status, responseBody = 302, "private-key"
	before := calls
	if _, err := client.AnalyzeMeal(context.Background(), config, input); err == nil || calls != before+1 {
		t.Fatal("redirect followed")
	}
}
