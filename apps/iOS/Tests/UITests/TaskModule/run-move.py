#!/usr/bin/env python3
"""编译真实 AppStore 竞态验收；只替换传输和通知，不复制状态机。"""
import os
import pathlib
import re
import subprocess
import tempfile

# 从已有核心测试脚本复用真实依赖，避免验收和生产逻辑产生两套实现。
root = pathlib.Path(__file__).resolve().parents[3]
script = (root / "Tests/run.sh").read_text()
files = re.findall(r'"\$PROJECT_ROOT/(PersonalAssistant/Core/[^\"]+)"', script.split("cp ")[0])
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
with tempfile.TemporaryDirectory(prefix="task-race-") as folder:
    binary = pathlib.Path(folder) / "race"
    command = ["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library", "-swift-version", "5", "-module-cache-path", folder + "/cache"]
    command += [str(root / file) for file in files]
    command += [str(root / "PersonalAssistant/Core/AppStore.swift"), str(pathlib.Path(__file__).with_name("MoveHarness.swift")), "-o", str(binary)]
    subprocess.run(command, env=env, check=True)
    # --preview 使真实 AppStore 的初始化不打开本机账本或读取钥匙串。
    subprocess.run([str(binary), "--preview"], env=env, check=True)
