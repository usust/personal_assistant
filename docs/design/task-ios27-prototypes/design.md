# iOS 任务管理液态玻璃概念原型

流程：选择或新建清单 → 创建任务 → 设置优先级与起止时间 → 拆分子任务或设置量化进度 → 今日执行 → 完成 → 按需归档。

完成与归档分开：完成用于执行状态，归档用于收起任务；量化任务通过步长推进。后续实现需确认现有数据模型的完成状态契约。

视觉：居中小导航标题；玻璃用于导航和操作层；内容使用普通系统背景；新建任务浮动标签；新建清单居中预览、编辑不显示预览；颜色固定六列三行，最后一格颜色盘。

原型为静态概念，不是已验证的 iOS 27 API 实现。图中的新建清单输入框未完整表现浮动标签动画，实际实现应统一使用浮动标签。进度加减可先调整草稿，记录进度提交一次，避免重复计入。

生成方式：内置 imagegen。

## 图一提示词

Use case: ui-mockup
Create a premium high fidelity iOS task management design prototype board, landscape, three large equally sized full-height iPhone screens side by side, readable Simplified Chinese UI, straight front-on flat screenshots in thin dark phone frames, all screens completely visible. Off-white presentation background. Small board heading "任务管理 · 从收集到执行". Above each phone small step label "01 清单", "02 今日", "03 新建任务". Refined Apple native Liquid Glass concept: translucent refractive glass only navigation buttons, bottom tab bar and primary floating actions; crisp opaque grouped content, pale system background, blue accent, SF-style typography/icons, no excessive glass cards or distracting wallpaper. Matching coherent app.
Screen 1: centered small navigation title "任务清单", right glass plus. At top compact smart entries "今日" count 5, "全部" count 18. Section "我的清单" with ordinary rounded system background rows: blue briefcase circle, name "工作" and smaller note "项目与协作" immediately to right of icon LEFT ALIGNED, count 8; purple book circle "学习" note "每天一点进步" count 6; orange home circle "生活" note "日常安排" count 4. Bottom native glass tab bar with "今日", "清单" selected, "我的". No large duplicated page title.
Screen 2: centered small nav title "今日", glass calendar button top right. Small date "10月5日 周一". Compact segmented filter "全部 / 高优先级". Section "待完成 · 3". White list with circular completion controls, hierarchy and restrained metadata: "准备产品评审" high priority red small flag, "工作 · 14:00", child preview "整理需求 · 完成原型"; "阅读设计书" progress 12/20 页 with blue slim progress bar, "学习"; "买水果" "生活". Section "已完成 · 2" compact muted checked row "整理收件箱". Floating glass blue plus near bottom and coherent native glass tabs with 今日 selected. No completion confetti.
Screen 3: full native pushed creation page, centered small title "新建任务", top left glass back chevron, top right blue glass "保存". No modal overlay. Floating-label outlined rounded input: small blue label "任务名称" at upper left border, value "准备产品评审". Remark field with label "备注" and text "整理本周需求与交互原型". Grouped form rows "清单" value "工作" chevron; "优先级" value "高" red flag; "开始" value "10月5日 09:00"; "结束" value "10月5日 14:00". Row "量化进度" switch off. Simple plus row "添加子任务". Spacious ergonomic real-world mobile typography. No tutorial paragraphs, no invented extra fields. Keyboard hidden.
Ensure all Chinese text legible, UI anatomically plausible, professionally aligned, generous margins. This is a concept mockup, no claimed official iOS27 features, no watermarks.

## 图二提示词

Use case: ui-mockup
Create second matching board for premium iOS Liquid Glass task app, landscape, three large equal full-height front-on iPhone screen mockups in thin black frames, all completely visible. White presentation background, heading "任务管理 · 拆解、推进与整理". Step labels "04 任务详情", "05 量化进度", "06 新建清单". Simplified Chinese crisp readable SF-like typography, pale cool gray system background, white opaque grouped rows, blue accent. Liquid Glass concept limited to navigation and action surfaces: visibly translucent soft blur, fine refractive edge highlights, floating capsule actions. No glass over content, no wallpaper, no exaggerated futuristic glow. Centered small navigation titles, no repeated giant page titles. This is conceptual visual design.
Screen1 top glass back arrow, centered "任务详情", glass ellipsis. Content task title "准备产品评审", red flag chip "高", blue chip "工作", small date "10月5日 09:00—14:00". White remark group "备注" and "整理本周需求与交互原型". Section "子任务 · 1/3", three rows with completion circles: checked "整理需求", unchecked "完成交互原型", unchecked "准备演示材料". Fine blue progress line, plus blue text row "添加子任务". At bottom large native glass blue capsule button "标记完成", secondary small neutral glass capsule "归档". No unnecessary explanatory copy.
Screen2 glass back, centered "任务详情", glass ellipsis. Task title "阅读设计书", purple book badge "学习", small "10月5日—10月10日". Main white progress area prominent "12 / 20 页", slim blue progress bar, small "60%". Below progress control with round minus glass button, middle "每次 1 页", blue round glass plus button. Grouped property rows "总量" value "20 页", "步长" value "1 页", "优先级" value "中". Bottom floating blue glass capsule "记录进度". No timer, no notification features, no charts.
Screen3 glass back, centered small "新建清单", glass blue "保存". Top centered real-time preview: orange rounded circle with white house SF-style symbol, below "生活", small "日常安排". Floating-label input fields "清单名称" value "生活", "备注" value "日常安排". Section heading "颜色". EXACTLY 18 circular color selector entries in a strict 6 columns x 3 rows grid: 17 common color circles, final bottom-right circle is native multicolor color-wheel picker. Orange circle has selected check. No separate custom color text row. Then heading "图标" with compact 6 columns x 2 rows SF-style icons covering checklist, target, calendar, book, briefcase, house, cart, heart, bicycle, airplane, leaf, star; house selected on subtle orange background. Spacious and aligned. Entire form fits phone without cutting bottom. Avoid tutorial text, duplicate headings, excessive decoration, watermarks.
Match first board in density and finish.
