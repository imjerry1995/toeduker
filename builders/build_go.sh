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

# 先提醒：純 Go 不需要 C 編譯器，但需要 CGO 的專案沒有編譯器會以難懂的訊息失敗。
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  log "[go] 注意：容器內目前沒有 C 編譯器。純 Go 專案沒差；但若此專案需要 CGO，"
  log "[go]       請在 workflow 的 apt_build_deps 補上 gcc 與對應的 -dev 套件後重跑。"
fi

# 跑 build；失敗時若看起來是 CGO / C 編譯器 / dev header 問題，翻成白話提示。
run_build() {
  local logf rc
  logf="$(mktemp)"
  set +e
  "$@" 2>&1 | tee "$logf"
  rc="${PIPESTATUS[0]}"
  set -e
  if [[ "$rc" -ne 0 ]]; then
    if grep -qiE 'build constraints exclude all Go files|exec: "?(gcc|cc)"?: executable file not found|cgo: C compiler|C compiler "?cc"? not found|fatal error: .*\.h: No such file|was not found.*pkg-config|pkg-config.*not found|undefined reference to' "$logf"; then
      rm -f "$logf"
      die "[go] build 失敗，研判是 CGO / C 編譯相依問題：此專案需要 CGO，但容器缺少 C 編譯器
      或對應的 -dev header / pkg-config。請在 workflow 的「apt_build_deps」欄位補上需要的套件
      再重跑，常見起手式：  gcc pkg-config  （再加專案要的 lib，例如
      libgpgme-dev libbtrfs-dev libdevmapper-dev libsystemd-dev）。原始錯誤見上方 log。"
    fi
    rm -f "$logf"
    die "[go] build 指令失敗（exit $rc）"
  fi
  rm -f "$logf"
}

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
  run_build bash -c "$BUILD_CMD"
elif [[ -f Makefile ]] && grep -qE '^(build|binary):' Makefile; then
  log "[go] 偵測到 Makefile，執行 make"
  run_build make
else
  log "[go] 無 BUILD_CMD 也無合適 Makefile target，退回 go build ./..."
  run_build go build ./...
fi

# --- 打包：重用共用的 fpm 邏輯 ---------------------------------------------
source "$SCRIPT_DIR/builders/_fpm_pack.sh"
fpm_pack go

cd /
rm -rf "$WORK"
