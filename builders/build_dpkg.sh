#!/usr/bin/env bash
#
# build_dpkg.sh — 模式 dpkg
# 適用於 repo 本身就有 debian/ 打包規則的專案。
# 直接 clone 後跑 dpkg-buildpackage，把產出的 .deb 收進 OUTPUT_DIR。
#
set -euo pipefail

[[ -n "${SOURCE_REPO:-}" ]] || die "dpkg 模式需要 SOURCE_REPO"

WORK="$(mktemp -d)"
log "[dpkg] clone https://github.com/${SOURCE_REPO}"
git clone --depth 1 ${SOURCE_REF:+--branch "$SOURCE_REF"} \
  "https://github.com/${SOURCE_REPO}.git" "$WORK/src"

cd "$WORK/src"

[[ -d debian ]] || die "[dpkg] 此 repo 沒有 debian/ 目錄，請改用 fpm 或 go 模式"

log "[dpkg] 安裝 build 相依 (mk-build-deps)"
apt-get install -y -qq --no-install-recommends \
  build-essential devscripts equivs >/dev/null
# 依 debian/control 自動裝齊 build 相依
mk-build-deps --install --remove \
  --tool 'apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends' \
  debian/control >/dev/null

install_extra_deps

log "[dpkg] dpkg-buildpackage"
# -us -uc 不簽章；-b 只 build binary（產 .deb，不需 orig tarball）
dpkg-buildpackage -us -uc -b

# 產出的 .deb 會在上層目錄
find "$WORK" -maxdepth 1 -name '*.deb' -exec cp -v {} "$OUTPUT_DIR/" \;
cd /
rm -rf "$WORK"
