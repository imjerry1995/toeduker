#!/usr/bin/env bash
#
# build.sh — 通用 deb builder 的進入點。
# 根據 MODE 分派到對應的 builder，把產出的 .deb 收集到 $OUTPUT_DIR。
#
# 可用環境變數（通常由 GitHub Action 的 inputs 帶進來）：
#   MODE          dpkg | fpm | url | go   (必填)
#   SOURCE_REPO   要 build 的 GitHub repo，格式 owner/name 或完整 URL（dpkg/fpm/go 用）
#   SOURCE_REF    branch / tag / commit（預設 抓 default branch）
#   DEB_URLS      逗號或換行分隔的現成 .deb 下載連結（url 模式用）
#   PKG_NAME      套件名稱（fpm 模式用，預設取 repo 名）
#   PKG_VERSION   套件版本（fpm 模式用，預設 0.0.0+日期）
#   BUILD_CMD     build 指令（fpm/go 模式）
#   BIN_PATHS     build 完要打包的檔案，格式 src=dest 以逗號分隔（fpm/go 模式）
#   APT_BUILD_DEPS 額外要先 apt install 的 build 相依（空白分隔）
#   GO_VERSION    Go 版本（go 模式，預設見 build_go.sh）
#   OUTPUT_DIR    .deb 收集目錄（預設 /out）
#
set -euo pipefail

export OUTPUT_DIR="${OUTPUT_DIR:-/out}"
mkdir -p "$OUTPUT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\033[1;34m[build]\033[0m $*"; }
die()  { echo -e "\033[1;31m[build:error]\033[0m $*" >&2; exit 1; }

MODE="${MODE:-}"
[[ -n "$MODE" ]] || die "必須指定 MODE (dpkg|fpm|url|go)"

# 正規化 SOURCE_REPO：接受 owner/name 或完整 https URL
normalize_repo() {
  local r="$1"
  r="${r%.git}"
  r="${r#https://github.com/}"
  r="${r#git@github.com:}"
  echo "$r"
}

if [[ -n "${SOURCE_REPO:-}" ]]; then
  SOURCE_REPO="$(normalize_repo "$SOURCE_REPO")"
  # 支援 owner/name@ref 寫法：把 @ 後面的 branch/tag/commit 拆進 SOURCE_REF。
  # （source_ref 不放表單，要釘版本就用這個合併寫法。）
  if [[ "$SOURCE_REPO" == *@* ]]; then
    : "${SOURCE_REF:=${SOURCE_REPO##*@}}"
    SOURCE_REPO="${SOURCE_REPO%@*}"
  fi
  export SOURCE_REPO
  export SOURCE_REF="${SOURCE_REF:-}"
fi

# 安裝共用基礎工具
ensure_base_tools() {
  export DEBIAN_FRONTEND=noninteractive
  # 容忍環境中第三方 repo 故障：先正常 update，失敗則只用主 sources 再試一次。
  if ! apt-get update -qq 2>/dev/null; then
    log "apt-get update 有來源失敗，改用乾淨來源清單重試"
    apt-get update -qq \
      -o Dir::Etc::sourcelist="sources.list" \
      -o Dir::Etc::sourceparts="-" \
      -o APT::Get::List-Cleanup="0" 2>/dev/null || true
  fi
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git xz-utils file >/dev/null
}

# 安裝使用者額外指定的 build 相依
install_extra_deps() {
  if [[ -n "${APT_BUILD_DEPS:-}" ]]; then
    log "安裝額外 build 相依: $APT_BUILD_DEPS"
    apt-get install -y -qq --no-install-recommends $APT_BUILD_DEPS >/dev/null
  fi
}

log "MODE=$MODE  SOURCE_REPO=${SOURCE_REPO:-<none>}  OUTPUT_DIR=$OUTPUT_DIR"
ensure_base_tools

case "$MODE" in
  dpkg) source "$SCRIPT_DIR/builders/build_dpkg.sh" ;;
  fpm)  source "$SCRIPT_DIR/builders/build_fpm.sh"  ;;
  url)  source "$SCRIPT_DIR/builders/build_url.sh"  ;;
  go)   source "$SCRIPT_DIR/builders/build_go.sh"   ;;
  *)    die "未知的 MODE: $MODE" ;;
esac

log "完成。產出的套件（.deb / .ddeb）："
# 同時接受 .deb 與 .ddeb（dbgsym）。任一存在即視為成功。
shopt -s nullglob
produced=( "$OUTPUT_DIR"/*.deb "$OUTPUT_DIR"/*.ddeb )
shopt -u nullglob
[[ "${#produced[@]}" -gt 0 ]] || die "沒有產出任何 .deb/.ddeb，build 視為失敗"
ls -lh "${produced[@]}"
