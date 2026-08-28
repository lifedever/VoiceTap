#!/bin/bash
set -euo pipefail

APP_NAME="VoiceTap"
BUNDLE_ID="com.lifedever.VoiceTap"

cd "$(dirname "$0")"

# 版本号只认 VERSION 文件这一个源，release.sh 读的是同一个。
# 各写一份迟早漂移，出现「界面显示 A、更新检查说 B」这种自相矛盾。
VERSION="$(tr -d '[:space:]' < VERSION)"

BUILD_DIR=".release"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

# 开头就把所有中间产物清干净。
# 脚本随时可能被打断，只靠末尾清理会残留暂存目录 —— 下一次 cp -R 到已存在的
# 目标就变成「拷进去」而不是「替换」，打出旧代码 + 新版本号的包。
rm -rf "${BUILD_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

echo "==> 编译 release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> 组装 .app"
rm -rf "${CONTENTS}/MacOS/${APP_NAME}"
cp "${BIN_PATH}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"

# SwiftPM 会为每个带资源的 target 生成 {Package}_{Target}.bundle。
# 必须 glob 拷贝全部 —— 硬编码单个 bundle 名的话，将来新加一个 SPM 依赖
# 就会漏拷，那个依赖的 Bundle.module 在运行时直接 SIGTRAP。
for bundle in "${BIN_PATH}"/*.bundle; do
    [ -d "${bundle}" ] || continue
    name="$(basename "${bundle}")"
    rm -rf "${CONTENTS}/Resources/${name}"
    cp -R "${bundle}" "${CONTENTS}/Resources/"
    echo "    资源 bundle: ${name}"
done

echo "==> 拷贝 App 图标"
if [ -f "icons/icon.icns" ]; then
    cp "icons/icon.icns" "${CONTENTS}/Resources/AppIcon.icns"
    echo "    AppIcon.icns"
else
    echo "    ⚠ icons/icon.icns 不存在，先跑图标生成脚本"
fi

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 lifedever</string>
    <!-- 默认不占 Dock；打开窗口时代码里临时切到 .regular 显示图标 -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "==> 签名"
# ad-hoc 签名。注意：TCC 权限是跟 cdhash 绑的，每次重新构建 hash 都会变，
# 「输入监控 / 辅助功能」授权可能需要重新给一次。
codesign --force --deep --sign - "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

echo ""
echo "✅ 打包完成: ${APP_BUNDLE}"
echo "   安装: ./install.sh"
