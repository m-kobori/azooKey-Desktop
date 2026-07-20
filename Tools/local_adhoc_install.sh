#!/bin/bash
# Kiwi (azooKey-Desktop fork) をローカルで動かすための「アドホック署名」インストーラ。
#
# 背景: 本家 install.sh は Apple Developer の署名（DEVELOPMENT_TEAM / provisioning profile）を
# 前提とする。App Sandbox + App Groups を含むため、無料 Apple ID や未サインイン環境では
# 自動署名が通らない。本スクリプトは「署名なしでビルド → 全体をアドホック署名(codesign -s -)」
# することで、Apple 登録なしでもローカル実行できるようにする。
# 配布は不可（アドホック署名のため他マシンでは Gatekeeper に弾かれる）。ローカル専用。
#
# 使い方:  ./Tools/local_adhoc_install.sh
#   --skip-build   既存の build/archive.xcarchive を再利用（署名とインストールのみ）
set -euo pipefail

SKIP_BUILD=false
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BUNDLE_ID="dev.ensan.inputmethod.azooKeyMac"
ARCHIVE="build/archive.xcarchive"
APP="${ARCHIVE}/Products/Applications/azooKeyMac.app"
INSTALL_APP_PATH="/Library/Input Methods/azooKeyMac.app"
TMP_ENT="$(mktemp -d)"
trap 'rm -rf "${TMP_ENT}"' EXIT

# --- 1. 署名なしでアーカイブビルド ---
if [ "${SKIP_BUILD}" = false ]; then
    echo "==> ビルド中（署名なし。数分かかります）..."
    xcodebuild -project azooKeyMac.xcodeproj -scheme azooKeyMac clean archive \
        -archivePath "${ARCHIVE}" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""
fi

[ -d "${APP}" ] || { echo "アプリが見つかりません: ${APP}" >&2; exit 1; }

# --- 2. エンタイトルメント変数を展開 ---
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/g" \
    azooKeyMac/azooKeyMac.entitlements > "${TMP_ENT}/app.entitlements"
cp azooKeyMac/ConverterServer.entitlements "${TMP_ENT}/server.entitlements"

# アドホック署名では全バイナリが「Team ID 無し」になる。hardened runtime 下では
# Library Validation が働き、同梱の llama.framework（別署名扱い）を dyld が拒否して
# 起動時にクラッシュする（"different Team IDs"）。アプリ本体と ConverterServer は共に
# llama.framework を読み込むため、両方のエンタイトルメントで検証を無効化する必要がある。
# （ConverterServer に付け忘れると keepalive の常駐サービスが crash-loop し Mac が重くなる）
for ent in "${TMP_ENT}/app.entitlements" "${TMP_ENT}/server.entitlements"; do
    /usr/libexec/PlistBuddy -c \
        "Add :com.apple.security.cs.disable-library-validation bool true" "${ent}" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c \
        "Set :com.apple.security.cs.disable-library-validation true" "${ent}"
done

# App Sandbox と App Group を外す（ローカルビルド限定）。
# アドホック署名（Team ID 無し）では、sandbox 下で自分の App Group コンテナ
# （~/Library/Group Containers/…）を「自分の所有物」と macOS が認識できず、そこへアクセスする度に
# 「ほかのアプリのデータへのアクセス権」(kTCCServiceSystemPolicyAppData) プロンプトが出る
# （特に設定画面は起動時に全 Config 値を App Group の UserDefaults から読むため必発）。
# sandbox を外すだけでは ~/Library/Group Containers/ が保護対象のままなので不十分。App Group entitlement
# 自体を外すと:
#   - AppGroup.containerURL() が nil を返し、azooKey は学習/履歴を ~/Library/Application Support/azooKey/
#     に、Config は ~/Library/Preferences/group.dev.ensan….plist に保存する（どちらも保護対象外）。
#   - アプリ⇔ConverterServer は同一ユーザーで同じフォールバック先を使うため設定共有は維持される。
# ※ 正規署名で配布する場合はこの 2 つの Delete を無効化し、sandbox / App Group を戻すこと。
for ent in "${TMP_ENT}/app.entitlements" "${TMP_ENT}/server.entitlements"; do
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "${ent}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "${ent}" 2>/dev/null || true
done

# --- 3. 内側から個別にアドホック署名（--deep は使わない: ネストへ誤ってapp権限が伝播するため）---
echo "==> アドホック署名..."
codesign --force --sign - --timestamp=none \
    "${APP}/Contents/Frameworks/libswiftCompatibilitySpan.dylib" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
    "${APP}/Contents/Frameworks/llama.framework/Versions/A/llama" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
    "${APP}/Contents/Frameworks/llama.framework"
# ConverterServer は本来の server.entitlements（app-groups のみ）
codesign --force --sign - --entitlements "${TMP_ENT}/server.entitlements" \
    --options runtime --timestamp=none "${APP}/Contents/MacOS/ConverterServer"
# アプリ本体は app.entitlements（sandbox + app-groups + mach例外）
codesign --force --sign - --entitlements "${TMP_ENT}/app.entitlements" \
    --options runtime --timestamp=none "${APP}"
codesign --verify --deep --strict "${APP}"
echo "==> 署名OK"

# --- 4. インストール（sudo 必要）---
echo "==> /Library/Input Methods/ へインストール（sudo）..."
sudo rm -rf "${INSTALL_APP_PATH}"
sudo ditto "${APP}" "${INSTALL_APP_PATH}"

# --- 5. ConverterServer 常駐サービス登録 & 再起動 ---
"${REPO_ROOT}/Tools/install_converter_server_launch_agent.sh" "${INSTALL_APP_PATH}"
pkill azooKeyMac || true

echo ""
echo "✅ 完了: ${INSTALL_APP_PATH}"
echo "次: ログアウト→ログイン後、システム設定 > キーボード > 入力ソース > + > 日本語 > azooKey を追加"
