#!/bin/bash
# 构建 AI Dock.app（通用二进制 arm64 + x86_64，仅需 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"
# 翻译表里有重复的键会让 App 在非中文界面下直接崩溃，构建前先检查
dups=$(grep -oE '^        "[^"]+":' Sources/AIDock/Translations.swift | sort | uniq -d || true)
if [ -n "$dups" ]; then echo "❌ Translations.swift 有重复的键：$dups"; exit 1; fi

ARCHS=(${AIDOCK_ARCHS:-arm64 x86_64})
BINS=()
for arch in "${ARCHS[@]}"; do
    triple="${arch}-apple-macosx14.0"
    swift build -c release --build-system native --triple "$triple"
    BINS+=("$(swift build -c release --build-system native --triple "$triple" --show-bin-path)/AIDock")
done

# AIDOCK_OUT 可以改输出目录（例如 build.noindex，不让聚焦收录这份副本）
APP="${AIDOCK_OUT:-build}/AI Dock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINS[@]}" -eq 1 ]; then
    cp "${BINS[0]}" "$APP/Contents/MacOS/AIDock"
else
    lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/AIDock"
fi
chmod 755 "$APP/Contents/MacOS/AIDock"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 官方品牌标志（由 scripts/make_logos.swift 从本机已安装的 App 中提取）
[ -d Resources/Logos ] && cp -R Resources/Logos "$APP/Contents/Resources/"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "✅ 已生成: $APP ($(lipo -archs "$APP/Contents/MacOS/AIDock"))"
