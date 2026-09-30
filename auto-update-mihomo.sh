#!/bin/sh
# auto-update-mihomo.sh — 每周检查 mihomo 稳定版 tag；有更新时调用 build-mihomo.sh
# 构建并安全部署到路由器。
#
# 设计原则：**任何一步拿不到可信输入（版本号、产物、远端校验）就安全退出**。
#           宁可这周不更新，也绝不"猜测式部署"——把会崩的内核推上去的代价远大于晚一周。
#
# 环境变量：见 README 第 5 节。常用：
#   MIHOMO_ROUTER=root@192.168.1.1     MIHOMO_SSH_KEY=~/.ssh/router_key
#   MIHOMO_UPLOAD_ONLY=1   干跑（只上传到 /tmp，不动正式核心）
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="${MIHOMO_SOURCE_DIR:-$SCRIPT_DIR/source}"
BUILD_SCRIPT="$SCRIPT_DIR/build-mihomo.sh"
LOG_DIR="$SCRIPT_DIR/logs"
LOCK_DIR="${TMPDIR:-/tmp}/mihomo-auto-update.lock"
ROUTER="${MIHOMO_ROUTER:-root@192.168.1.1}"
SSH_KEY="${MIHOMO_SSH_KEY:-$HOME/.ssh/router_key}"
SSH_OPTS="-i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
REMOTE="/tmp/mihomo-new"
CORE="/etc/openclash/core/clash_meta"

mkdir "$LOCK_DIR" 2>/dev/null || {
    echo "已有 mihomo 自动更新任务运行，退出。"
    exit 0
}
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/auto-update-$(date +%Y%m%d).log"
exec >>"$LOG_FILE" 2>&1

[ -d "$SOURCE_DIR" ] || { echo "源码目录不存在：$SOURCE_DIR"; exit 1; }
cd "$SOURCE_DIR"

echo "===== $(date -Is) mihomo 自动更新开始 ====="

# 只检查稳定版 vX.Y.Z，不纳入 alpha/beta/rc。
LATEST=$(git ls-remote --tags origin 2>/dev/null \
    | awk -F/ '{print $3}' \
    | grep -v '\^{}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1 || true)
[ -n "$LATEST" ] || { echo "无法取得 GitHub 最新稳定版 tag，安全退出。"; exit 1; }
echo "远程最新稳定版：$LATEST"

# 从路由器当前正在运行的核心读取版本；查询失败时绝不自动替换。
CURRENT=$(
    ssh $SSH_OPTS "$ROUTER" \
        "$CORE -v" 2>/dev/null \
        | sed -n '1s/.*[[:space:]]\(v[0-9][0-9.]*\).*/\1/p' \
        | head -1 || true
)
[ -n "$CURRENT" ] || { echo "无法读取路由器当前 mihomo 版本，安全退出。"; exit 1; }
echo "路由器当前版本：$CURRENT"

if [ "${MIHOMO_FORCE_BUILD:-0}" != "1" ] && [ "$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | sort -V | tail -1)" = "$CURRENT" ]; then
    echo "当前已是最新版本（或更新版本），无需构建和部署。"
    exit 0
fi

echo "检测到更新：$CURRENT -> $LATEST"
sh "$BUILD_SCRIPT"

# build-mihomo.sh 会切到最新 tag 并通过出厂检查；这里只选择本次 tag 的非隔离产物。
# ⚠️ 查找目录必须与 build-mihomo.sh 的 OUTPUT_DIR 完全一致（两者默认都是 <repo>/bin，
#    可用 MIHOMO_OUTPUT_DIR 同时覆盖）。曾写错成源码目录下的 bin/，
#    结果产物编好了也永远找不到。
BUILD_OUT_DIR="${MIHOMO_OUTPUT_DIR:-$SCRIPT_DIR/bin}"
OUT=$(find "$BUILD_OUT_DIR" -maxdepth 1 -type f \
    -name "mihomo-linux-arm64-${LATEST}-*" \
    ! -name 'QUARANTINE-*' \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-)
if [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
    echo "找不到 $LATEST 的有效构建产物，停止部署。"
    echo "  查找目录：$BUILD_OUT_DIR"
    echo "  该目录内实际存在的产物（末尾 10 个）："
    find "$BUILD_OUT_DIR" -maxdepth 1 -type f -name 'mihomo-*' -printf '    %f\n' 2>/dev/null | tail -10
    exit 1
fi
chmod 755 "$OUT"
SHA=$(sha256sum "$OUT" | awk '{print $1}')
echo "构建产物：$OUT"
echo "SHA256：$SHA"

# 先上传到临时路径，远端校验通过后才替换正式核心。
scp -O $SSH_OPTS "$OUT" "$ROUTER:$REMOTE"
if [ "${MIHOMO_UPLOAD_ONLY:-0}" = "1" ]; then
    echo "测试模式：已上传到 $ROUTER:$REMOTE，未替换核心、未重启 OpenClash。"
    exit 0
fi
ssh $SSH_OPTS "$ROUTER" sh -s "$SHA" "$LATEST" <<'DEPLOY'
set -eu
EXPECTED_SHA="$1"
EXPECTED_VERSION="$2"
REMOTE=/tmp/mihomo-new
CORE=/etc/openclash/core/clash_meta
BK="/etc/openclash/core/clash_meta.$(date +%Y%m%d_%H%M%S).bak"

# 远端二次校验：文件在、sha256 与本地一致、在路由器上真的能跑出预期版本号。
test -s "$REMOTE"
chmod 755 "$REMOTE"
ACTUAL_SHA=$(sha256sum "$REMOTE" | awk '{print $1}')
test "$ACTUAL_SHA" = "$EXPECTED_SHA"
VERSION=$($REMOTE -v | sed -n '1s/.*[[:space:]]\(v[0-9][0-9.]*\).*/\1/p')
test "$VERSION" = "$EXPECTED_VERSION"
test -x "$CORE"
cp "$CORE" "$BK"
test -s "$BK"
cp "$REMOTE" "$CORE"
chmod 755 "$CORE"
test "$($CORE -v | sed -n '1s/.*[[:space:]]\(v[0-9][0-9.]*\).*/\1/p')" = "$EXPECTED_VERSION"
uci set openclash.@openclash[0].enable='1'
uci commit openclash
/etc/init.d/openclash restart >/dev/null 2>&1
sleep 60
# 健康检查：OpenClash 的 API 必须回得出东西，回不出就说明这次部署没成。
# 注意：dashboard_password 从 uci 现读，不落盘、不写进脚本。
SECRET=$(uci get openclash.@openclash[0].dashboard_password)
API=$(curl -fsS --max-time 5 -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/version)
test -n "$API"
echo "部署成功：$API"
echo "旧核心备份：$BK"
DEPLOY

echo "===== $(date -Is) mihomo 自动更新完成 ====="
