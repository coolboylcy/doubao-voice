#!/usr/bin/env bash
# 生成可以发给别人的 DMG：Developer ID 签名 + Apple 公证 + 装订。
#
# 跟 make-dmg.sh 的区别在于「给谁用」。make-dmg.sh 出的是 Apple Development
# 签名的本机测试镜像，别人下载后会被 Gatekeeper 拦在门外（「无法验证开发者」）。
# 这个脚本出的镜像，任何人双击就能装。
#
# 前置条件见 README 的「发布」一节，缺什么这里都会指名道姓地报。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

VERSION="${VERSION:-0.2.0}"
APP="dist/Doubao Voice.app"
DMG="dist/Doubao Voice ${VERSION}.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-doubao-voice}"

# ---- 前置检查 ----

echo "==> 检查 Developer ID 证书"
SIGN_ID="${DEVELOPER_ID_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application:/ {print $2; exit}'
)}"
if [[ -z "$SIGN_ID" ]]; then
  cat >&2 <<'MSG'
找不到 Developer ID Application 证书。

这是 App Store 之外分发给他人的专用证书，跟 Apple Development（本机调试）
和 Apple Distribution（提交商店）都不是一回事，必须单独创建：

  1. 打开 Xcode → Settings → Accounts，选中你的 Apple ID 和团队
  2. 点 Manage Certificates… → 左下角 + → Developer ID Application
  3. 创建完成后证书会自动进入钥匙串

需要付费的 Apple Developer Program 账号（你已有），创建本身免费、几分钟完成。
MSG
  exit 1
fi
echo "    $SIGN_ID"

echo "==> 检查公证凭据"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<MSG
钥匙串里没有名为 "$NOTARY_PROFILE" 的公证凭据。

公证要用 App 专用密码（不是你的 Apple ID 登录密码）：

  1. 去 https://account.apple.com → 登录 → App 专用密码 → 生成一个
  2. 执行下面这条，按提示粘贴：

       xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
         --apple-id "<你的 Apple ID 邮箱>" \\
         --team-id "$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]*\)).*/\1/p' | head -1)" \\
         --password "<刚生成的 App 专用密码>"

  密码存进钥匙串，只需配置一次。
MSG
  exit 1
fi
echo "    凭据 $NOTARY_PROFILE 可用"

test -d "$APP" || { echo "缺少 $APP，请先运行 scripts/build-macos-app.sh" >&2; exit 1; }

# ---- 重新签名 ----
#
# 从内往外签，顺序不能乱：macOS 的签名是嵌套的，先签外层再改内层会让外层失效。
echo "==> 用 Developer ID 重新签名（从内到外）"

sign() {
  local target="$1"
  local entitlements="${2:-}"
  local args=(--force --sign "$SIGN_ID" --options runtime --timestamp)
  [[ -n "$entitlements" ]] && args+=(--entitlements "$entitlements")
  codesign "${args[@]}" "$target"
}

# 先是所有内嵌的可执行文件。--timestamp 不能省：公证要求 secure timestamp，
# 本机构建默认带的是 --timestamp=none，直接拿去公证会被判不合规。
sign "$APP/Contents/Resources/funasr/bin/llama-funasr-sensevoice"
sign "$APP/Contents/Helpers/dbvoice" App/Helper.entitlements

# 任何残留的 dylib/so 也要签到
while IFS= read -r -d '' lib; do
  sign "$lib"
done < <(find "$APP" \( -name '*.dylib' -o -name '*.so' \) -type f -print0)

# 最后签 App 本体
sign "$APP" App/DoubaoVoice-local.entitlements

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
# 这一步才是关键：spctl 用分发规则评估，Apple Development 签名到这里必失败
if ! spctl -a -vv -t exec "$APP" 2>&1 | grep -q "accepted"; then
  echo "spctl 拒绝了这个 App，签名不满足分发要求" >&2
  spctl -a -vv -t exec "$APP" || true
  exit 1
fi

# ---- 打包 ----

echo "==> 生成 DMG"
APP_PATH="$APP" OUTPUT_PATH="$DMG" ./scripts/make-dmg.sh >/dev/null
sign "$DMG"

# ---- 公证 ----

echo "==> 提交公证（首次通常几分钟，期间可以去干别的）"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "公证被拒。拿 submission id 看详细原因：" >&2
  echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

echo "==> 装订公证票据"
# 装订把票据写进 DMG 本身，这样别人即使离线打开也能通过校验
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---- 最终验证 ----
#
# 前面都是「我这台机器上看着没问题」。下面这段模拟真实下载场景：给镜像打上
# 隔离属性，再用 Gatekeeper 的安装规则评估一次。这是唯一能证明「别人下下来
# 能用」的检查。
echo "==> 模拟他人下载并通过 Gatekeeper"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$DMG"
if spctl -a -vv -t install "$DMG" 2>&1 | grep -q "accepted"; then
  echo "    通过"
else
  echo "带隔离属性时 Gatekeeper 仍拒绝，别人下载后会打不开" >&2
  spctl -a -vv -t install "$DMG" || true
  exit 1
fi
xattr -d com.apple.quarantine "$DMG" 2>/dev/null || true

echo
echo "可分发镜像已就绪：$DMG"
shasum -a 256 "$DMG"
echo
echo "上传到 GitHub Release："
echo "  gh release create v${VERSION} \"$DMG\" --title \"v${VERSION}\" --notes-file <(git log -1 --pretty=%B)"
