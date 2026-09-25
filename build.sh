#!/bin/bash
# 构建 AI Dock.app（需要 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"
# 翻译表里有重复的键会让 App 在非中文界面下直接崩溃，构建前先检查
dups=$(grep -oE '^        "[^"]+":' Sources/AIDock/Translations.swift | sort | uniq -d)
if [ -n "$dups" ]; then echo "❌ Translations.swift 有重复的键：$dups"; exit 1; fi
swift build -c release --build-system native
APP="build/AI Dock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIDock "$APP/Contents/MacOS/AIDock"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 官方品牌标志（由 scripts/make_logos.swift 从本机已安装的 App 中提取）
[ -d Resources/Logos ] && cp -R Resources/Logos "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "✅ 已生成: $APP"
