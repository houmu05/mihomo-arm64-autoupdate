#!/bin/sh
# watch_crash.sh — 监控 mihomo 是否因"堆损坏(GC sweep found pointer to free object)"崩溃,
# 一旦检测到【新的】崩溃,自动把 OpenClash 主核心切换为备份核心并重启,保证代理可用。
# 由 crontab 每 1 分钟调用一次(2026-09-01 从 2 分钟改为 1 分钟)。
#
# 部署位置：路由器 /etc/openclash/watch_crash.sh
# 部署命令见 README 第 4.6 节。
#
# —— 职责边界(别搞混,这决定了轮询间隔该取多少)——
#   * 把崩掉的核心【拉起来】: 不是本脚本的活, OpenClash 自带的
#     /usr/share/openclash/openclash_watchdog.sh 在做, 它是 `sleep 60` 的循环。
#   * 本脚本的活是【止血】: 发现核心在反复崩, 就换成兜底核心, 避免"拉起→再崩"死循环。
#
#   所以恢复服务的最坏窗口由 OpenClash watchdog 的 60s 决定, 不由本脚本决定。
#   本脚本再快也快不过那 60s ⇒ 取 1 分钟正好对齐, 没必要更细(cron 也做不到亚分钟)。
#
# 修复记录:busybox 的 grep -c 在匹配数为 0 时仍输出 0 但退出码为 1,
#   导致 `grep -c ... || echo 0` 变成 "0\n0" 两行,数值比较失真而误触发切换。
#   改用 awk 计数:任何情况下都输出单个数字(0 代表无匹配),从根本上规避。
#
# ⚠️ 兜底核心必须是已验证的【传统 GC】构建, 否则"崩了切过去接着崩"。
#   本机当前兜底核心是 mihomo v1.19.30 / go1.25.14
#   (sha256 c83089c8ad12a31207c0c464b537d59b8c1d586a9bd885819a1968f400b78a85)。
#   曾用过 UPX 压缩的 7.6MB 二进制作兜底: 压缩后扫不到符号 ⇒ 无法验证 GC 模式, 已弃用。
#   验证方法: `./backup-mihomo.sh --check <文件>`。

LOG=/tmp/openclash.log
CORE=/etc/openclash/core/clash_meta
FALLBACK=/etc/openclash/core/meta-backup/clash_meta
FNSTATE=/tmp/openclash_core_state
FLLOG=/tmp/openclash_core_fallback.log

# 备份核心必须存在,否则无法兜底
[ -f "$FALLBACK" ] || { echo "$(date '+%F %T') ERROR: fallback core missing: $FALLBACK" >> "$FLLOG"; exit 0; }

# —— 崩溃计数:awk 保证单个数字(0 = 无) ——
CNT=$(awk '/found pointer to free object/{n++} END{print n+0}' "$LOG" 2>/dev/null)
CNT=$(printf '%s' "$CNT" | tr -dc '0-9'); [ -z "$CNT" ] && CNT=0

# —— 首轮(状态文件不存在):只记录当前计数作基线,不触发;避免把历史崩误判为新崩 ——
if [ ! -f "$FNSTATE" ]; then
    echo "$CNT" > "$FNSTATE"
    echo "$(date '+%F %T') baseline init cnt=$CNT" >> "$FLLOG"
    exit 0
fi

# —— 读取上次计数;更新状态 ——
PREV=$(cat "$FNSTATE" 2>/dev/null); PREV=$(printf '%s' "$PREV" | tr -dc '0-9'); [ -z "$PREV" ] && PREV=0
echo "$CNT" > "$FNSTATE"

# —— 没有新的崩溃,退出(注意:日志被 OpenClash 重启清空时 CNT 会变小,属正常,不得触发) ——
[ "$CNT" -le "$PREV" ] && exit 0

# —— 检测到新的崩溃 ——
echo "$(date '+%F %T') [detected] new crash cnt=$CNT (prev=$PREV)" >> "$FLLOG"
echo "$(date '+%F %T')   current core: $(readlink -f "$CORE" 2>/dev/null), size=$(ls -l "$CORE" 2>/dev/null | awk '{print $5}')" >> "$FLLOG"

# —— 若已切过备份,不再重复切,交由 OpenClash watchdog / 人工处理 ——
if [ -f /tmp/openclash_core_switched_to_fallback ]; then
    echo "$(date '+%F %T')   already on fallback; no auto switch (manual review needed)" >> "$FLLOG"
    exit 0
fi

# —— 执行切换 ——
echo "$(date '+%F %T') [fallback] switching core -> $FALLBACK" >> "$FLLOG"
if cp -f "$FALLBACK" "$CORE" 2>/dev/null; then
    chmod 755 "$CORE"
    : > /tmp/openclash_core_switched_to_fallback
    echo "$(date '+%F %T')   switched OK. restarting OpenClash..." >> "$FLLOG"
    if [ -x /etc/init.d/openclash ]; then
        /etc/init.d/openclash restart >> "$FLLOG" 2>&1
    else
        killall openclash 2>/dev/null
    fi
else
    echo "$(date '+%F %T')   ERROR: failed to copy fallback core" >> "$FLLOG"
fi
exit 0
