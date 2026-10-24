#!/usr/bin/env bash
# 一键推送到 GitHub 并触发 Actions 出 IPA（Linux / macOS / WSL 用这个；
# Windows 上用同名 push_and_build.ps1）。
#
#   ./push_and_build.sh <token> [owner/repo]
#
# token 需要 repo + workflow 权限。
set -euo pipefail

TOKEN="${1:-}"
FULL="${2:-}"

if [ -z "$TOKEN" ]; then
  echo "用法: $0 <github_token> [owner/repo]" >&2
  exit 1
fi

API="https://api.github.com"
HDR_AUTH="Authorization: Bearer $TOKEN"
HDR_ACC="Accept: application/vnd.github+json"
HDR_VER="X-GitHub-Api-Version: 2022-11-28"

say() { printf '\033[36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 1. 身份 ----------
say "校验 token"
OWNER=$(curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" "$API/user" \
        | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$OWNER" ] || die "token 无效（拿不到 login）"
say "身份: $OWNER"

if [ -z "$FULL" ]; then
  FULL="$OWNER/$(basename "$(pwd)")"
fi
REPO_NAME="${FULL#*/}"
say "目标仓库: $FULL"

# ---------- 2. 建仓库（不存在才建） ----------
if curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" "$API/repos/$FULL" >/dev/null 2>&1; then
  say "仓库已存在"
else
  say "创建仓库 $FULL"
  curl -fsS -X POST -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" \
       -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}" \
       "$API/user/repos" >/dev/null || die "建仓库失败"
  sleep 2
fi

# ---------- 3. 推送 ----------
say "推送 main"
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "https://github.com/$FULL.git"

BASIC=$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')
SHA_BEFORE=$(git rev-parse HEAD)
git -c "http.extraheader=AUTHORIZATION: basic $BASIC" push -u origin main
say "已推送 $SHA_BEFORE"

# ---------- 4. 等 Actions ----------
say "等待 run 出现（最多 3 分钟）"
RUN_ID=""
for _ in $(seq 1 30); do
  sleep 6
  BODY=$(curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" \
         "$API/repos/$FULL/actions/runs?per_page=10" || true)
  RUN_ID=$(printf '%s' "$BODY" \
    | tr '{' '\n' \
    | grep -F "\"head_sha\":\"$SHA_BEFORE\"" \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
  [ -n "$RUN_ID" ] && break
done
[ -n "$RUN_ID" ] || die "没看到对应 run，请手动打开 https://github.com/$FULL/actions"

say "run id=$RUN_ID，构建中（首次 3–8 分钟）"
STATE=""
for _ in $(seq 1 160); do
  sleep 15
  CUR=$(curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" "$API/repos/$FULL/actions/runs/$RUN_ID" || true)
  STATE=$(printf '%s' "$CUR" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  CONC=$(printf '%s' "$CUR" | grep -o '"conclusion":null\|"conclusion":"[^"]*"' | head -1 | cut -d'"' -f4)
  printf '    %s  %s/%s\n' "$(date +%H:%M:%S)" "${STATE:-?}" "${CONC:-null}"
  [ "$STATE" = "completed" ] && break
done

if [ "$CONC" != "success" ]; then
  say "构建未成功（$CONC），拉日志："
  curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" \
       "$API/repos/$FULL/actions/runs/$RUN_ID/jobs" \
    | tr '{' '\n' | grep -E '"name"|"conclusion"' | head -60 || true
  die "见 https://github.com/$FULL/actions/runs/$RUN_ID"
fi

# ---------- 5. 下载 ----------
say "下载 artifact"
URL=$(curl -fsS -H "$HDR_AUTH" -H "$HDR_ACC" -H "$HDR_VER" \
      "$API/repos/$FULL/actions/runs/$RUN_ID/artifacts" \
      | tr '{' '\n' | grep -F 'SparkKeeper-unsigned-ipa' \
      | sed -n 's/.*"archive_download_url":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$URL" ] || die "没找到 ipa artifact"

mkdir -p out
curl -fsSL -H "User-Agent: push-and-build" -o out/ipa.zip "$URL"
( cd out && unzip -oq ipa.zip && rm -f ipa.zip )
ls -lh out/*.ipa
say "完成：out/ 下就是可签名的 unsigned IPA"
