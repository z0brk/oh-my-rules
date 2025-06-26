#!/bin/bash
# 广告拦截规则助手
# 从上游广告列表（默认 anti-AD）同步 WPS/金山系域名到 ads.list 的自动区。
# 手动区条目优先：自动区会剔除手动区已有的域名。
#
# 用法:
#   ./ads-helper.sh            同步并更新 ads.list
#   ./ads-helper.sh --check    仅预览差异，不写文件

set -e
cd "$(dirname "$0")"

LIST=ads.list
UPSTREAM_URL="${ADS_UPSTREAM:-https://anti-ad.net/domains.txt}"

# 只认金山/WPS 系后缀，避免把名字里碰巧含 wps 的无关域名捞进来
WPS_SUFFIX='(^|[.-])(wps\.cn|wps\.com|wps\.ai|wpscdn\.cn|wpscdn\.com|kingsoft\.com|kingsoft-office-service\.com|wpserveur\.net|wpshsdk\.com|metricswpsh\.com|docer\.com|kdocs\.cn|ksosoft\.com)$'
# 这些根域名本身就是广告/统计设施，按 DOMAIN-SUFFIX 收录以覆盖子域
ROOT_AS_SUFFIX='^(metricswpsh\.com|wpshsdk\.com)$'

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

if [ ! -f "$LIST" ]; then
  echo "错误：找不到 $LIST" >&2
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "👉 拉取上游列表: $UPSTREAM_URL"
curl -fsSL --max-time 60 "$UPSTREAM_URL" >| "$TMP"

# 手动区已有域名（取路由规则最后一个字段）
manual=$(sed -n '/^# ===== 自动区结束/,$p' "$LIST" | grep -Ev '^#|^[[:space:]]*$' | awk -F, '{print $NF}' | sort -u)

# 上游过滤：仅保留金山/WPS 系后缀，去掉手动区已有项
auto=$(grep -E "$WPS_SUFFIX" "$TMP" | grep -v '^#' | sort -u)
if [ -n "$manual" ]; then
  auto=$(comm -23 <(printf '%s\n' "$auto") <(printf '%s\n' "$manual"))
fi

if [ -z "$auto" ]; then
  echo "⚠️  上游没有匹配到 WPS/金山域名，跳过更新"
  exit 0
fi

new_block=$(printf '%s\n' "$auto" | awk '$0 ~ re { print "DOMAIN-SUFFIX," $0; next } { print "DOMAIN," $0 }' re="$ROOT_AS_SUFFIX")

if [ "$CHECK" = 1 ]; then
  old_block=$(sed -n '/^# ===== 自动区开始/,/^# ===== 自动区结束/p' "$LIST" | grep -Ev '^#|^[[:space:]]*$')
  echo "👉 差异预览（< 旧条目，> 新条目）:"
  diff <(printf '%s\n' "$old_block") <(printf '%s\n' "$new_block") || true
  exit 0
fi

export NEW_BLOCK="$new_block"
awk '
  /^# ===== 自动区开始/ { print; printf "%s\n", ENVIRON["NEW_BLOCK"]; skip=1; next }
  /^# ===== 自动区结束/ { skip=0 }
  !skip { print }
' "$LIST" >| "$LIST.tmp" && mv "$LIST.tmp" "$LIST"

echo "✅ 已同步 $(printf '%s\n' "$auto" | wc -l | tr -d ' ') 条到 $LIST 自动区"
