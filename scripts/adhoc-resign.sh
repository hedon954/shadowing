#!/usr/bin/env bash
# 对本地不签名构建的 Shadowing.app 做完整 ad-hoc 重签并校验。
#
# 不签名构建只有链接器生成的 ad-hoc 签名（linker-signed）：Info.plist 未绑定、资源未封存、
# 没有指定要求（designated requirement）。TCC 无法匹配这样的应用（连它自己都匹配不上），
# 麦克风授权每次都会重新询问。完整 ad-hoc 重签后授权会一直有效，直到下一次重新构建
# （cdhash 变化）。
#
# 用法：./scripts/adhoc-resign.sh path/to/Shadowing.app
set -euo pipefail

app_path="${1:?用法: $0 path/to/Shadowing.app}"
if [[ ! -d "$app_path" ]]; then
  echo "✗ 未找到 $app_path" >&2
  exit 1
fi

codesign --force --deep --sign - "$app_path"
codesign --verify --strict "$app_path"

bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
details="$(codesign -dv "$app_path" 2>&1)"
if ! grep -qx "Identifier=$bundle_id" <<<"$details"; then
  echo "✗ 签名标识不是 $bundle_id：" >&2
  echo "$details" >&2
  exit 1
fi
if grep -q "linker-signed" <<<"$details"; then
  echo "✗ 仍是链接器签名（linker-signed）：" >&2
  echo "$details" >&2
  exit 1
fi
echo "   ✓ ad-hoc 重签: $(codesign -d -r- "$app_path" 2>&1 | sed -n "s/^# designated => //p")"
