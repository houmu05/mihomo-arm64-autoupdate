# 根因复盘:Green Tea GC 与两次误判

> 这份文档记录**一次真实的排障**,包括两次错误的中间结论。
> 它比脚本本身更值钱——因为翻车的不是水平,是**验证方法**:断言写在了参数上,而没写在产物上。

---

## 1. 症状

| 项 | 值 |
|---|---|
| 机器 | ARMv8 rev4 / Cortex-A53 路由器,ImmortalWrt + OpenClash |
| 现象 | mihomo 内核随机崩溃 |
| 崩溃间隔 | 44 ~ 215 分钟(无规律) |
| runtime 报错 | `found pointer to free object` |
| 后果 | 代理断流;OpenClash watchdog 60 秒后拉起,拉起后可能再崩(死循环) |

`found pointer to free object` 是 Go runtime 的 GC 断言:堆扫描时遇到**指向已释放对象的指针**,意味着堆已经被破坏。这类问题不是配置问题——改 DNS、改规则、改并发都治不好。

---

## 2. 正确的根因

**Go 的 Green Tea GC 在该 CPU 上会破坏堆;传统 mark-sweep GC 稳定。**

- Green Tea GC 在 go1.25 是可选实验特性(`GOEXPERIMENT=greenteagc`),go1.26 起默认启用。
- 官方 mihomo arm64 release 由新版 Go 默认构建 ⇒ 官方产物是 Green Tea 构建 ⇒ 部署上去就会崩。
- OpenClash 的 LuCI「更新内核」拉的就是官方 release ⇒ **它是复发的直接来源**。

⇒ **关键变量是「用哪种 GC 编译」,不是「mihomo 版本号」。**
产物名里必须带 go 版本(`mihomo-linux-arm64-v1.19.30-go1.25.14`),否则下次谁也说不清"这个二进制到底是什么 GC"。

---

## 3. 两次误判(以及它们为什么会发生)

### 3.1 第一次:以为写 `-tags nogreenteagc` 就关掉了

当时的做法是在构建命令里加 `-tags nogreenteagc`。

**但 `nogreenteagc` 是 GOEXPERIMENT,不是 build tag。** 写进 `-tags` 完全无效——构建成功、没有报错、没有任何提示,编出来的二进制仍然是 Green Tea,却被命名成 `-nogreentea` 并部署到路由器上。

⇒ 由此得出的结论"**go1.26 传统 GC 也崩**"是错的。那次实验根本没关掉 Green Tea。

### 3.2 第二次:断言本身也是错的

为了防止再犯,脚本里加了断言:

```sh
grep -q 'nogreenteagc' buildinfo   # ❌ 假通过
```

问题是:上一次的错误做法把 `nogreenteagc` 写进了 `-tags`,而 **buildinfo 里就会出现 `-tags=nogreenteagc,...` 这一行** —— 断言匹配到了自己伪造的痕迹,于是"验证通过"。

**两层保护(构建参数 + 事后断言)建立在同一个错误前提上,同时失效。**

### 3.3 复核证据(2026-09-01)

对 `bin/` 下三个产物逐一复核:

| 证据 | Green Tea 产物 | 真·nogreenteagc 产物 |
|---|---|---|
| buildinfo 里 `GOEXPERIMENT=nogreenteagc` 行 | **没有** | **有**(版本串变成 `go1.26.5-X:nogreenteagc`) |
| Green Tea 专属 runtime 符号 `spanInlineMarkBits` 计数 | > 0 | **0** |

结论:**所有崩过的版本都是 Green Tea;所有稳过的版本都是传统 GC,没有例外。**
两个冒牌产物被改名为 `QUARANTINE-greentea-*.DO-NOT-DEPLOY`,永久留档。

---

## 4. 修正后的验证方法(唯一可信的两条)

**验证产物,不验证参数。**

```sh
# ① go 版本串:go1.26+ 真关掉时必带 -X:nogreenteagc 后缀
go version -m bin/mihomo-linux-arm64-v1.19.32-go1.26.5 | head -1
#    → go1.26.5-X:nogreenteagc

# ② Green Tea 专属符号计数必须为 0
grep -ac spanInlineMarkBits bin/mihomo-linux-arm64-v1.19.32-go1.26.5
#    → 0
```

这两条已固化成:

- `build-mihomo.sh` 的**出厂检查**:②不通过就删除产物并以非零码退出(`FAIL=1` → `rm -f "$OUT"`),不给"误部署"留机会。
- `backup-mihomo.sh --audit`:随时扫 `bin/` 下所有产物,一眼看出哪个是 Green Tea 冒牌货。

### 一个必须记住的负面结论

**UPX 压缩过的二进制扫不到符号。** 压缩后 `grep -ac spanInlineMarkBits` 返回 0,但那不是"没有 Green Tea",是"被压缩了"。
**别把"扫不到"当成"没有"** —— 兜底核心因此必须是未压缩的、已验证的构建。

---

## 5. 兜底设计:为什么两层,以及为什么是 1 分钟

崩溃不是靠"防住"能完全解决的(万一主核心又被换成官方产物呢),所以还有第二层止血:

| 层 | 谁在做 | 周期 | 职责 |
|---|---|---|---|
| 拉起崩掉的核心 | OpenClash 自带 `openclash_watchdog.sh` | `sleep 60` 循环 | 核心死了重新拉起 |
| 换掉会崩的核心 | `watch_crash.sh` | cron 每 1 分钟 | 检出**新增**崩溃就切兜底核心,只切一次 |

**为什么是 1 分钟而不是 30 秒:** 恢复服务的瓶颈是 OpenClash watchdog 的 60 秒循环。监控再快也快不过它,1 分钟正好对齐;而且 cron 本身做不到亚分钟。

**为什么兜底核心和主核心可以是同一个二进制:** 这套机制真正防的不是"这个核心自己崩",而是**主核心被外部(如 LuCI「更新内核」)换成 Green Tea 构建**。此时 `watch_crash.sh` 会把它换回已验证的兜底核心。所以"主核心 == 兜底核心"不是配置错误。

**状态文件(调试时必看):**

- `/tmp/openclash_core_state` —— 崩溃计数基线
- `/tmp/openclash_core_switched_to_fallback` —— 已切换标记;切过一次就不再自动切,**重新做实验前必须删掉**
- `/tmp/openclash_core_fallback.log` —— 切换日志

---

## 6. 教训(可迁移)

1. **开关的名字要认得准**:`-tags` 与 `GOEXPERIMENT` 是两条完全不同的路,写错不报错、静默无效。
2. **断言必须验证产物,不能验证参数**。"我传了参数"不等于"产物变了";能读二进制就绝不读命令行。
3. **两层保护不要建立在同一个前提上**,否则会同时失效(这里:错误参数 + 匹配该参数痕迹的断言)。
4. **静默失败最贵**。`grep -q` 假通过、`grep -c || echo 0` 变两行、`find` 找错目录导致"编好了却找不到产物"——全是无声的。
5. **不要把"观测不到"当成"不存在"**(UPX 压缩后扫不到符号,差点把兜底核心变成定时炸弹)。
6. **脚本要能自证**:产物名带 go 版本、出厂检查写死、审计命令随时可跑。人对上周的自己没有信任度,脚本要有。
