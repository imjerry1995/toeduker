# deb2docker — 通用 deb 打包 + 掃描用 image 產生器

把任意來源的 `.deb` 包進一個 minimal 的 Docker image，push 到 Docker Hub，
讓內部掃描器把 image 拉進去時順便掃這些 deb。

這是 `linux-dbgsym-crash` 的通用化版本：除了「直接放現成 deb」之外，
還能從 GitHub 原始碼自動 build 出 deb。

## 支援的四種模式（MODE）

| MODE  | 適用情境 | 必填 inputs |
|-------|----------|-------------|
| `url`  | 已有現成 `.deb` 連結（如 ddebs.ubuntu.com、官方 release） | `deb_urls` |
| `dpkg` | repo 本身就有 `debian/` 打包規則 | `source_repo` |
| `fpm`  | 一般專案，build 後用 fpm 把產物打成 deb | `source_repo`, `bin_paths`（通常還有 `build_cmd`） |
| `go`   | Go 專案（含 CGO/Bazel），自動裝 Go toolchain 再打包 | `source_repo`, `bin_paths` |

## 怎麼用

1. **Fork 這個 repo。**
2. 在 repo 的 Settings → Secrets 加：
   - `DOCKERHUB_USERNAME`
   - `DOCKERHUB_TOKEN`（Docker Hub access token）
3. 到 Actions → **build-deb-and-push** → **Run workflow**，填 inputs。

### 範例 1：放現成的 dbgsym deb（原本的用法）

```
mode:     url
deb_urls: http://ddebs.ubuntu.com/pool/main/l/linux-hwe-6.17/linux-image-...-dbgsym_..._amd64.ddeb
image_tag: myorg/scan-target:6.17.0-20
```

### 範例 2：從 Go 專案 build（prometheus-podman-exporter）

```
mode:           go
source_repo:    containers/prometheus-podman-exporter
build_cmd:      make binary
bin_paths:      bin/prometheus-podman-exporter=/usr/bin/prometheus-podman-exporter
apt_build_deps: libbtrfs-dev libgpgme-dev libdevmapper-dev pkg-config gcc
pkg_name:       prometheus-podman-exporter
```

或直接填 `recipe: podman-exporter`，其餘留空。

### 範例 3：gvisor

gvisor 從源碼 build 需要 bazel（很重），建議用官方 release deb：

```
recipe: gvisor
```
（內部就是 `mode=url` 抓官方 `runsc.deb`。要從源碼 build 的設定在 `recipes/gvisor.env` 註解中。）

## Recipes（懶人包）

`recipes/` 下放預設好的設定，workflow inputs 只要填 `recipe` 名就好：

- `podman-exporter` — Go + CGO 範例
- `gvisor` — 官方 deb 範例
- `dbgsym-kernel` — 對應原本的 kernel dbgsym 用法

要新增自己的，複製一份 `.env` 改參數即可。

## 架構

```
build.sh              # 進入點，依 MODE 分派
builders/
  build_url.sh        # 下載現成 deb
  build_dpkg.sh       # dpkg-buildpackage
  build_fpm.sh        # build 後 fpm 打包
  build_go.sh         # Go toolchain + build + fpm 打包
recipes/*.env         # 各專案預設參數
Dockerfile.builder    # 跑 build.sh 的環境（toolchain 都在這，不進產出 image）
Dockerfile.image      # 最終 minimal image，只放 /debs/*.deb
.github/workflows/build-deb.yml
```

build 與產出 image 刻意分兩個 Dockerfile：toolchain 不會污染最終要掃描的 image。

## Smoke test（冒煙測試）

`.github/workflows/smoke-test.yml` 會對四種模式各跑一次最小驗證：能不能成功產出
`.deb`，以及 `Dockerfile.image` 的 `COPY out/*.deb` 通不通。**不會 push、不需要 Docker
Hub 憑證**，純粹確認 build 階段沒爆。

- 觸發：手動 (Actions → **smoke-test** → Run workflow)，或 push 改動 build 邏輯時自動跑。
- 測試目標：`url`=archive.ubuntu.com 的 hello deb、`fpm`/`go`=`golang/example`（純 Go）、
  `dpkg`=`streadway/hello-debian`（C + debhelper）。
- 四個 job 全綠＝四種模式在真實環境能動。產出的 deb 會上傳成 artifact 可下載檢查。

要驗自己的目標時，照 `build-deb.yml` 的 inputs 跑即可；smoke-test 只是固定幾個已知目標的回歸測試。

## 注意事項

- ddebs 的 dbgsym 副檔名常是 `.ddeb`。`url` 模式下載後會**自動把 `.ddeb` 改名成 `.deb`**
  （`build_url.sh`），所以 `Dockerfile.image` 的 `COPY out/*.deb` 能正常收到，無需手動處理。
- `go` 模式預設從 go.dev 下載 toolchain；若 runner 有網路限制，把 `GO_VERSION` 設成 `system` 改用 apt 版。
- 本機測試：`MODE=url DEB_URLS=... OUTPUT_DIR=/tmp/out ./build.sh`
