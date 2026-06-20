#!/usr/bin/env bash
#
# build_url.sh — 模式 url
# 最單純的情境：直接給定現成 .deb 的下載連結，下載後放進 OUTPUT_DIR。
# 這對應你原本 linux-dbgsym-crash 的用法（從 ddebs.ubuntu.com 抓 dbgsym deb）。
#
# 需要的變數：
#   DEB_URLS   逗號或換行分隔的 .deb 下載連結
#
set -euo pipefail

[[ -n "${DEB_URLS:-}" ]] || die "url 模式需要 DEB_URLS"

# 同時支援逗號與換行當分隔
mapfile -t urls < <(echo "$DEB_URLS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')

[[ "${#urls[@]}" -gt 0 ]] || die "url 模式：DEB_URLS 解析後是空的"

for url in "${urls[@]}"; do
  fname="$(basename "${url%%\?*}")"
  case "$fname" in
    *.deb|*.ddeb) ;;
    *) log "[url] 警告：$fname 看起來不是 .deb/.ddeb，仍照常下載" ;;
  esac
  log "[url] 下載 $url"
  curl -fSL --retry 3 -o "$OUTPUT_DIR/$fname" "$url" \
    || die "[url] 下載失敗：$url"
  # 基本驗證：確認是 Debian 套件
  if ! file "$OUTPUT_DIR/$fname" | grep -qi 'debian binary package'; then
    die "[url] $fname 不是有效的 Debian 套件"
  fi
  # ddebs.ubuntu.com 的 dbgsym 套件副檔名常是 .ddeb，內容與 .deb 相同。
  # 後續 build.sh 的產出檢查與 Dockerfile.image 都以 *.deb 收集，
  # 這裡統一改名成 .deb，避免 .ddeb 被整條 pipeline 漏掉。
  if [[ "$fname" == *.ddeb ]]; then
    newname="${fname%.ddeb}.deb"
    log "[url] $fname 是 .ddeb，改名為 $newname 以利後續收集"
    mv -f "$OUTPUT_DIR/$fname" "$OUTPUT_DIR/$newname"
    fname="$newname"
  fi
done
