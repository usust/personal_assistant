#!/bin/bash
set -euo pipefail
# 验证健康空间纯逻辑；参数：无；返回值：失败非零、成功零；只在 TMPDIR 生成测试产物，不访问健康库或真实照片。
: "${TMPDIR:?需要可写的 TMPDIR}"
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "$TMPDIR/pa-health-space.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
SWIFT_COMPILER="${SWIFT_COMPILER:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc}"
bash "$IOS_ROOT/Tests/run-health-profile.sh"
"$SWIFT_COMPILER" -swift-version 5 -parse-as-library -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -module-cache-path "$TEST_BUILD/cache" \
  "$IOS_ROOT/PersonalAssistant/Core/NutritionData.swift" \
  "$IOS_ROOT/Tests/NutritionTests.swift" -o "$TEST_BUILD/nutrition"
"$TEST_BUILD/nutrition"
"$SWIFT_COMPILER" -swift-version 5 -parse-as-library -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -module-cache-path "$TEST_BUILD/cache" \
  "$IOS_ROOT/PersonalAssistant/Core/NutritionData.swift" \
  "$IOS_ROOT/PersonalAssistant/Core/NutritionEnergyState.swift" \
  "$IOS_ROOT/Tests/NutritionEnergyStateTests.swift" -o "$TEST_BUILD/energy"
"$TEST_BUILD/energy"
