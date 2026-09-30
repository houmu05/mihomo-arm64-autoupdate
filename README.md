# mihomo ARM64 稳定内核:自动编译 / 自动更新 / 崩溃兜底

面向 **OpenClash + OpenWrt / ImmortalWrt(ARM64)** 的一套脚本:自己编译 mihomo 内核,编完直接校验产物,按周自动升级,内核崩了自动切兜底核心。

它只解决一个问题:

> **官方 mihomo arm64 release 用新一代 Go 的默认 GC(Green Tea)构建,在部分 ARM64 路由器上会破坏 Go 堆,导致内核随机崩溃。** 必须换成传统 GC 的构建,并且防住"又被官方产物覆盖回去"。

---

## 1. 为什么需要这套东西

### 1.1 症状

mihomo 内核在路由器上随机崩溃,间隔 44~215 分钟不等,runtime 报:

```
found pointer to free object
```

`found pointer to free object` 是 Go runtime 的 GC 断言:扫描堆时拿到一个**指向已释放对象**的指针,即堆已损坏。它不是"配置错误",改配置治不好。

### 1.2 根因

Go 的 **Green Tea GC**(go1.25 起可通过 `GOEXPERIMENT=greenteagc` 启用,go1.26 起默认启用)在该机器(ARMv8 rev4 / Cortex-A53)上会破坏堆;传统 mark-sweep GC 稳定。

**决定稳不稳的变量是「用哪种 GC 编译的」,不是 mihomo 的版本号。** 这一点是本项目的全部立足点。

### 1.3 为什么不能直接用官方 release

- 官方 arm64 release 由新版 Go 默认构建,即 Green Tea 构建。
- OpenClash 的 LuCI 界面里有「更新内核」按钮,它拉的就是官方 release。

⇒ **不要用 OpenClash 自带的内核更新。** 一旦它把 `clash_meta` 换成官方产物,崩溃就会回来。升级只能走本仓库的 `build-mihomo.sh`。

### 1.4 那为什么还要"自动"更新

1. 上游有新版本和修复,手工"下载源码 → 编译 → 校验 → 上传 → 重启 → 验证"很容易忘,也容易漏步骤。
2. 更实际的原因:**手工流程漏掉校验这一步,就会把没法验证 GC 模式的二进制推上去**(见 `docs/root-cause.md` 里那次真实的翻车)。
3. 所以把"比对版本 → 编译 → 出厂检查 → 远端口径校验 → 替换 → 健康检查"整条链路脚本化,每周跑一次,人工只负责看结果。

---

## 2. 方案

```
   ┌─ Windows 计划任务(每周日 03:00),在 WSL 里执行 ─┐
   │                                                │
   ▼                                                │
auto-update-mihomo.sh                               │
   │  ① 读上游最新稳定 tag(vX.Y.Z)                   │
   │  ② ssh 读路由器当前核心版本  ← 读不到就安全退出   │
   │  ③ 已是最新? → 结束                             │
   │  ④ 调 build-mihomo.sh 编译 + 出厂检查            │
   └─► build-mihomo.sh                               │
          · 锁最新 tag / 指定 tag                     │
          · 解析 go 工具链(默认 go1.25.14)            │
          · go1.26+ 时自动加 GOEXPERIMENT=nogreenteagc│
          · 产物名带 go 版本(它才是关键变量)          │
          · 出厂检查:扫二进制里有无 Green Tea 符号    │
            有 → 删除产物并报错退出(绝不部署)         │
   ┌────────────────────────────────────────────────┘
   │  ⑤ 找到本次 tag 的产物,算 sha256
   │  ⑥ scp 到路由器 /tmp(先不进正式路径)
   │  ⑦ 远端二次校验:sha256 一致 + 远端跑 -v 版本一致
   │  ⑧ 备份旧核心 → 替换 → 重启 OpenClash
   │  ⑨ sleep 60 后打 OpenClash API 做健康检查
   ▼
路由器
   · /etc/openclash/core/clash_meta           主核心(传统 GC)
   · /etc/openclash/core/meta-backup/clash_meta 兜底核心(同样已验证)
   · /etc/openclash/watch_crash.sh  cron 每 1 分钟
        检出【新增】的 "found pointer to free object" → 切兜底核心(只切一次)
```

两层保护的分工要说清楚,别搞混:

| 层 | 谁在做 | 周期 | 职责 |
|---|---|---|---|
| 拉起崩掉的核心 | OpenClash 自带 `openclash_watchdog.sh` | `sleep 60` 循环 | 核心死了重新拉起。**恢复服务的最坏窗口由它决定** |
| 换掉会崩的核心 | `watch_crash.sh` | cron 每 1 分钟 | 数到新增崩溃就切兜底核心,避免"拉起→再崩"死循环 |

为什么不把 `watch_crash.sh` 做到 30 秒:恢复服务的瓶颈是 OpenClash watchdog 的 60 秒循环,监控再快也快不过它;1 分钟正好对齐(而且 cron 本来也做不到亚分钟)。

---

## 3. 文件清单

| 文件 | 部署位置 | 作用 |
|---|---|---|
| `build-mihomo.sh` | 构建机(WSL) | 一键编译 + **出厂检查**(架构、buildinfo、Green Tea 符号) |
| `auto-update-mihomo.sh` | 构建机(WSL) | 自动更新主流程:比对版本、构建、上传、远端校验、替换、健康检查 |
| `backup-mihomo.sh` | 构建机(WSL) | `--audit` 扫 `bin/` 全部产物,一眼揪出 Green Tea 冒牌货;`--check` 单文件校验 |
| `watch_crash.sh` | 路由器 `/etc/openclash/watch_crash.sh` | cron 每 1 分钟:检出新增崩溃就切兜底核心 |
| `register-mihomo-task.ps1` | Windows | 注册(或重建)每周计划任务 |
| `install-mihomo-task.cmd` | Windows | 双击入口,转调上面的 ps1 |
| `docs/root-cause.md` | — | 根因分析 + 两次误判的完整复盘(值得读) |

---

## 4. 快速开始

### 4.1 准备

```sh
# 构建机需要:go(任意 1.21+,脚本会按需下载指定工具链)、git、ssh/scp、sha256sum
# mihomo 内核源码:注意 main 分支不是内核源码(是无关注入内容),必须用 vX.Y.Z tag 或 Meta/Alpha 分支
git clone --depth 1 --branch v1.19.32 https://github.com/MetaCubeX/mihomo.git source

# 目录布局(脚本按自身位置推导默认路径,整个目录可以随意搬):
#   <repo>/
#     ├── build-mihomo.sh  auto-update-mihomo.sh  backup-mihomo.sh
#     ├── source/   ← mihomo 内核源码
#     ├── bin/      ← 产物
#     └── logs/     ← 运行日志
```

### 4.2 编译

```sh
./build-mihomo.sh                       # 默认:自动拉最新稳定 tag,用 go1.25.14 编译
./build-mihomo.sh --tag v1.19.31        # 指定版本
GO_VERSION=go1.26.5 MIHOMO_VERSION=v1.19.30 ./build-mihomo.sh   # A/B 实验:go1.26.5 + 真 nogreenteagc
```

### 4.3 审计与校验

```sh
./backup-mihomo.sh --audit                                  # 扫 bin/ 下所有产物
./backup-mihomo.sh --check bin/mihomo-linux-arm64-v1.19.32-go1.25.14
```

### 4.4 部署(建议先干跑)

```sh
export MIHOMO_ROUTER=root@192.168.1.1     # 你的路由器地址
export MIHOMO_SSH_KEY=$HOME/.ssh/router_key

MIHOMO_UPLOAD_ONLY=1 ./auto-update-mihomo.sh   # 只上传到 /tmp,不动正式核心
./auto-update-mihomo.sh                        # 正式部署
```

### 4.5 Windows 侧定时

```bat
:: 以管理员以外的当前用户运行即可(计划任务默认按当前用户注册)
install-mihomo-task.cmd F:\mihomo\auto-update-mihomo.sh Debian
```

或在 PowerShell 里直接调用(参数更清楚):

```powershell
.\register-mihomo-task.ps1 -ScriptPath F:\mihomo\auto-update-mihomo.sh -Distro Debian -DayOfWeek Sunday -At 3:00AM
```

### 4.6 路由器侧兜底(一次性)

```sh
# 1) 放兜底核心(必须同样是已验证的传统 GC 构建)
ssh router 'mkdir -p /etc/openclash/core/meta-backup'
ssh router 'cat > /etc/openclash/core/meta-backup/clash_meta' < bin/mihomo-linux-arm64-v1.19.32-go1.25.14
ssh router 'chmod 755 /etc/openclash/core/meta-backup/clash_meta'

# 2) 放监控脚本
ssh router 'cat > /etc/openclash/watch_crash.sh' < watch_crash.sh
ssh router 'chmod 755 /etc/openclash/watch_crash.sh'

# 3) 每 1 分钟跑一次
ssh router "echo '* * * * * /etc/openclash/watch_crash.sh' >> /etc/crontabs/root && /etc/init.d/cron restart"
```

> 注意:装完先删掉 `/tmp/openclash_core_switched_to_fallback` 和 `/tmp/openclash_core_state`,让计数基线重建。

---

## 5. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `MIHOMO_ROUTER` | `root@192.168.1.1` | 路由器 SSH 目标 |
| `MIHOMO_SSH_KEY` | `$HOME/.ssh/router_key` | SSH 私钥 |
| `MIHOMO_SOURCE_DIR` | `<repo>/source` | mihomo 内核源码目录 |
| `MIHOMO_OUTPUT_DIR` | `<repo>/bin` | 产物输出目录(**三个脚本必须指向同一个**) |
| `MIHOMO_VERSION` | 由 git 推导 | 显式指定版本号(无 git 环境必填) |
| `MIHOMO_FORCE_BUILD` | `0` | `1` = 版本相同也强制重建 |
| `MIHOMO_UPLOAD_ONLY` | `0` | `1` = 只上传到路由器的 `/tmp`,不替换核心 |
| `GO_VERSION` | `go1.25.14` | go 工具链版本,**这是决定稳不稳的关键变量** |
| `GO` | — | 直接指定 go 可执行文件(优先于 `GO_VERSION`) |
| `GO_TAGS` | `with_gvisor` | 构建 tag。**别往这里塞 `nogreenteagc`,它是 GOEXPERIMENT 不是 build tag** |

---

## 6. 验证:只认两条

**不要相信命令行参数,只相信产物。** 唯一可信的验证是下面这两条同时成立:

```sh
# ① buildinfo 里必须出现 -X:nogreenteagc(go1.26+ 构建时)
go version -m bin/mihomo-linux-arm64-v1.19.32-go1.26.5 | head -1
#   → go1.26.5-X:nogreenteagc   (go1.25.x 天然传统 GC,不带这个后缀)

# ② 二进制里 Green Tea 专属 runtime 符号数必须为 0
grep -ac spanInlineMarkBits bin/mihomo-linux-arm64-v1.19.32-go1.26.5
#   → 0
```

`build-mihomo.sh` 已把 ② 做成出厂检查(不通过就删产物并退出),`backup-mihomo.sh --audit` 可以随时复检整个 `bin/`。

**别用 `grep -q 'nogreenteagc'` 当断言** —— 它匹配的是 buildinfo 字符串,会被无效参数骗过去(这正是历史上那次翻车的直接原因)。

---

## 7. 踩坑清单(会再踩)

1. **`MetaCubeX/mihomo` 的 `main` 分支不是内核源码**——是无关注入的 Python 项目。必须用 tags(`vX.Y.Z`)或 `Meta`/`Alpha` 分支。
2. **`nogreenteagc` 是 GOEXPERIMENT,不是 build tag。** 写进 `-tags` 静默无效,编出来照样是 Green Tea。必须 `GOEXPERIMENT=nogreenteagc go build`。
3. **同一个 commit 可能同时挂 `vX.Y.Z` 和滚动 tag `Prerelease-Alpha`**(实测 v1.19.31 与 `Prerelease-Alpha` 指向同一 commit)。裸 `git describe --tags` 会返回 `Prerelease-Alpha`,导致产物名、内嵌版本号全错,自动更新按 `vX.Y.Z` 找不到产物。取版本必须 `git describe --tags --match 'v[0-9]*'`。
4. **ldflags 的 `BuildTime` 值不能含空格**:`date -u` 默认带空格,linker 会按空格拆分前一个字段导致编译失败。用无空格格式 + 给每个 `-X` 值加引号。
5. **工具链别写死绝对路径**:被 WSL 重建搞废过一次。现在走 `GOTOOLCHAIN` 下载到 module cache,再直接调用缓存里的 go。
6. **go1.24.4 的 `cmd/go` 转交给 go1.26.5 时会 panic**(`cmd/go/internal/fips140.Init` nil deref)。脚本已绕开转交这一步。
7. **精简环境没有 `file` / `git`**:脚本直接读 ELF 头判架构(`e_machine==0xb7`),git 变为可选(用 `MIHOMO_VERSION` 指定版本)。
8. **`grep -c` 零匹配时既输出 `0` 又返回 1**,`grep -c ... || echo 0` 会得到 `"0\n0"` → 数值比较报 `Illegal number`,甚至误触发核心切换。统一用「捕获后 `tr -dc '0-9'` 清洗」或 `awk` 计数。
9. **UPX 压缩过的二进制扫不到符号**:压缩后无法判断 GC 模式。**别把"扫不到"当成"没有"**——兜底核心必须是未压缩的、已验证的构建。
10. **`scp` 在只有 dropbear 的 OpenWrt 上不可用**(没有 sftp-server)。传文件用 `ssh router 'cat > /目标路径' < 本地文件`;`auto-update-mihomo.sh` 里的 `scp -O` 需要目标机有 sftp-server 或改用同款 `cat` 写法。

---

## 8. 关于本仓库的敏感性说明

本仓库是从私有运维环境中**清理后**导出的,已剔除:

- 内网地址、主机名、SSH 私钥与密钥文件路径;
- 代理订阅、节点信息(VLESS / Reality / XHTTP 参数、SNI、path、short-id、UUID);
- WebDAV / FRP / aria2 RPC 等服务的地址与 token;
- 运行日志、编译产物、上游 mihomo 源码克隆。

脚本里的路由器地址、SSH 私钥路径、目录位置全部改成环境变量 + 通用默认值(`root@192.168.1.1`、`~/.ssh/router_key`、脚本同级目录),请按自己的环境覆盖。

---

## 9. 许可与致谢

- 本仓库的**脚本和文档**:MIT(见 `LICENSE`)。
- [mihomo](https://github.com/MetaCubeX/mihomo) 本身是 **GPL-3.0**。本仓库不包含、也不分发 mihomo 源码或二进制;它只是"按你的环境编译上游源码"的脚本。你用这些脚本编译并分发的二进制,需要遵守上游的 GPL-3.0。
- 根因与验证方法来自本机的实测和一次真实的误判复盘,不是通用结论:如果你的机器没有这个 GC 问题,这套东西对你只是"可复现的自编译流水线"。
