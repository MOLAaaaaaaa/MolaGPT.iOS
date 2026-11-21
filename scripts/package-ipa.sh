#!/usr/bin/env bash
# 打包自签用 IPA：release 构建 → IPA 根目录加 iTunesArtwork（部分签名软件从这里取图标）→ 复制到 dist/
# 最后检查两个扩展没有被死代码剔空（应包含各自的入口类）。
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.local/share/swiftly/env.sh
mkdir -p .build dist
LOG=.build/xtool-release.log
if ! xtool dev build -c release --ipa > "$LOG" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "^/.*error: |^Error" | sort -u | head -20
  exit 1
fi
IPA=xtool/MolaGPT.ipa
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp Resources/Icons/iTunesArtwork.png "$TMP/iTunesArtwork"
(cd "$TMP" && zip -q -0 "$OLDPWD/$IPA" iTunesArtwork)
VER=$(python3 -c "import plistlib;print(plistlib.load(open('Resources/Info.plist','rb'))['CFBundleShortVersionString'])")
OUT=dist/MolaGPT-$VER.ipa
cp "$IPA" "$OUT"
# 自检
unzip -q -o "$IPA" -d "$TMP/x" 'Payload/*'
A="$TMP/x/Payload/MolaGPT.app"
for f in AppIcon60x60@2x.png AppIcon60x60@3x.png; do [ -f "$A/$f" ] || { echo "缺少图标 $f"; exit 1; }; done
LC_ALL=C grep -aq MolaShareViewController "$A/PlugIns/MolaShare.appex/MolaShare" || { echo "分享扩展被剔空"; exit 1; }
LC_ALL=C grep -aq MolaWidgetBundle "$A/PlugIns/MolaWidgets.appex/MolaWidgets" || { echo "实时活动扩展被剔空"; exit 1; }
echo "OK $OUT $(du -h "$OUT" | cut -f1) sha256:$(sha256sum "$OUT" | cut -c1-16)"
