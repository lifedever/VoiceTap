#!/bin/bash
set -euo pipefail

# 建一张本地代码签名证书，让开发构建的 TCC 授权能跨构建保留。
#
# 为什么需要它（实测对比）：
#
#   ad-hoc   designated => cdhash H"46eb1e…" or cdhash H"994429…"
#   本证书   designated => identifier "VoiceTap" and certificate leaf = H"c7b76b…"
#
# TCC 记的就是这个 Designated Requirement。ad-hoc 的 DR 里是 cdhash，每次编译都变，
# 于是每重装一次「输入监控 / 辅助功能」的勾就全部失效——而失效的表现是**静默的**：
# 按线控毫无反应也不报错，极容易被一路误判成代码 bug（这个项目已经踩过一整轮）。
# 换成固定证书后 DR 落在证书哈希上，只要证书不换，重新构建授权就一直有效。
#
# 这张证书只在本机自签自用，不参与分发；正式发版仍该用 Developer ID。

CERT_NAME="VoiceTap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 注意不能加 -v：那是「只列受信任的」，而自签名证书永远不受信任
# （会标成 CSSMERR_TP_NOT_TRUSTED）。codesign 本身不要求证书受信任，
# 所以这里也不去 add-trusted-cert —— 那一步只会多弹一次密码框。
if security find-identity -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "✅ 证书已存在，无需重建：$CERT_NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 固定用系统自带的 openssl，不看 PATH 里排在前面的是谁。
# Homebrew 的 OpenSSL 3 默认拿 AES-256 + SHA-256 打包 PKCS12，而 macOS 的
# Security framework 只认老算法，导入时会报 "MAC verification failed
# (wrong password?)" —— 一条彻底误导人的错误信息，密码其实是对的。
OPENSSL=/usr/bin/openssl

echo "==> 生成自签名证书"
cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = $CERT_NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
# codeSigning 这条 EKU 是必须的，缺了 codesign 认不出这张证书
extendedKeyUsage = critical,codeSigning
CONF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.conf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# p12 必须带非空密码：security import 处理空密码时会报和上面一样的
# "MAC verification failed"，同样是误导。这个密码只用于把证书搬进钥匙串，
# 随机生成、随临时目录一起销毁，不是任何需要记住的东西。
P12_PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" 2>/dev/null

echo "==> 导入登录钥匙串"
# -T /usr/bin/codesign 把 codesign 加进私钥的 ACL，否则每次签名都要点一次
# 「允许访问钥匙串」。实测加了这条就不再弹框，不需要 set-key-partition-list。
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo ""
echo "✅ 证书已就绪：$CERT_NAME"
echo "   build.sh 会自动认出它并用它签名。"
echo ""
echo "⚠️  换签名方式本身会让现有授权失效一次（DR 从 cdhash 变成证书）。"
echo "   下次 ./install.sh 之后去系统设置把「输入监控」重新勾一次——"
echo "   这是最后一次，之后重新构建都不会再掉。"
echo ""
echo "   万一签名时弹出「允许访问钥匙串」，点「始终允许」即可。"
