#!/bin/bash
set -euo pipefail
# 独立执行纯 Foundation 健康资料测试；参数：无；返回值：测试进程退出码；仅在可写 TMPDIR 创建脚本和模块缓存，不依赖项目其他测试或 HealthKit。
: "${TMPDIR:?需要可写的 TMPDIR}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "$TMPDIR/pa-health-profile.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# swift 解释器只将第一个文件作为入口，因此合并纯模型与测试到临时入口，所有模块缓存也保留在临时目录。
cat "$PROJECT_ROOT/PersonalAssistant/Core/HealthProfile.swift" "$PROJECT_ROOT/Tests/HealthProfileTests.swift" > "$BUILD_DIR/main.swift"
SWIFT_EXECUTABLE="${SWIFT_EXECUTABLE:-$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"
"$SWIFT_EXECUTABLE" -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" "$BUILD_DIR/main.swift"
