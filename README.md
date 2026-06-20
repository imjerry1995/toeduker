# toeduker — 通用 deb 打包 + 掃描用 image 產生器

把任意來源的 `.deb` 包進一個 minimal 的 Docker image，push 到 Docker Hub，
讓內部掃描器把 image 拉進去時順便掃這些 deb。

這是 `linux-dbgsym-crash` 的通用化版本：除了「直接放現成 deb」之外，
還能從 GitHub 原始碼自動 build 出 deb。

> 產出的 image 一律叫 **`<你的DockerHub帳號>/toeduker`**，tag 自動帶上產品名與時間
> （例：`你的帳號/toeduker:hello-20260620-1530`）。不需要、也不能在表單自訂 image 名稱。

## 支援的四種模式（MODE）

| MODE  | 適用情境 | 必填 inputs |
|-------|----------|-------------|
| `url`  | 已有現成 `.deb` 連結（如 ddebs.ubuntu.com、官方 release） | `deb_urls` |
| `dpkg` | repo 本身就有 `debian/` 打包規則 | `source_repo` |
| `fpm`  | 一般專案，build 後用 fpm 把產物打成 deb | `source_repo`, `bin_paths`（通常還有 `build_cmd`） |
| `go`   | Go 專案（含 CGO/Bazel），自動裝 Go toolchain 再打包 | `source_repo`, `bin_paths` |

## 怎麼用

到 Actions → **build-deb-and-push** → **Run workflow**，填表單即可。**只有一種操作方式：表單。**

> **90% 的情況：選 `mode`、填 `deb_urls`（url 模式）或 `source_repo`（其它模式）就好，其餘留空。**
> 表單共 9 個欄位，每個 description 都標了適用模式（如 `【url】`、`【fpm/go】`）——不是你那個模式的就留白。
> 預設 `push: false`，所以**不設任何憑證也能直接跑**，只做 build 驗證、產出 deb 與 image。

### 先決定 `mode`（怎麼看原始 repo 該用哪個）

| 你的來源長怎樣 | 選 |
|------|------|
| 已經有現成的 `.deb`/`.ddeb` 下載連結 | **`url`** |
| repo 裡有 `debian/` 目錄（自帶 Debian 打包規則） | **`dpkg`** |
| Go 專案（有 `go.mod`） | **`go`** |
| 其它語言／要自己下指令編譯，再把產物打包成 deb | **`fpm`** |

判斷方式：到該 GitHub repo 首頁看一眼——**有 `debian/` 資料夾 → dpkg**；**有 `go.mod` → go**；
都沒有但你知道怎麼 build → fpm；根本不用 build、已有 deb 連結 → url。

### 表單欄位一覽（共 9 個）

| 欄位 | 適用 | 說明 |
|------|------|------|
| `mode` | 全部 | `url` / `dpkg` / `fpm` / `go`，見上表 |
| `source_repo` | dpkg/fpm/go | `owner/name`，要指定分支/tag 寫 `owner/name@v1.2` |
| `deb_urls` | url | 現成 `.deb`/`.ddeb` 連結，逗號或換行分隔 |
| `build_cmd` | fpm/go | build 指令，例如 `make binary` 或 `go build -o app .` |
| `bin_paths` | fpm/go | 產物 `src=dest`，例如 `bin/app=/usr/bin/app` |
| `apt_build_deps` | 進階 | 額外 apt build 相依（空白分隔）。CGO 專案常需要，多半留空 |
| `pkg_name` | fpm/go | 套件名稱，預設取 repo 名 |
| `go_version` | 進階(go) | 指定 Go 版本（如 `1.25.0`）；專案 `go.mod` 需要較新版時才填，多半留空 |
| `push` | 全部 | 是否推到 Docker Hub（**預設 false**＝只 build 不推；要推見下節） |

**Image tag 不開放客製**：固定自動命名為 `<DockerHub帳號>/toeduker:<產品名>-<時間>`，
產品名取自產出的套件檔名（例：`hello_2.10_amd64.deb`→`hello`、`runsc.deb`→`runsc`）。
`ubuntu_version`（base image 版本）也不放表單，固定 `24.04`；要改就改 `Dockerfile.builder` 與
`Dockerfile.image` 的 `ARG UBUNTU_VERSION=` 預設。

## 憑證與同事使用（重要）

push 到 Docker Hub 需要 `DOCKERHUB_USERNAME` 與 `DOCKERHUB_TOKEN`。
**這兩個一律走各自 repo 的 Secrets，不開放在表單填**——因為 `workflow_dispatch` 的 input 值
會顯示在那次 run 的頁面上，等於把 token 公開給所有看得到 Actions 的人（包含 repo owner）。

正確用法依情境：

- **只想驗 / 不推**：直接用本 repo 跑，`push` 留 `false`。不需要任何憑證。
- **要 push 且憑證要保密（同事各推各的）**：請同事**各自 fork 一份**，在自己 fork 的
  Settings → Secrets and variables → Actions 設自己的 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`，
  在自己的 fork 跑。各自加密、互不可見、owner 也看不到——這是 GitHub 上唯一能做到憑證隔離的方式。
- workflow 已內建保護：`push=true` 但該 repo 沒設 Secrets 時會**提早失敗並提示**，不會半途出錯；
  帳號也會被登記成 log 遮罩。

### 範例 1：放現成的 dbgsym deb（原本的用法）

```
mode:     url
deb_urls: http://ddebs.ubuntu.com/pool/main/l/linux-hwe-6.17/linux-image-...-dbgsym_..._amd64.ddeb
```
產出 image 會自動命名為 `<你的DockerHub帳號>/toeduker:linux-image-...-dbgsym-<時間>`。

### 範例 2：gvisor（用官方現成 deb）

gvisor 從源碼 build 需要 bazel（很重），用官方 release deb 最省事（url 模式）：

```
mode:     url
deb_urls: https://storage.googleapis.com/gvisor/releases/pool/20260608.0/binary-amd64/runsc.deb
```
換新版方法：讀 apt repo 的 Packages 索引取 `Filename`——
`curl -s https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-amd64/Packages`
（arm64 把兩處 `binary-amd64` 換成 `binary-arm64`）。

### 範例 3：從 Go + CGO 專案 build（prometheus-podman-exporter）

CGO 專案要靠 `apt_build_deps` 補系統 header：

```
mode:           go
source_repo:    containers/prometheus-podman-exporter   # 要釘版本：...@v1.4.0
build_cmd:      make binary
bin_paths:      bin/prometheus-podman-exporter=/usr/bin/prometheus-podman-exporter
apt_build_deps: libbtrfs-dev libgpgme-dev libdevmapper-dev libsystemd-dev pkg-config gcc
pkg_name:       prometheus-podman-exporter
```

### 範例 4：純 Go 工具（vegeta）

```
mode:        go
source_repo: tsenart/vegeta
build_cmd:   go build -o vegeta .
bin_paths:   vegeta=/usr/bin/vegeta
pkg_name:    vegeta
```
（若專案 `go.mod` 要求的 Go 版本比預設新，補填 `go_version`，例如 yq 要 `go_version: 1.25.0`。）

## 架構

```
build.sh              # 進入點，依 MODE 分派
builders/
  build_url.sh        # 下載現成 deb
  build_dpkg.sh       # dpkg-buildpackage
  build_fpm.sh        # build 後 fpm 打包
  build_go.sh         # Go toolchain + build + fpm 打包
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
