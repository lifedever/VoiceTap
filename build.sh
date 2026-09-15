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

# 用**当前工具链的 SDK** 构建，同时保持 Package.swift 里声明的最低系统版本。
#
# SwiftPM 默认把 LC_BUILD_VERSION 的 sdk 字段也写成 deployment target
# （minos 14.0 → sdk 也记 14.0）。而系统判断「这 app 是用哪代 SDK 编的」看的
# 就是这个字段：macOS 26 起的窗口外观（toolbar 那层玻璃，见约束 8）按它分档，
# 记成 14.0 等于自称老 app，新外观一律拿不到。
#
# 两个版本号都现问，不写死：deployment target 的唯一事实源是 Package.swift，
# SDK 跟着装的那套 Xcode 走。
MIN_MACOS="$(swift package dump-package | python3 -c '
import json, sys
v = [p["version"] for p in json.load(sys.stdin).get("platforms", []) if p["platformName"] == "macos"]
print(v[0] if v else "")
')"
[ -n "${MIN_MACOS}" ] || { echo "❌ 读不到 Package.swift 里的 macOS deployment target"; exit 1; }
SDK_VER="$(xcrun --show-sdk-version)"
# 必须传完整三元组：单独给 -sdk_version 会被 SwiftPM 自己那份 -platform_version 盖掉
LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "${MIN_MACOS}" -Xlinker "${SDK_VER}")

echo "==> 编译 release（最低 macOS ${MIN_MACOS}，SDK ${SDK_VER}）"
swift build -c release "${LINK_FLAGS[@]}"
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> 组装 .app"
rm -rf "${CONTENTS}/MacOS/${APP_NAME}"
cp "${BIN_PATH}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"

# 回读确认两个版本号都落对了。写错是静默的：sdk 记小了拿不到新外观，
# minos 记大了低版本系统上直接起不来，而本机永远复现不出来。
ACTUAL="$(vtool -show-build-version "${CONTENTS}/MacOS/${APP_NAME}" | awk '/minos/{m=$2} /sdk/{s=$2} END{print m" "s}')"
[ "${ACTUAL}" = "${MIN_MACOS} ${SDK_VER}" ] || {
    echo "❌ 二进制的 minos/sdk 是「${ACTUAL}」，应为「${MIN_MACOS} ${SDK_VER}」"
    exit 1
}

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
    <key>LSMinimumSystemVersion</key>    <string>${MIN_MACOS}</string>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 lifedever</string>
    <!-- 默认不占 Dock；打开窗口时代码里临时切到 .regular 显示图标 -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

echo "==> 签名"
# 优先用本机那张固定的代码签名证书（scripts/create-signing-cert.sh 创建）。
#
# 差别不是"更正规"，而是 TCC 授权保不保得住：ad-hoc 签名的 Designated Requirement
# 里带 cdhash，每次编译都变，于是每重装一次「输入监控 / 辅助功能」的勾就全掉。
# 而掉授权的表现是**静默的** —— 按线控毫无反应也不报错，会被一路误判成代码 bug。
# 用固定证书签名后 DR 变成 certificate leaf，重新构建不再影响授权。
# 查找不能加 -v：那是「只列受信任的」，自签名证书永远不在其中
# （标成 CSSMERR_TP_NOT_TRUSTED）。codesign 不要求证书受信任，照样签得动。
CERT_NAME="VoiceTap Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -qF "${CERT_NAME}"; then
    SIGN_ID="${CERT_NAME}"
    echo "    证书: ${CERT_NAME}"
else
    SIGN_ID="-"
    echo "    ⚠ 未找到本地签名证书，退回 ad-hoc —— 每次重装都要重给权限"
    echo "      跑一次 ./scripts/create-signing-cert.sh 可以根治"
fi
codesign --force --deep --sign "${SIGN_ID}" "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

echo ""
echo "✅ 打包完成: ${APP_BUNDLE}"
echo "   安装: ./install.sh"
