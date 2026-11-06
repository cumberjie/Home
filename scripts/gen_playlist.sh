#!/bin/sh
# ============================================================
# gen_playlist.sh — 从 gx.m3u 生成播放器兼容的 0 文件
#
# 规则（用户指定）：
#   1. 删除 tvg-name 中含 4K 的频道（电视播不了）
#   2. 去掉 tvg-name 属性（播放器不识别）
#   3. URL 末尾追加 "?$<画质>"，画质取自原 tvg-name 的最后一段
#      原地址已带 ?servicetype=1，所以结果是两个问号（用户明确要求字面照写）
#
# 例：
#   原：#EXTINF:-1 tvg-name="CCTV-1 超清" tvg-logo="..." group-title="央视热播",CCTV-1
#       http://cdn.example/index.m3u8?servicetype=1
#   新：#EXTINF:-1 tvg-logo="..." group-title="央视热播",CCTV-1
#       http://cdn.example/index.m3u8?servicetype=1?$超清
#
# 用法：
#   sh scripts/gen_playlist.sh [输入] [输出]
#   默认输入 iptv/gx.m3u，输出 iptv/0
# ============================================================
set -eu

# 在切换目录前解析调用者的当前目录
CALLER_PWD=$(pwd)

REPO_DIR=${REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
cd "$REPO_DIR"

IN=${1:-iptv/gx.m3u}
OUT=${2:-iptv/0.m3u}

# 相对路径按调用者当前目录解析，避免被 cd 影响
case "$IN" in
  /*) ;;
  *) [ -f "$IN" ] || IN="$CALLER_PWD/$IN" ;;
esac
case "$OUT" in
  /*) ;;
  *) OUT="$CALLER_PWD/$OUT" ;;
esac

[ -f "$IN" ] || { echo "[ERROR] 找不到输入文件：$IN" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

TMP=$(mktemp /tmp/gen-m3u.XXXXXX)

awk '
function quality_of(name,   n, a, last) {
  # 取 tvg-name 最后一段作为后缀，原样使用，不做白名单映射。
  # 后缀只是给人看的标签，上游出现新画质（花絮/杜比等）也能自动跟上。
  n = split(name, a, " ")
  if (n >= 2) return a[n]
  return ""
}

BEGIN { skip = 0 }

# 频道行
/^#EXTINF/ {
  # 提取 tvg-name 的值
  name = ""
  if (match($0, /tvg-name="[^"]*"/)) {
    name = substr($0, RSTART + 10, RLENGTH - 11)
  }

  # 规则1：含 4K 的整组丢弃（含下一行的 URL）
  if (name ~ /4K/) {
    skip = 1
    next
  }
  skip = 0

  # 规则2：删掉 tvg-name 属性（连同后面的一个空格）
  if (match($0, /tvg-name="[^"]*" ?/)) {
    $0 = substr($0, 1, RSTART - 1) substr($0, RSTART + RLENGTH)
  }

  q = quality_of(name)
  print $0
  next
}

# URL 行
/^[Hh][Tt][Tt][Pp]/ {
  if (skip) { skip = 0; next }
  # 规则3：去掉原有的 ?servicetype=1 查询串，末尾改为 $<画质>
  # 实测：?servicetype=1$超清 → 404 ；$超清 → 200，分片可下载
  sub(/\?servicetype=1$/, "")
  print $0 "$" q
  next
}

# 其他行（#EXTM3U 头、# update time、空行）原样保留
{
  if (skip) next
  print $0
}
' "$IN" > "$TMP"

# 安全写入：目标已存在则先备份
if [ -f "$OUT" ]; then
  mkdir -p "$REPO_DIR/backups"
  cp "$OUT" "$REPO_DIR/backups/$(basename "$OUT").bak-$(date +%Y%m%d-%H%M%S)"
fi
mv "$TMP" "$OUT"

# 统计
IN_CNT=$(grep -c '^#EXTINF' "$IN" || true)
OUT_CNT=$(grep -c '^#EXTINF' "$OUT" || true)
echo "生成完成：$OUT"
echo "  原始频道：$IN_CNT"
echo "  输出频道：$OUT_CNT"
echo "  移除 4K ：$((IN_CNT - OUT_CNT))"
echo "  画质分布："
grep -o '?\$[^ ]*$' "$OUT" | sort | uniq -c | sed 's/^/    /' || true
