#!/bin/zsh
set -euo pipefail
# 从脚本目录定位工程；参数：无；返回：测试退出码；构建产物只写临时目录。
PROJECT_ROOT="${0:A:h:h}"
BUILD_DIR="$(mktemp -d /tmp/pa-ios-tests.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$PROJECT_ROOT/PersonalAssistant/Core/Models.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/CategoryCatalog.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AccountIconBackground.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AmountKeypad.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AccountKind.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AccountProvider.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AccountPresentation.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/AccountTransactionPeriod.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/LoanDetailPresentation.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/ScreenshotBookkeeping.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/TextBookkeeping.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/TaskBrowsing.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/FinanceLocalStore.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/FinanceLocalLedger.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/FinanceLocalQuery.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/FinanceSync.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/APIClient.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/HealthData.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/NutritionData.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/HealthReader.swift" \
  "$PROJECT_ROOT/Tests/AccountProviderTests.swift" \
  "$PROJECT_ROOT/Tests/AccountIconBackgroundTests.swift" \
  "$PROJECT_ROOT/Tests/AccountPresentationTests.swift" \
  "$PROJECT_ROOT/Tests/AccountTransactionPeriodTests.swift" \
  "$PROJECT_ROOT/Tests/ScreenshotBookkeepingTests.swift" \
  "$PROJECT_ROOT/Tests/TextBookkeepingTests.swift" \
  "$PROJECT_ROOT/Tests/TaskBrowsingTests.swift" \
  "$PROJECT_ROOT/Tests/FinanceOfflineTests.swift" \
  "$PROJECT_ROOT/Tests/CoreTests.swift" -o "$BUILD_DIR/core-tests"
cp "$PROJECT_ROOT/PersonalAssistant/Resources/AccountKinds.json" "$BUILD_DIR/AccountKinds.json"
cp "$PROJECT_ROOT/PersonalAssistant/Resources/AccountProviders.json" "$BUILD_DIR/AccountProviders.json"
"$BUILD_DIR/core-tests"

# 独立验证分类目录兼容性及系统图标可用性；失败时返回非零退出码。
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$PROJECT_ROOT/PersonalAssistant/Core/Models.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/CategoryCatalog.swift" \
  "$PROJECT_ROOT/Tests/CategoryCatalogTests.swift" -o "$BUILD_DIR/category-tests"
"$BUILD_DIR/category-tests"

# 卡面搜索解析独立验证，不联网、不使用真实账户或卡号。
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 \
  "$PROJECT_ROOT/PersonalAssistant/Core/CardArtwork.swift" \
  "$PROJECT_ROOT/Tests/CardArtworkTests.swift" -o "$BUILD_DIR/card-artwork-tests"
"$BUILD_DIR/card-artwork-tests"

# 卡号分组独立验证，使用虚构号码且不联网。
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 \
  "$PROJECT_ROOT/PersonalAssistant/Core/CardNumberFormat.swift" \
  "$PROJECT_ROOT/Tests/CardNumberFormatTests.swift" -o "$BUILD_DIR/card-number-tests"
"$BUILD_DIR/card-number-tests"

# 财务分析独立验证；纯汇总计算，不读取真实账本或网络。
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 \
  -D FINANCE_ANALYSIS_TEST_MAIN \
  "$PROJECT_ROOT/PersonalAssistant/Core/Models.swift" \
  "$PROJECT_ROOT/PersonalAssistant/Core/FinanceAnalysis.swift" \
  "$PROJECT_ROOT/Tests/FinanceAnalysisTests.swift" -o "$BUILD_DIR/finance-analysis-tests"
"$BUILD_DIR/finance-analysis-tests"

# 饮食估算独立验证；覆盖目标比较、份量换算、校验及协议，不使用照片或AI。
xcrun swiftc -module-cache-path "$BUILD_DIR/module-cache" -parse-as-library -swift-version 5 \
  "$PROJECT_ROOT/PersonalAssistant/Core/NutritionData.swift" \
  "$PROJECT_ROOT/Tests/NutritionTests.swift" -o "$BUILD_DIR/nutrition-tests"
"$BUILD_DIR/nutrition-tests"
