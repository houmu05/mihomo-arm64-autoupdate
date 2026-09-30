#!/bin/sh
# build-mihomo.sh — 为 OpenClash 编译 mihomo 内核（linux/arm64，强制传统 GC）
#
# ============================ 根因与踩坑（必读） ============================
# 症状：路由器（ARMv8 rev4 / Cortex-A53）上 mihomo 随机崩溃，
#       runtime 报 "found pointer to free object"（GC 扫到堆损坏），44~215 分钟不等。
#
# 根因：Go 的 **Green Tea GC**（go1.25 起为可选实验，go1.26 起默认开启）在这台机器上
#       会破坏堆。传统 GC（mark-sweep）稳定。
#
# ⚠️ 曾经的误判（2026-08-27）：本脚本一度用 `-tags nogreenteagc` 来"关掉" Green Tea，
#    但 **nogreenteagc 是 GOEXPERIMENT，不是 build tag**——写进 -tags 完全无效，
#    编出来的仍是 Green Tea 二进制，却被命名成 "-nogreentea"。
#    于是得出了错误结论"go1.26 传统 GC 也崩"。实际上那次根本没关掉 Green Tea。
#    证据（2026-09-01 复核 bin/ 下三个产物）：
#      - go1.26.5 产物的 buildinfo 里**没有** `GOEXPERIMENT=nogreenteagc` 行
#        （实测 go1.26.5 只要真的设了该 GOEXPERIMENT，buildinfo 必定记录）
#      - go1.26.5 产物里含 Green Tea 专属 runtime 符号 `spanInlineMarkBits`
#        （真 nogreenteagc 构建里该符号数为 0）
#    结论：所有崩溃过的版本都是 Green Tea；所有稳定的版本都是传统 GC。
#
# 因此本脚本：
#   1) 用 GOEXPERIMENT（而非 -tags）关闭 Green Tea；
#   2) 编完**直接检查二进制**里有没有 Green Tea 符号，不信任任何命令行参数；
#   3) 产物名带上 go 工具链版本，杜绝"名字说是传统 GC、其实不是"。
# ==========================================================================
#
# 用法：
#   ./build-mihomo.sh                默认自动拉取最新 release tag 后编译（升级内核首选）
#   ./build-mihomo.sh --tag v1.19.30 切到指定 tag 后编译（指定某版）
#   ./build-mihomo.sh --branch Meta  切到 Meta 分支后编译
#
# 环境变量：
#   GO_VERSION      指定 go 工具链版本（默认 go1.25.14，已实测稳定）。
#                   通过 GOTOOLCHAIN 按需下载，不依赖本机预装某个绝对路径。
#   GO              直接指定 go 可执行文件路径（优先级高于 GO_VERSION）。
#   MIHOMO_VERSION  显式指定版本号（无 git 环境下必填，如 v1.19.30）。
#   MIHOMO_SOURCE_DIR  内核源码目录（默认：脚本同级 source/）。
#   MIHOMO_OUTPUT_DIR  产物目录（默认：脚本同级 bin/）。
#   GO_TAGS         覆盖默认 build tag（默认 "with_gvisor"）。
#                   ⚠️ 不要往这里塞 nogreenteagc，那是 GOEXPERIMENT，写这没用。
#
# 例：
#   ./build-mihomo.sh                                       # go1.25.14 编最新 tag（生产用）
#   GO_VERSION=go1.26.5 MIHOMO_VERSION=v1.19.30 ./build-mihomo.sh   # go1.26.5 + 真·nogreenteagc（A/B 用）
#
# ⚠️ 重要：MetaCubeX/mihomo 的 main 分支目前【不是内核源码】（是无关注入内容）。
#        必须用 --tag <vX.Y.Z> 或 --branch Meta 才能拿到 Go 内核！直接 checkout main 会编译失败。

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="${MIHOMO_SOURCE_DIR:-$SCRIPT_DIR/source}"
OUTPUT_DIR="${MIHOMO_OUTPUT_DIR:-$SCRIPT_DIR/bin}"
cd "$SOURCE_DIR"

TAGS="${GO_TAGS:-with_gvisor}"
TARGET="linux-arm64"
GO_VERSION="${GO_VERSION:-go1.25.14}"
AUTO=1   # 默认自动拉取最新 release tag；遇到 --tag/--branch 时关闭

# Green Tea GC 专属 runtime 符号：真正禁用后二进制里应为 0 个
GREENTEA_SYM="spanInlineMarkBits"

# git 是可选的：构建环境被重建过一次就没了 git，但源码已在盘上、版本号可用 MIHOMO_VERSION 指定。
# 没有 git 时只是不能自动切 tag，不该让整个编译不可用。
HAVE_GIT=0
command -v git >/dev/null 2>&1 && HAVE_GIT=1
if [ "$HAVE_GIT" = 0 ]; then
    echo "==> 提示：未找到 git，跳过 tag 切换/自动升级；版本号取 \$MIHOMO_VERSION（当前：${MIHOMO_VERSION:-未设置}）"
fi

# ---- 解析参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            AUTO=0
            shift
            [ -n "$1" ] || { echo "错误: --tag 后面要跟版本号"; exit 2; }
            [ "$HAVE_GIT" = 1 ] || { echo "错误：--tag 需要 git，但本机没有 git"; exit 1; }
            echo "==> 切到 tag $1（需网络）"
            git fetch --depth 1 origin tag "$1" >/dev/null 2>&1 || git fetch origin tag "$1" >/dev/null 2>&1
            git checkout -q "$1"
            shift ;;
        --branch)
            AUTO=0
            shift
            [ -n "$1" ] || { echo "错误: --branch 后面要跟分支名"; exit 2; }
            [ "$HAVE_GIT" = 1 ] || { echo "错误：--branch 需要 git，但本机没有 git"; exit 1; }
            echo "==> 切到分支 $1"
            git fetch --depth 1 origin "$1" >/dev/null 2>&1 || true
            git checkout -q "$1"
            shift ;;
        *)
            echo "未知参数: $1"; exit 2 ;;
    esac
done

# ---- 默认：自动拉取最新 release tag ----
# 不带 --tag/--branch 时，自动锁定远程最新稳定 tag 再编译，避免卡在旧版本。
if [ "$AUTO" = 1 ] && [ "$HAVE_GIT" = 1 ]; then
    echo "==> 自动检测最新 release tag（需联网）"
    LATEST=$(git ls-remote --tags origin 2>/dev/null \
        | awk -F'/' '{print $3}' | grep -v '\^{}' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    if [ -n "$LATEST" ]; then
        echo "==> 最新 release tag：$LATEST"
        git fetch --depth 1 origin tag "$LATEST" >/dev/null 2>&1 || git fetch origin tag "$LATEST" >/dev/null 2>&1
   git checkout -q -f "$LATEST" || { git reset -q --hard && git clean -qfd && git checkout -q "$LATEST"; } \
    || echo "警告：checkout $LATEST 失败，沿用当前源码"
    else
        echo "==> 未能联网获取最新 tag，沿用当前源码编译"
    fi
fi

# ---- 校验是 mihomo 内核源码 ----
[ -f go.mod ] || {
    echo "错误：当前目录不是 mihomo 内核源码（缺 go.mod）。"
    echo "  main 分支不是内核，请用 --tag/--branch 切到内核源码。"
    exit 1
}

# ---- 探测 go 工具链 ----
# 目标：把 $GO_VERSION 解析成一个**具体的 go 可执行文件**，而不是依赖 GOTOOLCHAIN 转交。
# 原因：go1.24.4 的 cmd/go 在转交给 go1.26.5 时会 panic
#       （cmd/go/internal/fips140.Init nil deref → SIGSEGV）。
#       先让它把工具链下载到 module cache，然后直接调用缓存里的 go，绕开转交这一步。
# 好处：也不再依赖 /opt/go1.25.14 这种会随环境重建而消失的绝对路径。
resolve_go() {
    if [ -n "$GO" ]; then
        echo "$GO"; return
    fi
    _host_go="$(command -v go 2>/dev/null || true)"
    [ -n "$_host_go" ] || {
        echo "错误：找不到 go。请装任意 go1.21+（会自动下载 $GO_VERSION），或用 GO=/path/to/go 指定。" >&2
        exit 1
    }
    # 已经是目标版本就直接用
    if [ "$(GOTOOLCHAIN=local "$_host_go" env GOVERSION 2>/dev/null)" = "$GO_VERSION" ]; then
        echo "$_host_go"; return
    fi
    _mc=$(GOTOOLCHAIN=local "$_host_go" env GOMODCACHE 2>/dev/null)
    _os=$(GOTOOLCHAIN=local "$_host_go" env GOHOSTOS 2>/dev/null)
    _ar=$(GOTOOLCHAIN=local "$_host_go" env GOHOSTARCH 2>/dev/null)
    _cached="$_mc/golang.org/toolchain@v0.0.1-$GO_VERSION.$_os-$_ar/bin/go"
    if [ ! -x "$_cached" ]; then
        echo "==> 下载工具链 $GO_VERSION（首次会慢）" >&2
        # 这一步只为触发下载；即便它自己 panic，工具链通常也已落盘
        GOTOOLCHAIN="$GO_VERSION" "$_host_go" version >/dev/null 2>&1 || true
    fi
    [ -x "$_cached" ] || {
        echo "错误：无法获得工具链 $GO_VERSION（期望 $_cached）。请检查网络或用 GO=/path/to/go 指定。" >&2
        exit 1
    }
    echo "$_cached"
}

GO_BIN="$(resolve_go)"

# 统一入口：所有 go 调用都走这里。GOTOOLCHAIN=local 防止再次触发转交。
run_go() { GOTOOLCHAIN=local "$GO_BIN" "$@"; }

GOVER=$(run_go env GOVERSION 2>/dev/null || true)
[ -n "$GOVER" ] || { echo "错误：无法获取 go 版本（工具链不可用？）"; exit 1; }
echo "==> go 工具链：$GOVER  ($GO_BIN)"

# ---- 决定是否需要 GOEXPERIMENT=nogreenteagc ----
# go1.25.x：Green Tea 默认关闭，天然传统 GC，不需要也不应该设（设了只是噪音）。
# go1.26+ ：Green Tea 默认开启，**必须**用 GOEXPERIMENT 关掉。
case "$GOVER" in
    go1.2[0-5]*) GOEXP="" ; echo "    → $GOVER 默认即传统 GC，无需 GOEXPERIMENT" ;;
    *)           GOEXP="nogreenteagc" ; echo "    → $GOVER 默认启用 Green Tea，强制 GOEXPERIMENT=nogreenteagc" ;;
esac

# ---- 版本（与 Makefile 逻辑一致）----
# MIHOMO_VERSION 显式指定时优先（无 git 环境下的唯一途径）
if [ -n "$MIHOMO_VERSION" ]; then
    VERSION="$MIHOMO_VERSION"
elif [ "$HAVE_GIT" = 1 ]; then
    BRANCH=$(git branch --show-current 2>/dev/null || true)
    case "$BRANCH" in
        Alpha) VERSION="alpha-$(git rev-parse --short HEAD)" ;;
        Beta)  VERSION="beta-$(git rev-parse --short HEAD)" ;;
        # ⚠️ 必须 --match 'v[0-9]*'：上游会把**同一个 commit 同时打上 `v1.19.31` 和滚动
        #    tag `Prerelease-Alpha`**（2026-09-15 实测 ab405ba 两 tag 并存）。裸 `git describe
        #    --tags` 会返回 Prerelease-Alpha → 产物名与内嵌 constant.Version 都变成
        #    "Prerelease-Alpha"，auto-update 按 vX.Y.Z 找不到产物，路由器端 -v 也解析不出
        #    版本号（下次运行会因读不到当前版本而永久安全退出）。
        #    限定只认 vX.Y.Z 才拿得到 v1.19.31；若无 v tag 则退回原行为。
        "")    VERSION=$(git describe --tags --match 'v[0-9]*' 2>/dev/null \
                   || git describe --tags 2>/dev/null \
                   || echo "dev-$(git rev-parse --short HEAD)") ;;
        *)     VERSION=$(git rev-parse --short HEAD) ;;
    esac
else
    echo "错误：无 git 且未设 MIHOMO_VERSION，无法确定版本号。"
    echo "  请用：MIHOMO_VERSION=v1.19.30 $0"
    exit 1
fi
BUILDTIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")   # 无空格，避免 -X 值被 linker 按空格拆分

# 产物命名：mihomo-<target>-<version>-<gover>
#   带上 go 工具链版本，因为「用哪个 go 编的」正是决定稳不稳的关键变量。
OUT="$OUTPUT_DIR/mihomo-${TARGET}-${VERSION}-${GOVER}"

echo "==> 编译 mihomo"
echo "    tags=${TAGS}   GOEXPERIMENT=${GOEXP:-<默认>}"
echo "    target=${TARGET}  version=${VERSION}"
echo "    out=${OUT}"

mkdir -p "$OUTPUT_DIR"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOEXPERIMENT="$GOEXP" \
    run_go build -trimpath -tags "$TAGS" \
    -ldflags "-X 'github.com/metacubex/mihomo/constant.Version=${VERSION}' \
              -X 'github.com/metacubex/mihomo/constant.BuildTime=${BUILDTIME}' \
              -w -s -buildid=" \
    -o "$OUT"

# ---- 出厂检查：不信参数，只信二进制 ----
echo "==> 出厂检查"
FAIL=0

# 读 ELF 头判架构，不依赖 `file`（精简环境 / OpenWrt busybox 常没装）。
# ELF: 魔数 \x7fELF 在偏移 0；e_machine 在偏移 18（小端 2 字节），AArch64 = 0x00b7。
ELF_MAGIC=$(od -An -tx1 -j1 -N3 "$OUT" 2>/dev/null | tr -d ' \n')
ELF_MACH=$(od -An -tx1 -j18 -N2 "$OUT" 2>/dev/null | tr -d ' \n')
if [ "$ELF_MAGIC" = "454c46" ] && [ "$ELF_MACH" = "b700" ]; then
    echo "    [架构] ELF aarch64 ✅"
else
    echo "    ❌ 不是 arm64 ELF（magic=$ELF_MAGIC machine=0x$ELF_MACH）"; FAIL=1
fi

INFO=$(run_go version -m "$OUT" 2>/dev/null || true)
echo "$INFO" | grep -q 'GOARCH=arm64' || { echo "    ❌ buildinfo GOARCH 非 arm64"; FAIL=1; }

# 关键断言：二进制里不能有 Green Tea 专属符号。
# 这是唯一可信的检查——它验证的是产物本身，而不是"我以为我传了什么参数"。
# ⚠️ 不能写成 `grep -ac X f || echo 0`：grep -c 在 0 匹配时既输出 "0" 又返回 1，
#    `|| echo 0` 会再补一个 0 → "0\n0" → 数值比较报 Illegal number。
GT=$(grep -ac "$GREENTEA_SYM" "$OUT" 2>/dev/null || true)
GT=$(printf '%s' "$GT" | head -1 | tr -dc '0-9'); [ -n "$GT" ] || GT=0
if [ "$GT" -gt 0 ]; then
    echo "    ❌ 检出 Green Tea GC 符号（$GREENTEA_SYM ×$GT）——未成功禁用，此产物会崩！"
    FAIL=1
else
    echo "    [GC]   传统 GC ✅（无 $GREENTEA_SYM 符号）"
fi

echo "    [go]   $(echo "$INFO" | head -1)"

if [ "$FAIL" -ne 0 ]; then
    echo "==> 出厂检查未通过，删除产物避免被误部署"
    rm -f "$OUT"
    exit 1
fi

echo "==> 完成：$OUT"
echo "    sha256: $(sha256sum "$OUT" 2>/dev/null | awk '{print $1}')"
ls -l "$OUT"
