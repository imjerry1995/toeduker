# toeduker — 通用 deb 打包 + 掃描用 image 產生器

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

> **90% 的情況：只要選 `mode`、填 `recipe`（或 `url` 模式的 `deb_urls`）、`image_tag` 三格就好，其餘留空。**
> 表單只有 9 個欄位，每個 description 都標了適用模式（如 `【url】`、`【fpm/go】`）——不是你那個模式的就留白。

### 表單欄位一覽（共 9 個）

| 欄位 | 適用 | 說明 |
|------|------|------|
| `mode` | 全部 | `url` / `dpkg` / `fpm` / `go`（用了 recipe 時以 recipe 內的 MODE 為準） |
| `recipe` | 可選 | 懶人包：填 `podman-exporter` 等，幾乎不用再填別的 |
| `source_repo` | dpkg/fpm/go | `owner/name`，要指定分支/tag 寫 `owner/name@v1.2` |
| `deb_urls` | url | 現成 `.deb`/`.ddeb` 連結，逗號或換行分隔 |
| `build_cmd` | fpm/go | build 指令，例如 `make binary` |
| `bin_paths` | fpm/go | 產物 `src=dest`，例如 `bin/app=/usr/bin/app` |
| `pkg_name` | fpm/go | 套件名稱，預設取 repo 名 |
| `image_tag` | 全部 | 最終 image tag，留空＝自動命名 |
| `push` | 全部 | 是否推到 Docker Hub |

進階旋鈕刻意**不放表單**（GitHub inputs 上限 10 個）：
- `apt_build_deps`、`pkg_version`、`source_ref` → 寫在 recipe 裡（見下）。
- `ubuntu_version`（base image 版本）→ 固定 `24.04`；要改就改 `Dockerfile.builder` 與
  `Dockerfile.image` 的 `ARG UBUNTU_VERSION=` 預設（它在 runner 上 build，recipe 改不到它）。

### 範例 1：放現成的 dbgsym deb（原本的用法）

```
mode:     url
deb_urls: http://ddebs.ubuntu.com/pool/main/l/linux-hwe-6.17/linux-image-...-dbgsym_..._amd64.ddeb
image_tag: myorg/scan-target:6.17.0-20
```

### 範例 2：從 Go 專案 build（prometheus-podman-exporter）

最省事：填 `recipe: podman-exporter`，其餘留空。若要手填：

```
mode:        go
source_repo: containers/prometheus-podman-exporter   # 要釘版本：containers/prometheus-podman-exporter@v1.4.0
build_cmd:   make binary
bin_paths:   bin/prometheus-podman-exporter=/usr/bin/prometheus-podman-exporter
pkg_name:    prometheus-podman-exporter
```
（這個專案還需要一串 CGO build 相依 `apt_build_deps`——因為表單沒有這格，這類目標**就該用 recipe**。）

### 範例 3：gvisor

gvisor 從源碼 build 需要 bazel（很重），建議用官方 release deb：

```
recipe: gvisor
```
（內部就是 `mode=url` 抓官方 `runsc.deb`。要從源碼 build 的設定在 `recipes/gvisor.env` 註解中。）

## Recipes（懶人包）

`recipes/*.env` 是「事先寫好的參數檔」，在 `build.sh` 解析表單前先被 `source`。
用途：把某個專案每次都要填的一堆參數存檔，讓表單只要填 `recipe` 名就好。

裡面就是一行行 `export 變數=值`，**包含表單沒有的進階旋鈕**：

```bash
export MODE="go"
export SOURCE_REPO="containers/prometheus-podman-exporter"
export BUILD_CMD="make binary"
export BIN_PATHS="bin/prometheus-podman-exporter=/usr/bin/prometheus-podman-exporter"
export APT_BUILD_DEPS="libbtrfs-dev libgpgme-dev libdevmapper-dev libsystemd-dev pkg-config gcc"  # ← 表單沒有，靠 recipe
export PKG_NAME="prometheus-podman-exporter"
# 還可設 SOURCE_REF / PKG_VERSION / GO_VERSION 等（這些都在容器內被 build.sh 讀到）
```

內附範例：

- `podman-exporter` — Go + CGO，一長串 build 相依的典型
- `gvisor` — 官方 deb（url 模式）
- `dbgsym-kernel` — 對應原本的 kernel dbgsym 用法

要新增自己的，複製一份 `.env` 改參數即可。**規則：臨時/簡單目標用表單；常用/參數多（尤其 CGO）用 recipe。**

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

- ddebs 的 dbgsym 副檔名常是 `.ddeb`。**保留原始副檔名**：`.ddeb` 就維持 `.ddeb`（內容同為
  Debian 套件，可照常 `dpkg -i` / `apt install`）。整條 pipeline（`build.sh` 產出檢查、
  `Dockerfile.image` 以 `COPY out/` 收整個目錄、`dpkg` 模式的 `find`）都同時收 `.deb` 與 `.ddeb`，
  不會漏掉，也不會改名。
- `go` 模式預設從 go.dev 下載 toolchain；若 runner 有網路限制，把 `GO_VERSION` 設成 `system` 改用 apt 版。
- 本機測試：`MODE=url DEB_URLS=... OUTPUT_DIR=/tmp/out ./build.sh`
