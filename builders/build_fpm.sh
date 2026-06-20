#!/usr/bin/env bash
#
# build_fpm.sh — 模式 fpm
# 適用於沒有 debian/ 規則的專案（如一般 Go/Rust/C 專案）。
# 流程：clone → 跑 BUILD_CMD → 把 BIN_PATHS 指定的產物用 fpm 打成 .deb。
# 實際的 staging + fpm 打包交給共用的 _fpm_pack.sh（與 go 模式共用）。
#
# 需要的變數：
#   SOURCE_REPO   必填
#   BUILD_CMD     build 指令，例如 "make build" 或 "go build -o bin/app ./cmd/app"
#   BIN_PATHS     要打包的檔案，格式 src=dest，逗號分隔
#                 例如 "bin/app=/usr/bin/app,configs/app.yaml=/etc/app/app.yaml"
#   PKG_NAME      套件名，預設取 repo 名
#   PKG_VERSION   版本，預設 0.0.0+YYYYMMDD
#   PKG_ARCH      架構，預設 amd64（cross-arch 時 BUILD_CMD 需自行產出該架構的產物）
#   PKG_DEPENDS   runtime 相依，逗號分隔（轉成多個 --depends）
#
set -euo pipefail

[[ -n "${SOURCE_REPO:-}" ]] || die "fpm 模式需要 SOURCE_REPO"
[[ -n "${BIN_PATHS:-}"   ]] || die "fpm 模式需要 BIN_PATHS（要打包哪些檔案）"

log "[fpm] 安裝 build 工具"
apt-get install -y -qq --no-install-recommends build-essential >/dev/null
install_extra_deps

WORK="$(mktemp -d)"
log "[fpm] clone https://github.com/${SOURCE_REPO}"
git clone --depth 1 ${SOURCE_REF:+--branch "$SOURCE_REF"} \
  "https://github.com/${SOURCE_REPO}.git" "$WORK/src"
cd "$WORK/src"

if [[ -n "${BUILD_CMD:-}" ]]; then
  log "[fpm] 執行 BUILD_CMD: $BUILD_CMD"
  bash -c "$BUILD_CMD"
else
  log "[fpm] 未指定 BUILD_CMD，略過 build 步驟（假設產物已在 repo 內）"
fi

# staging + fpm 打包（共用邏輯）
source "$SCRIPT_DIR/builders/_fpm_pack.sh"
fpm_pack fpm

cd /
rm -rf "$WORK"
