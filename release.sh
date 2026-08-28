#!/bin/bash
set -euo pipefail

# 构建 VoiceTap.app 并打成 DMG（arm64 / x86_64 各一个包）。
#
# ⚠️ DMG 命名是**契约**：UpdateChecker 按 `名字里含架构 && 以 .dmg 结尾` 查找资产。
#    改了命名规则 = 所有已装用户的自动更新静默失效（找不到资产会降级到发布页）。

APP_NAME="VoiceTap"
BUNDLE_ID="com.lifedever.VoiceTap"

cd "$(dirname "$0")"
ROOT="$(pwd)"

# 版本号单一事实源。不在脚本里另写一份——两个源迟早漂移，
# 出现「界面显示 A、更新检查说 B」这种自相矛盾。
VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "${VERSION}" ] || { echo "❌ VERSION 文件为空"; exit 1; }

BUILD_DIR="build"
ARCHS=(arm64 x86_64)

# 开头就把所有中间产物清干净。脚本随时可能被打断，只靠末尾清理会残留暂存目录
# —— 下一次 cp -R 到已存在的目标就变成「拷进去」而不是「替换」，
# 打出旧代码 + 新版本号的包（PasteMemo v1.7.12-beta.6 事故）。
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

if [ ! -f "icons/icon.icns" ]; then
    echo "❌ icons/icon.icns 不存在，先生成图标"
    exit 1
fi

echo "==> 发布 ${APP_NAME} ${VERSION}"

build_one() {
    local arch="$1"
    local app="${BUILD_DIR}/${arch}/${APP_NAME}.app"
    local dmg="${BUILD_DIR}/${APP_NAME}-${VERSION}-${arch}.dmg"
    local stage="${BUILD_DIR}/dmg-${arch}"

    echo "==> [${arch}] 编译"
    swift build -c release --arch "${arch}"
    # 单架构构建的产物在 .build/<triple>/release；.build/release 只是指向
    # 「最近一次构建」的符号链接，连续构建两个架构时它会来回切，不能用
    local bin_dir="${ROOT}/.build/${arch}-apple-macosx/release"

    echo "==> [${arch}] 组装 bundle"
    rm -rf "${app}"
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
    cp "${bin_dir}/${APP_NAME}" "${app}/Contents/MacOS/${APP_NAME}"
    cp "icons/icon.icns" "${app}/Contents/Resources/AppIcon.icns"

    # SPM 的 .process 资源会生成 {Package}_{Target}.bundle。必须 glob 而不是
    # 写死名字：漏拷一个就是运行时 Bundle.module 直接 SIGTRAP，
    # 而且崩溃点离这里很远（PasteMemo issue #34 / #38）。
    shopt -s nullglob
    for bundle in "${bin_dir}"/*.bundle; do
        [ -d "${bundle}" ] && cp -R "${bundle}" "${app}/Contents/Resources/"
    done
    shopt -u nullglob

    cat > "${app}/Contents/Info.plist" <<PLIST
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
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

    codesign --force --deep --sign - "${app}"
    codesign --verify --strict "${app}" && echo "    [${arch}] 签名校验通过"

    echo "==> [${arch}] 打包 DMG"
    rm -rf "${stage}"
    mkdir -p "${stage}"
    cp -R "${app}" "${stage}/${APP_NAME}.app"
    ln -s /Applications "${stage}/Applications"
    hdiutil create -volname "${APP_NAME} ${VERSION}" \
        -srcfolder "${stage}" -ov -format UDZO -quiet "${dmg}"
    rm -rf "${stage}"
}

for arch in "${ARCHS[@]}"; do
    build_one "${arch}"
done

echo ""
echo "==> 验包"
# 「dev 上验证过」≠「DMG 里是对的」。挂载真包核对内容，
# 防止嵌套 .app、漏拷资源这类打包事故发出去。
for arch in "${ARCHS[@]}"; do
    dmg="${BUILD_DIR}/${APP_NAME}-${VERSION}-${arch}.dmg"
    mount_point="$(hdiutil attach "${dmg}" -nobrowse -noverify | grep -o '/Volumes/.*' | head -1)"
    inner="${mount_point}/${APP_NAME}.app"

    # 嵌套 .app 是残留暂存目录导致的典型事故，体积会接近翻倍
    nested="$(find "${inner}" -name "*.app" -mindepth 1 | wc -l | tr -d ' ')"
    plist_version="$(defaults read "${inner}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"

    hdiutil detach "${mount_point}" -quiet

    if [ "${nested}" != "0" ]; then
        echo "❌ [${arch}] 包内发现嵌套 .app，打包有误"
        exit 1
    fi
    if [ "${plist_version}" != "${VERSION}" ]; then
        echo "❌ [${arch}] 包内版本号是 ${plist_version}，与 ${VERSION} 不符"
        exit 1
    fi
    echo "    [${arch}] 版本 ${plist_version}，无嵌套 .app，$(du -h "${dmg}" | cut -f1)"
done

echo ""
echo "✅ 完成"
for arch in "${ARCHS[@]}"; do
    echo "   ${BUILD_DIR}/${APP_NAME}-${VERSION}-${arch}.dmg"
done
echo ""
echo "发布："
echo "   git tag v${VERSION} && git push origin v${VERSION}"
echo "   gh release create v${VERSION} ${BUILD_DIR}/${APP_NAME}-${VERSION}-*.dmg --title \"${APP_NAME} ${VERSION}\""
