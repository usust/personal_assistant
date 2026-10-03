// 文件职责：绘制验证码图像与干扰线，将验证码文本转换为可返回客户端的图片。

package service

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/png"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gobold"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

const (
	captchaImageWidth     = 140
	captchaImageHeight    = 48
	captchaNoiseDotCount  = 180
	captchaNoiseLineCount = 12
	captchaFontSize       = 22
	captchaTextMargin     = 8
)

// renderCaptcha 使用内嵌字体生成带抗锯齿文字的 PNG 验证码图片。
// 参数：code 必须为非空 ASCII 验证码，当前调用方固定生成 6 位；返回值：PNG Data URL 及随机数、字体或编码错误。
// 空字符串会导致除零 panic，过长输入会超出图像布局，因此仅供内部已生成验证码使用。
func renderCaptcha(code string) (string, error) {
	// 创建验证码绘制画布。
	img := image.NewRGBA(image.Rect(0, 0, captchaImageWidth, captchaImageHeight))
	// 使用柔和的纵向渐变背景，避免图片显得过于单调。
	for y := range captchaImageHeight {
		shade := uint8(y * 8 / captchaImageHeight)
		background := color.RGBA{R: 244 - shade, G: 249 - shade, B: 252 - shade/2, A: 255}
		for x := range captchaImageWidth {
			// 绘制验证码像素。
			img.SetRGBA(x, y, background)
		}
	}

	// 从安全随机源生成验证码所需数据。
	noise, err := secureRandom(captchaNoiseDotCount*2 + captchaNoiseLineCount*5)
	if err != nil {
		return "", err
	}
	for i := range captchaNoiseDotCount {
		x := int(noise[i*2]) % captchaImageWidth
		y := int(noise[i*2+1]) % captchaImageHeight
		// 绘制验证码像素。
		img.SetRGBA(x, y, color.RGBA{R: 130, G: 175, B: 192, A: 150})
	}
	// 在文字下方绘制随机干扰线；可通过 captchaNoiseLineCount 调整数量。
	lineNoiseOffset := captchaNoiseDotCount * 2
	for i := range captchaNoiseLineCount {
		offset := lineNoiseOffset + i*5
		x0 := int(noise[offset]) % captchaImageWidth
		y0 := int(noise[offset+1]) % captchaImageHeight
		x1 := int(noise[offset+2]) % captchaImageWidth
		y1 := int(noise[offset+3]) % captchaImageHeight
		lineColor := color.RGBA{
			R: 85 + noise[offset+4]%35,
			G: 135 + noise[offset+4]%30,
			B: 155 + noise[offset+4]%35,
			A: 255,
		}
		// 绘制验证码干扰线。
		drawCaptchaLine(img, x0, y0, x1, y1, lineColor)
	}

	// 加载内嵌字体，避免验证码生成依赖服务器安装的字体。
	parsedFont, err := opentype.Parse(gobold.TTF)
	if err != nil {
		// 为失败补充当前操作的错误上下文。
		return "", fmt.Errorf("解析验证码字体: %w", err)
	}
	// 创建验证码绘制使用的字体。
	face, err := opentype.NewFace(parsedFont, &opentype.FaceOptions{
		Size:    captchaFontSize,
		DPI:     72,
		Hinting: font.HintingFull,
	})
	if err != nil {
		// 为失败补充当前操作的错误上下文。
		return "", fmt.Errorf("创建验证码字体: %w", err)
	}

	// 图片生成结束后释放字体资源，失败路径也执行清理。
	defer face.Close()

	// 逐字绘制并添加轻微的高度变化，使排版更自然，同时保持足够的可读性。
	// 根据字符数量平分可用宽度，使 6 个字符也能在保留两侧边距的情况下完整显示。
	characterCellWidth := (captchaImageWidth - captchaTextMargin*2) / len(code)
	for i, character := range []byte(code) {
		characterText := string(character)
		// 测量当前字符宽度，将其居中放入对应字符格。
		characterWidth := font.MeasureString(face, characterText).Ceil()
		x := captchaTextMargin + i*characterCellWidth + (characterCellWidth-characterWidth)/2
		baseline := 33 + int(noise[i]%5) - 2
		drawer := font.Drawer{
			Dst: img,
			// 创建验证码绘制所需的颜色源。
			Src:  image.NewUniform(color.RGBA{R: 24, G: 72 + uint8(i*7), B: 108, A: 255}),
			Face: face,
			// 转换为字体绘制坐标。
			Dot: fixed.P(x, baseline),
		}
		// 将验证码字符绘制到画布。
		drawer.DrawString(characterText)
	}

	var output bytes.Buffer
	// 将验证码图片编码为 PNG。
	if err := png.Encode(&output, img); err != nil {
		// 为失败补充当前操作的错误上下文。
		return "", fmt.Errorf("编码验证码图片: %w", err)
	}
	// 将二进制数据编码为可传输文本。
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(output.Bytes()), nil
}

// drawCaptchaLine 使用 Bresenham 算法绘制一像素宽的干扰线。
// 参数：img 为非 nil 图像；x0、y0 为起点，x1、y1 为终点，均为图像范围内坐标；lineColor 为颜色。
// 返回值：无；直接修改 img 中的像素。
func drawCaptchaLine(img *image.RGBA, x0, y0, x1, y1 int, lineColor color.RGBA) {
	// 取得绘图坐标差的绝对值。
	dx, dy := abs(x1-x0), -abs(y1-y0)
	stepX, stepY := -1, -1
	if x0 < x1 {
		stepX = 1
	}
	if y0 < y1 {
		stepY = 1
	}
	err := dx + dy
	for {
		// 绘制验证码像素。
		img.SetRGBA(x0, y0, lineColor)
		if x0 == x1 && y0 == y1 {
			return
		}
		doubledError := 2 * err
		if doubledError >= dy {
			err += dy
			x0 += stepX
		}
		if doubledError <= dx {
			err += dx
			y0 += stepY
		}
	}
}

// abs 返回坐标差的绝对值。
// 参数：value 为可取反的整数，调用方使用图像坐标差，不得传入最小 int；返回值：非负绝对值；无副作用。
func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}
