#!/bin/sh
# backup-mihomo.sh — mihomo 内核产物「校验 / 编译→备份」一站式脚本（随时调用）
#
# 用法：
#   ./backup-mihomo.sh                   默认：校验已知备份（sha256 + 语义断言）
#   ./backup-mihomo.sh --check <文件>     校验指定文件（sha256 + 语义断言）
#   ./backup-mihomo.sh --audit            扫描 bin/ 下全部产物，揪出 Green Tea 冒牌货
#   ./backup-mihomo.sh --rebuild          用当前源码重编译 → 备份为带版本新文件 → 校验
#   ./backup-mihomo.sh --tag v1.19.30     切到指定 tag 编译 → 备份 → 校验（升级用）
#   ./backup-mihomo.sh --branch Meta      切到 Meta 分支编译 → 备份 → 校验
#
# 环境：GO 可覆盖（默认系统 go）。语义断言依赖 `go version -m`，需已装 Go。

set -e
cd "$(dirname "$0")"

GO_BIN="${GO:-go}"
BIN_DIR=bin

# 已知备份（arm64 + go1.25.14 传统 GC，实测稳定）
KNOWN="mihomo-linux-arm64-v1.19.30-go1.25.14"
KNOWN_SHA=""   # 留空则跳过完整性比对，只做语义断言；确认产物后可手填一次锁死

# Green Tea GC 专属 runtime 符号：真正禁用后二进制里应为 0 个
GREENTEA_SYM="spanInlineMarkBits"

# 统计二进制里 Green Tea 符号出现次数，保证输出单个数字。
# ⚠️ 不能写成 `grep -ac X f || echo 0`：grep -c 在 0 匹配时**既输出 "0" 又返回 1**，
#    `|| echo 0` 会再补一个 0 → "0\n0" → 数值比较报 Illegal number。
#    （watch_crash.sh 里踩过同一个坑，见其头部注释。）
greentea_count() {
    _n=$(grep -ac "$GREENTEA_SYM" "$1" 2>/dev/null || true)
    _n=$(printf '%s' "$_n" | head -1 | tr -dc '0-9')
    [ -n "$_n" ] || _n=0
    printf '%s' "$_n"
}

# ---------- 语义断言：架构 / 真·传统 GC / 平台 ----------
# ⚠️ 历史 bug（2026-08-27，2026-09-01 修正）：
#    这里原本用 `grep -q 'nogreenteagc'` 判断是否禁用了 Green Tea。
#    但 build-mihomo.sh 当时是把 nogreenteagc 塞进 `-tags`（无效，它是 GOEXPERIMENT），
#    buildinfo 里就有 `-tags=nogreenteagc,...` 这行 → 断言**假通过**，
#    实际编出来的是 Green Tea 二进制，被冠以 "-nogreentea" 名字部署上去，然后崩。
#    现在改为直接检查二进制里有无 Green Tea 专属符号——验证产物，而不是验证参数。
assert_semantics() {
    BIN="$1"
    [ -f "$BIN" ] || { echo "  错误：不存在 $BIN"; return 1; }

    ARCH=$(elf_arch "$BIN")
    echo "  [架构]   $ARCH"
    [ "$ARCH" = "aarch64" ] || { echo "  错误：非 arm64（$ARCH）"; return 1; }

    INFO=$("$GO_BIN" version -m "$BIN" 2>/dev/null) || { echo "  错误：无法读 build info"; return 1; }
    echo "$INFO" | grep -q 'GOARCH=arm64' || { echo "  错误：GOARCH 非 arm64"; return 1; }

    GT=$(greentea_count "$BIN")
    if [ "$GT" -gt 0 ]; then
        echo "  错误：检出 Green Tea GC 符号（$GREENTEA_SYM ×$GT）——未禁用 Green Tea，此产物会崩"
        return 1
    fi
    echo "  [GC]     传统 GC ✅（无 $GREENTEA_SYM 符号）"

    echo "  [tag]    $(echo "$INFO" | grep -oE 'tags=[^ ]+' | head -1)"
    echo "  [commit] $(echo "$INFO" | grep -oE 'vcs.revision=[0-9a-f]+' | head -1)"
    echo "  [go]     $(echo "$INFO" | head -1)"
    echo "  语义断言通过 ✅"
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# 读 ELF 头判架构，不依赖 `file`（精简环境 / OpenWrt busybox 常没装）。
# ELF: 魔数 \x7fELF 在偏移 0；e_machine 在偏移 18（小端 2 字节），AArch64 = 0x00b7。
elf_arch() {
    _magic=$(od -An -tx1 -j1 -N3 "$1" 2>/dev/null | tr -d ' \n')
    [ "$_magic" = "454c46" ] || { echo "not-an-elf"; return; }
    _m=$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')
    case "$_m" in
        b700) echo "aarch64" ;;
        3e00) echo "x86-64" ;;
        2800) echo "arm" ;;
        "")   echo "unknown" ;;
        *)    echo "machine=0x$_m" ;;
    esac
}

# ---------- 编译 + 备份为新版本 ----------
make_and_backup() {
    echo "== 编译（沿用 build-mihomo.sh，含出厂检查）=="
    ./build-mihomo.sh "$@"
    # build-mihomo.sh 产物名为 mihomo-linux-arm64-<ver>-go<X.Y.Z>，取最新的一个
    BIN=$(ls -t "$BIN_DIR"/mihomo-linux-arm64-*-go1.* 2>/dev/null | head -n1)
    [ -n "$BIN" ] || { echo "错误：未找到编译产物 ${BIN_DIR}/mihomo-linux-arm64-*-go1.*"; exit 1; }
    echo "== 产物：$BIN"
    echo "  sha256: $(sha_of "$BIN")"
    echo "== 语义断言"
    assert_semantics "$BIN"
    echo "== 完成。以后用 \`./backup-mihomo.sh --check '$BIN'\` 可随时复检"
}

# ---------- 校验单个文件 ----------
check() {
    FILE="$1"
    [ -f "$FILE" ] || { echo "错误：不存在 $FILE"; exit 1; }
    echo "== 校验 $FILE"
    echo "  [sha256] $(sha_of "$FILE")"
    if [ "$FILE" = "$BIN_DIR/$KNOWN" ] && [ -n "$KNOWN_SHA" ]; then
        echo "  [期望]   $KNOWN_SHA"
        if [ "$(sha_of "$FILE")" = "$KNOWN_SHA" ]; then
            echo "  完整性 OK ✅"
        else
            echo "  完整性不匹配 ❌"
            exit 1
        fi
    fi
    assert_semantics "$FILE"
}

# ---------- 扫描 bin/ 下所有产物，揪出 Green Tea 冒牌货 ----------
audit() {
    echo "== 审计 $BIN_DIR/ 下所有产物"
    RC=0
    for f in "$BIN_DIR"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.sha256|*.meta|*.txt|*.md) continue;; esac
        [ "$(elf_arch "$f")" = "not-an-elf" ] && continue
        GT=$(greentea_count "$f")
        GOV=$("$GO_BIN" version -m "$f" 2>/dev/null | head -1 | awk '{print $2}')
        if [ "$GT" -gt 0 ]; then
            echo "  ❌ $(basename "$f")  [$GOV]  Green Tea GC —— 会崩，勿部署"
            RC=1
        else
            echo "  ✅ $(basename "$f")  [$GOV]  传统 GC"
        fi
    done
    return $RC
}

# ---------- 参数分发 ----------
if [ $# -eq 0 ]; then
    check "$BIN_DIR/$KNOWN"
    exit 0
fi

case "$1" in
    --check)    shift; check "$@";;
    --audit)    audit;;
    --rebuild)  make_and_backup;;
    --tag|--branch) make_and_backup "$@";;
    *) echo "用法: $0 [--check [文件] | --audit | --rebuild | --tag vX.Y.Z | --branch Meta]"; exit 2;;
esac
