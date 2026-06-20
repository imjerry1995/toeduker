#!/usr/bin/env bash
#
# build_go.sh — 模式 go
# 針對 Go 專案（如 prometheus-podman-exporter、gvisor）。
# 會先準備 Go toolchain，再跑 build，最後沿用共用的 fpm 打包邏輯產出 .deb。
#
# 需要的變數：
#   SOURCE_REPO   必填
#   GO_VERSION    Go 版本，預設 1.22.5；填 "system" 則用 apt 的 golang
#   BUILD_CMD     build 指令，預設偵測 Makefile，再退回 go build
#   BIN_PATHS     要打包的產物 src=dest，逗號分隔（必填）
#   PKG_NAME / PKG_VERSION / PKG_ARCH / PKG_DEPENDS  同 fpm 模式
#   PKG_ARCH      目標 deb 架構，預設 amd64；設 arm64 會交叉編譯（見下方說明）
#   APT_BUILD_DEPS  CGO 專案常需要，例如 podman-exporter 需
#                   "libbtrfs-dev libgpgme-dev libdevmapper-dev pkg-config"
#
# 關於跨架構（arm64）：
#   Go toolchain 一律抓「執行環境(host)」架構的版本，目標架構交給 GOARCH 交叉編譯。
#   純 Go（CGO_ENABLED=0）跨架構乾淨可行。CGO 跨架構需要對應的交叉 gcc，本腳本會
#   自動裝 gcc-aarch64-linux-gnu / gcc-x86-64-linux-gnu 並設定 CC；但若專案還相依
#   一堆「目標架構」的系統 dev header（如 podman-exporter 的 libbtrfs/gpgme），
#   amd64→arm64 交叉會非常麻煩，建議改用 native arm64 runner。
#
set -euo pipefail

[[ -n "${SOURCE_REPO:-}" ]] || die "go 模式需要 SOURCE_REPO"
[[ -n "${BIN_PATHS:-}"   ]] || die "go 模式需要 BIN_PATHS"

GO_VERSION="${GO_VERSION:-1.22.5}"
PKG_ARCH="${PKG_ARCH:-amd64}"

# host 架構（toolchain 要用這個）；目標架構是 PKG_ARCH。
host_arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"  # amd64 / arm64

# --- 準備 Go toolchain ------------------------------------------------------
if [[ "$GO_VERSION" == "system" ]]; then
  log "[go] 使用 apt 的 golang"
  apt-get install -y -qq --no-install-recommends golang-go make >/dev/null
else
  tarball="go${GO_VERSION}.linux-${host_arch}.tar.gz"
  log "[go] 下載 Go ${GO_VERSION} (host=${host_arch})"
  curl -fSL --retry 3 -o "/tmp/$tarball" "https://go.dev/dl/$tarball" \
    || die "[go] 無法下載 Go toolchain（go.dev 需在白名單內）"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$tarball"
  export PATH="/usr/local/go/bin:$PATH"
  apt-get install -y -qq --no-install-recommends make >/dev/null
fi
go version

# --- 目標架構（交叉編譯設定）-----------------------------------------------
export GOOS=linux
case "$PKG_ARCH" in
  amd64) export GOARCH=amd64 ;;
  arm64) export GOARCH=arm64 ;;
  *)     die "[go] 不支援的 PKG_ARCH: $PKG_ARCH（支援 amd64 / arm64）" ;;
esac

# CGO 跨架構時，補上對應的交叉 gcc 並設定 CC。
if [[ "$GOARCH" != "$host_arch" && "${CGO_ENABLED:-1}" != "0" ]]; then
  log "[go] 交叉編譯 ${host_arch}->${GOARCH} 且 CGO 開啟，安裝交叉 gcc"
  case "$GOARCH" in
    arm64) apt-get install -y -qq --no-install-recommends gcc-aarch64-linux-gnu >/dev/null
           export CC="${CC:-aarch64-linux-gnu-gcc}" ;;
    amd64) apt-get install -y -qq --no-install-recommends gcc-x86-64-linux-gnu >/dev/null
           export CC="${CC:-x86_64-linux-gnu-gcc}" ;;
  esac
fi

# CGO 專案（如 podman-exporter）需要的系統 dev 套件透過 APT_BUILD_DEPS 帶入
install_extra_deps

# --- clone & build ----------------------------------------------------------
WORK="$(mktemp -d)"
log "[go] clone https://github.com/${SOURCE_REPO}"
git clone --depth 1 ${SOURCE_REF:+--branch "$SOURCE_REF"} \
  "https://github.com/${SOURCE_REPO}.git" "$WORK/src"
cd "$WORK/src"

export GOFLAGS="${GOFLAGS:-}"
export GOPATH="${GOPATH:-/tmp/go}"

if [[ -n "${BUILD_CMD:-}" ]]; then
  log "[go] 執行 BUILD_CMD: $BUILD_CMD"
  bash -c "$BUILD_CMD"
elif [[ -f Makefile ]] && grep -qE '^(build|binary):' Makefile; then
  log "[go] 偵測到 Makefile，執行 make"
  make
else
  log "[go] 無 BUILD_CMD 也無合適 Makefile target，退回 go build ./..."
  go build ./...
fi

# --- 打包：重用共用的 fpm 邏輯 ---------------------------------------------
source "$SCRIPT_DIR/builders/_fpm_pack.sh"
fpm_pack go

cd /
rm -rf "$WORK"
