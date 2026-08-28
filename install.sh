#!/bin/bash
set -euo pipefail

APP_NAME="VoiceTap"
cd "$(dirname "$0")"

SRC=".release/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

if [ ! -d "${SRC}" ]; then
    echo "❌ 找不到 ${SRC}，先跑 ./build.sh"
    exit 1
fi

# 先停掉正在运行的实例。只按进程路径精确匹配自己这一个 app，
# 不用 pkill 的宽泛名字模式 —— 那会牵连无关进程。
RUNNING_PID="$(pgrep -f "/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" || true)"
if [ -n "${RUNNING_PID}" ]; then
    echo "==> 停止运行中的 ${APP_NAME} (PID ${RUNNING_PID})"
    ps -p "${RUNNING_PID}" -o pid,comm,args | sed 's/^/    /'
    kill "${RUNNING_PID}"
    sleep 1
fi

# cp -R 到已存在的目录是「拷进去」不是「替换」，会套娃。必须先删。
echo "==> 安装到 ${DEST}"
rm -rf "${DEST}"
cp -R "${SRC}" "${DEST}"

echo "==> 启动"
open "${DEST}"

echo ""
echo "✅ 已安装并启动。状态栏应出现耳机图标。"
