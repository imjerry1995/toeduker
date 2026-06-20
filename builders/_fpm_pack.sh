#!/usr/bin/env bash
#
# _fpm_pack.sh — fpm 模式與 go 模式共用的打包邏輯。
# 不是獨立 builder，而是被 build_fpm.sh / build_go.sh source 進去用的函式庫。
# 依賴 build.sh 已定義的 log() / die() 與 $OUTPUT_DIR。
#
# 使用方式：
#   source "$SCRIPT_DIR/builders/_fpm_pack.sh"
#   fpm_pack <log_tag>     # 例如 fpm_pack fpm / fpm_pack go
#
# 讀取的變數（呼叫前先設好）：
#   BIN_PATHS    要打包的產物 src=dest，逗號分隔（必填）
#   SOURCE_REPO  用來推導 PKG_NAME 預設值
#   PKG_NAME / PKG_VERSION / PKG_ARCH / PKG_DEPENDS  套件 metadata（有預設）
#   OUTPUT_DIR   .deb 產出目錄
#

# 確保 fpm 可用。idempotent：apt/gem 對已安裝的不會重做。
ensure_fpm() {
  command -v fpm >/dev/null 2>&1 && return 0
  apt-get install -y -qq --no-install-recommends \
    build-essential ruby ruby-dev >/dev/null
  gem install --no-document fpm >/dev/null
}

# fpm_pack <log_tag>
# 依 BIN_PATHS 把產物擺進 staging，再用 fpm 打成 .deb 放到 OUTPUT_DIR。
fpm_pack() {
  local tag="${1:-fpm}"

  [[ -n "${BIN_PATHS:-}" ]] || die "[$tag] 需要 BIN_PATHS（要打包哪些檔案）"

  # 套件 metadata 預設值（與舊版 build_fpm/build_go 行為一致）
  PKG_NAME="${PKG_NAME:-$(basename "${SOURCE_REPO:?需要 SOURCE_REPO 或 PKG_NAME}")}"
  PKG_VERSION="${PKG_VERSION:-0.0.0+$(date +%Y%m%d)}"
  PKG_ARCH="${PKG_ARCH:-amd64}"

  ensure_fpm

  local stage; stage="$(mktemp -d)"
  local pair src dest target
  IFS=',' read -ra pairs <<< "$BIN_PATHS"
  for pair in "${pairs[@]}"; do
    src="${pair%%=*}"
    dest="${pair#*=}"
    [[ "$src" != "$pair" ]] || die "[$tag] BIN_PATHS 格式錯誤，需 src=dest：$pair"
    [[ -e "$src" ]] || die "[$tag] 找不到 build 產物：$src（檢查 BUILD_CMD 與輸出路徑）"
    target="$stage/${dest#/}"
    mkdir -p "$(dirname "$target")"
    cp -r "$src" "$target"
    log "[$tag] 收錄 $src -> $dest"
  done

  local fpm_args=(
    -s dir -t deb
    -n "$PKG_NAME"
    -v "$PKG_VERSION"
    -a "$PKG_ARCH"
    -C "$stage"
    --deb-no-default-config-files
  )
  if [[ -n "${PKG_DEPENDS:-}" ]]; then
    local d
    IFS=',' read -ra deps <<< "$PKG_DEPENDS"
    for d in "${deps[@]}"; do fpm_args+=(--depends "$d"); done
  fi

  log "[$tag] 打包 ${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
  ( cd "$OUTPUT_DIR" && fpm "${fpm_args[@]}" . )

  rm -rf "$stage"
}
