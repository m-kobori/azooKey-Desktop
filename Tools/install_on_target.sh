#!/bin/bash
# Kiwi を「別の Mac」にインストールするスクリプト（管理者権限・Xcode 不要）。
#
# 使い方:
#   1. ビルド元 Mac で ./Tools/local_adhoc_install.sh --package を実行し、
#      dist/Kiwi-transfer.zip を作る
#   2. zip を対象 Mac へコピー（AirDrop / USB / scp など何でも可）
#   3. 対象 Mac で: unzip Kiwi-transfer.zip && cd Kiwi-transfer && ./install_on_target.sh
#   4. ログアウト→ログイン後、システム設定 > キーボード > 入力ソース > + > 日本語 > Kiwi を追加
#
# 内容:
# - Gatekeeper の隔離属性（quarantine）を除去（sudo 不要）
# - ~/Library/Input Methods へ配置（ユーザー単位・sudo 不要）
# - ConverterServer の LaunchAgent を ~/Library/LaunchAgents に登録（sudo 不要）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="${SCRIPT_DIR}/azooKeyMac.app"
INSTALL_APP_PATH="${HOME}/Library/Input Methods/azooKeyMac.app"
SERVICE_NAME="dev.ensan.inputmethod.azooKeyMac.ConverterServer"
AGENT_PATH="${HOME}/Library/LaunchAgents/${SERVICE_NAME}.plist"
GUI_DOMAIN="gui/$(id -u)"

[ -d "${APP_SRC}" ] || { echo "azooKeyMac.app が見つかりません（zip を展開したフォルダで実行してください）" >&2; exit 1; }

echo "==> Gatekeeper 隔離属性を除去..."
xattr -dr com.apple.quarantine "${APP_SRC}" 2>/dev/null || true

echo "==> ~/Library/Input Methods/ へインストール（sudo 不要）..."
if [ -d "/Library/Input Methods/azooKeyMac.app" ]; then
    echo "⚠️  /Library/Input Methods/azooKeyMac.app（システム側）も存在します。"
    echo "    二重登録を避けるため、可能なら管理者権限で削除してください:"
    echo "    sudo rm -rf '/Library/Input Methods/azooKeyMac.app'"
fi
rm -rf "${INSTALL_APP_PATH}"
mkdir -p "$(dirname "${INSTALL_APP_PATH}")"
ditto "${APP_SRC}" "${INSTALL_APP_PATH}"

echo "==> ConverterServer をアプリ外に配置（辞書バンドル解決のため）..."
# SwiftPM の実行ファイルはリソースバンドルを実行ファイルの隣（Bundle.main.bundleURL 直下）
# でしか探せないため、アプリ内から起動すると辞書が見つからず crash-loop する。
# サーバを Application Support 配下に置き、バンドル等をシンボリックリンクで並べる。
SUPPORT_DIR="${HOME}/Library/Application Support/Kiwi"
rm -rf "${SUPPORT_DIR}/server"
mkdir -p "${SUPPORT_DIR}/server"
cp "${INSTALL_APP_PATH}/Contents/MacOS/ConverterServer" "${SUPPORT_DIR}/server/"
for bundle in "${INSTALL_APP_PATH}/Contents/Resources/"*.bundle; do
    ln -sfn "${bundle}" "${SUPPORT_DIR}/server/$(basename "${bundle}")"
done
rm -f "${SUPPORT_DIR}/Frameworks" "${SUPPORT_DIR}/Resources"
ln -s "${INSTALL_APP_PATH}/Contents/Frameworks" "${SUPPORT_DIR}/Frameworks"
ln -s "${INSTALL_APP_PATH}/Contents/Resources" "${SUPPORT_DIR}/Resources"

echo "==> ConverterServer の LaunchAgent を登録..."
SERVER_PATH="${SUPPORT_DIR}/server/ConverterServer"
mkdir -p "$(dirname "${AGENT_PATH}")"
cat > "${AGENT_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SERVER_PATH}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${SERVICE_NAME}</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${SERVICE_NAME}.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${SERVICE_NAME}.stderr.log</string>
</dict>
</plist>
PLIST

launchctl bootout "${GUI_DOMAIN}" "${AGENT_PATH}" >/dev/null 2>&1 || true
launchctl bootstrap "${GUI_DOMAIN}" "${AGENT_PATH}"
launchctl kickstart -k "${GUI_DOMAIN}/${SERVICE_NAME}"
pkill azooKeyMac 2>/dev/null || true

echo ""
echo "✅ 完了: ${INSTALL_APP_PATH}"
echo "次: ログアウト→ログイン後、システム設定 > キーボード > 入力ソース > + > 日本語 > Kiwi を追加"
