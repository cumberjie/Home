#!/bin/sh
# ============================================================
# sync.sh — 跟随上游 Healer-sys/Home 更新，且绝不让上游的删除生效
#
# 核心保证：
#   1. 上游的新改动 → 合并进来（内容跟随）
#   2. 上游删掉的文件 → 自动从合并前状态恢复（删除不生效）
#   3. 每次合并前 → 先做一份完整快照到 BACKUP_DIR
#   4. 永不 force push、永不改写历史 → 任何旧版本都能找回
#
# 用法：bash scripts/sync.sh
# 环境变量：
#   BACKUP_DIR   快照目录，默认 <repo 父目录>/backups
#   UPSTREAM     upstream 远程名，默认 upstream
#   BRANCH       分支名，默认 main
#   DRY_RUN      设为 1 只报告不提交不推送
# ============================================================
set -eu

# ---- 定位仓库根 ----
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${REPO_DIR:-}" ]; then
  REPO_DIR=""
  for cand in "$SCRIPT_DIR/.." "$SCRIPT_DIR"; do
    if git -C "$cand" rev-parse --git-dir >/dev/null 2>&1; then
      REPO_DIR=$(git -C "$cand" rev-parse --show-toplevel)
      break
    fi
  done
fi
[ -n "${REPO_DIR:-}" ] || { echo "[ERROR] 找不到 git 仓库（脚本应在仓库内运行）" >&2; exit 1; }
cd "$REPO_DIR"

UPSTREAM=${UPSTREAM:-upstream}
ORIGIN=${ORIGIN:-origin}
BRANCH=${BRANCH:-main}
BACKUP_DIR=${BACKUP_DIR:-$(CDPATH= cd -- "$REPO_DIR/.." && pwd)/backups}
DRY_RUN=${DRY_RUN:-0}
SKIP_PUSH=${SKIP_PUSH:-0}

TS=$(date -u '+%Y%m%d-%H%M%S')
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "找不到 git"

# 关键：关闭路径转义。默认 core.quotepath=true 时，中文/特殊字符路径会被
# 输出为 "iptv/\350\207\252..." 这样的八进制转义，后续按文件名恢复必然失败，
# 删除保护会静默失效。只对本仓库设本地配置，不污染全局。
git config core.quotepath false

# 身份兜底：仅当仓库未配置时用环境变量，不写全局配置
if ! git config user.email >/dev/null 2>&1; then
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gh-home-sync}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-gh-home-sync@localhost}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"
  log "提示：仓库未配置 git 身份，使用内置身份提交"
fi

# ---------- 0. 抓取 ----------
log "抓取 $UPSTREAM / $ORIGIN"
git fetch --prune --quiet "$UPSTREAM" || fail "fetch $UPSTREAM 失败（网络或凭据问题）"
git fetch --prune --quiet "$ORIGIN"   || log "警告：fetch $ORIGIN 失败，继续（推送阶段会重试）"

PREV=$(git rev-parse HEAD)
UP=$(git rev-parse "$UPSTREAM/$BRANCH")

if git merge-base --is-ancestor "$UP" HEAD 2>/dev/null; then
  log "已包含上游最新提交 ${UP%????????}，无需同步"
  exit 0
fi

log "本地 ${PREV%????????} → 上游 ${UP%????????}"

# ---------- 1. 算出上游要删/改什么 ----------
# 以共同祖先为基准算"上游删了什么"，只保留本地确实有的，避免把本地独有文件误报成上游删除
BASE=$(git merge-base "$PREV" "$UP" 2>/dev/null || echo "$PREV")
DELETED_FILE=$(mktemp /tmp/sync-del.XXXXXX)
git -c core.quotepath=false diff --name-only --diff-filter=D "$BASE" "$UP" 2>/dev/null | while IFS= read -r f; do
  [ -n "$f" ] && git cat-file -e "$PREV:$f" 2>/dev/null && printf '%s\n' "$f"
done > "$DELETED_FILE" || true
DEL_COUNT=$(wc -l < "$DELETED_FILE" | tr -d ' ')

CHANGED_FILE=$(mktemp /tmp/sync-chg.XXXXXX)
git -c core.quotepath=false diff --name-status "$PREV" "$UP" > "$CHANGED_FILE" || true

log "上游改动：$(grep -c . "$CHANGED_FILE" 2>/dev/null || echo 0) 个路径，其中删除 $DEL_COUNT 个"
if [ "$DEL_COUNT" -gt 0 ]; then
  log "⚠ 上游删除了以下文件（将自动保留）："
  sed 's/^/    - /' "$DELETED_FILE"
fi

# ---------- 2. 合并前快照（真正的"备份"） ----------
mkdir -p "$BACKUP_DIR"
SNAP="$BACKUP_DIR/snapshot-$TS.tar.gz"
git archive --format=tar.gz -o "$SNAP" "$PREV" 2>/dev/null \
  || fail "创建快照失败"
log "快照已存：$SNAP ($(wc -c < "$SNAP" | tr -d ' ') 字节)"

# 校验清单：路径 + git blob 哈希 + 大小
MAN="$BACKUP_DIR/manifest-$TS.txt"
git -c core.quotepath=false ls-tree -r -l "$PREV" | awk -F'\t' '{n=split($1,a," "); printf "%-12s %-10s %s\n", substr(a[3],1,10), a[4], $2}' > "$MAN"
log "清单已存：$MAN（$(wc -l < "$MAN" | tr -d ' ') 个文件）"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1，到此为止。上游改动预览："
  head -40 "$CHANGED_FILE"
  rm -f "$DELETED_FILE" "$CHANGED_FILE"
  exit 0
fi

# ---------- 3. 合并上游 ----------
MERGE_MSG="sync: 跟随上游 ${UP%????????} ($(date -u '+%Y-%m-%d'))"
MERGE_ERR=/tmp/sync-merge.$$.log
if git merge --no-edit --no-ff -m "$MERGE_MSG" "$UP" >"$MERGE_ERR" 2>&1; then
  log "合并成功（无冲突）"
else
  # 关键：区分「真冲突」和「其他失败」。没有未合并路径 = 不是冲突
  UNMERGED=$(git -c core.quotepath=false diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -z "$UNMERGED" ]; then
    cat "$MERGE_ERR" >&2
    git merge --abort 2>/dev/null || true
    rm -f "$MERGE_ERR"
    fail "合并失败且非冲突（见上方输出），已放弃本次合并"
  fi
  log "检测到冲突，按「内容取上游、删除不生效」逐项处理"
  printf '%s\n' "$UNMERGED" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    if git cat-file -e "$UP:$f" 2>/dev/null; then
      git checkout --theirs -- "$f" 2>/dev/null || true
      git add -- "$f" 2>/dev/null || true
      log "  冲突·取上游内容: $f"
    else
      git checkout "$PREV" -- "$f" 2>/dev/null || true
      git add -- "$f" 2>/dev/null || true
      log "  冲突·上游删除，保留本地: $f"
    fi
  done
  # 兜底：仍未解决的，取上游（若上游也没有则保留本地）
  STILL=$(git -c core.quotepath=false diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$STILL" ]; then
    printf '%s\n' "$STILL" | while IFS= read -r f; do
      [ -z "$f" ] && continue
      if git cat-file -e "$UP:$f" 2>/dev/null; then
        git checkout --theirs -- "$f" 2>/dev/null && git add -- "$f" 2>/dev/null
      else
        git checkout "$PREV" -- "$f" 2>/dev/null && git add -- "$f" 2>/dev/null
      fi
    done
  fi
  if ! git commit --no-edit >/dev/null 2>&1; then
    rm -f "$MERGE_ERR"
    fail "冲突已解决但提交失败（检查 git 身份配置）"
  fi
  log "冲突全部处理完毕"
fi
rm -f "$MERGE_ERR"

# ---------- 4. 恢复被上游删除的文件 ----------
RESTORED_FILE=$(mktemp /tmp/sync-restored.XXXXXX)
RESTORED_COUNT=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ ! -e "$f" ]; then
    if git checkout "$PREV" -- "$f" 2>/dev/null; then
      printf '%s\n' "$f" >> "$RESTORED_FILE"
      RESTORED_COUNT=$((RESTORED_COUNT + 1))
      log "  [恢复] $f"
    else
      log "  [失败] 无法恢复 $f"
    fi
  fi
done < "$DELETED_FILE"

if [ "$RESTORED_COUNT" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && git add -- "$f" 2>/dev/null
  done < "$RESTORED_FILE"
  git commit -m "protect: 保留上游已删除的 $RESTORED_COUNT 个文件 ($(date -u '+%Y-%m-%d'))" >/dev/null 2>&1 || true
  log "已生成保护提交，恢复 $RESTORED_COUNT 个文件"
fi

# ---------- 5. 审计日志写入仓库（GitHub 网页可见） ----------
{
  printf '\n## %s  ·  上游 `%s`\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "${UP%????????}"
  printf -- '- 改动路径：%s 个\n' "$(grep -c . "$CHANGED_FILE" 2>/dev/null || echo 0)"
  printf -- '- 上游删除：%s 个' "$DEL_COUNT"
  if [ "$RESTORED_COUNT" -gt 0 ]; then
    printf '（已全部保留）\n'
    while IFS= read -r f; do [ -n "$f" ] && printf '  - `%s`\n' "$f"; done < "$RESTORED_FILE"
  else
    printf '\n'
  fi
  printf -- '- 快照：`%s`\n' "$(basename "$SNAP")"
} >> SYNC_LOG.md

git add SYNC_LOG.md
git commit -m "log: 同步记录 $(date -u '+%Y-%m-%d')" >/dev/null 2>&1 || true

# ---------- 6. 推送（永不 force） ----------
if [ "$SKIP_PUSH" = "1" ]; then
  log "SKIP_PUSH=1，跳过推送。新 HEAD $(git rev-parse --short HEAD)"
  rm -f "$DELETED_FILE" "$CHANGED_FILE"
  exit 0
fi

PUSHED=0
i=1
while [ "$i" -le 3 ]; do
  if git push "$ORIGIN" "HEAD:$BRANCH" 2>/dev/null; then
    PUSHED=1
    break
  fi
  log "推送失败（第 $i 次），尝试先合并远端再重试"
  git merge --no-edit "origin/$BRANCH" >/dev/null 2>&1 || true
  i=$((i + 1))
done

rm -f "$DELETED_FILE" "$CHANGED_FILE" "$RESTORED_FILE"

if [ "$PUSHED" -eq 1 ]; then
  log "✅ 已推送到 $ORIGIN/$BRANCH（新 HEAD $(git rev-parse --short HEAD)）"
else
  fail "推送失败 3 次，改动已留在本地仓库，请手动检查"
fi
