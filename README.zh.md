# dsh-termux-fix

**让 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) 跑在 Termux / Android 上。**

简体中文 · [English](README.md)

---

`dsh` 只发布了 linux、macOS 和 Windows 版本。在 Android 上它能启动，然后在
不同的层各摔一跤。这个仓库把它们收集成一个可重复运行、幂等的安装脚本。

```
$ npm install -g @deepseek-ai/dsh
$ ./install.sh
$ dsh web                     # 现在能起来了
```

## 为什么跑不起来

Android 与 Linux 足够相似，能骗过所有表面检查；又足够不同，在五个独立的地方失败。
这些都不是配置问题，而是 dsh 的假设与 Android 的实际能力对不上。

| # | 组件 | 失效的假设 | 修法 |
|---|---|---|---|
| 1 | `koffi` | `<sys/stat.h>` 声明了 `statx()` | 把 Android 排除出 `statx` 分支，走自带的 `fstatat` 回退 |
| 2 | `node-addon-require-builtin` | 存在 `android-arm64` 预编译产物 | 从上游源码编译 |
| 3 | `node-addon-system` | 存在 `android-arm64` 预编译产物 | 用自写的最小 N-API 绑定顶替 |
| 4 | 会话持久化、附件 | `link(2)` 可用 | 全部改成 `renameat2` / `copyFile` |
| 5 | 验证 | — | 加载每个绑定并实跑 |

### 最麻烦的一个：SELinux 禁止 `link()`

这一条最耗时，因为它不是关于 capabilities 或文件系统的错误——
**Android 的 SELinux 策略直接拒绝 `link(2)`**，每次调用都返回 `EACCES`/`EPERM`。

dsh 在三处用 `link()`，而且三处都在做同一件特定的事：**原子独占创建发布**。
把暂存文件链到最终路径，要么成功（文件同时存在于两个名字下，再删掉暂存名），
要么因为目标已存在而返回 `EEXIST`。这是 compare-and-swap，不是拷贝。

所以替换方案不能是普通 `rename()`——那会静默覆盖并发写入者的结果。两个回退都保住了原语义：

| 位置 | 回退方案 | 为何等价 |
|---|---|---|
| 会话发布（ESM + CJS） | `renameat2(RENAME_NOREPLACE)` | 内核级原子独占创建；冲突时同样报 `EEXIST` |
| 附件发布 | `copyFile` | 目标是内容寻址（sha256），并发重复写入字节相同；随后的摘要校验仍然把关 |

前者需要 Node 公开 API 没有暴露的系统调用，这正是第 3 步存在的原因：
`src/node-addon-system/system.cc` 是一个小型 N-API 绑定，同时提供
`flock`（dsh 需要）和 `renameNoReplace`（我们的补丁需要）。

## 快速开始

```bash
git clone https://github.com/Mooling0602/dsh-termux-fix
cd dsh-termux-fix
./install.sh --check    # 先看缺什么
./install.sh            # 全部应用
```

然后重启 `dsh`。

## 用法

```
./install.sh              应用全部步骤。幂等，可重复运行。
./install.sh --check      只报告各补丁状态，不做任何改动。
./install.sh --step 3     只跑某一步。
./install.sh --list       列出步骤。
./install.sh --help       完整选项。
```

`--check` 的输出大致是这样：

```
dsh-termux-fix — status

  dsh version   0.2.1-rc.2
  modules       /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules
  node          v26.4.0
  platform      Linux aarch64

  1 koffi source                     patched
  2 require-builtin binding          present (245424 bytes)
  3 system binding                   present (8216 bytes)
  3 flock.js guard                   allows android
  4 session-persistence              patched (3 refs)
  4 attachment-local                 patched (2 refs)
```

### 环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `DSH_MODULES` | `npm root -g` + `/@deepseek-ai/dsh/node_modules` | dsh 安装位置 |
| `DSH_FIX_WORKDIR` | `~/src` | 克隆/编译源码的暂存目录 |
| `NODE_INC` | `$PREFIX/include/node` | 含 `node_api.h` 的目录 |
| `NO_COLOR` | 未设置 | 关闭彩色输出 |

## 每次升级之后

> **补丁改的是已安装包内的文件，任何重装或升级都会把它们抹掉。**
> 每次 `npm install -g @deepseek-ai/dsh` 之后都要重新跑 `./install.sh`。

只有 `koffi` 需要真正重新编译；另外两个走 N-API v9，能跨 Node 版本存活。
第 2 步在绑定已存在时会直接跳过，所以重跑成本很低。

## 要求

- Android 上的 Termux，**aarch64**（arm64）。预编译的 `system.node` 仅支持
  aarch64；其他架构需从 `system.cc` 重新编译。
- Node.js ≥ 20，且头文件位于 `$PREFIX/include/node`（`pkg install nodejs` 已包含）。
- `clang`（`pkg install clang`）。
- 第 2 步需要网络（克隆上游源码）；绑定已存在时跳过。

## 排错

**`Error: dsh: plugin tree failed to load`** —— 通常是插件问题，与这些补丁无关。
看完整堆栈；缺某个 npm 包是另一回事。

**`no sandbox backend is usable on this host`** —— Termux 既没有 bubblewrap，
内核也没有启用 Landlock，所以 dsh 的 `workspace-write` 沙箱模式会拒绝执行命令。
这**不是**本仓库能修的，属于运行参数选择：在这台机器上执行工具请用 `danger-full-access`。

**dsh 自己的文件工具报 `EACCES ... cannot write <file>`** —— 与第 4 步同根因：
dsh 的原子写入用了 `link()`。改用 `bash` 重定向写文件即可。第 4 步修的是会话与
附件路径；通用的文件工具路径属于上游，此处未打补丁。

**`upstream layout changed`** —— 某一步的锚点出现的次数不是恰好 1 次，说明上游挪了代码。
不要强行绕过；带上 dsh 版本提 issue。

## 实现说明

每一步都是 [`scripts/`](scripts/) 下的独立脚本，可单独运行。安装器只负责编排与汇报。

补丁用**精确文本锚点**应用，不用正则。锚点出现次数不等于 1 时脚本会拒绝执行——
因为这一带补丁一旦打错位置，不会立刻报错，而是在并发场景下损坏会话文件。
打不上补丁是安全的失败方式。

### 仓库结构

```
install.sh                  入口：--check / --step / --list / --help
scripts/
  lib.sh                    共享函数、模块定位
  step1-koffi.sh            statx -> fstatat
  step2-require-builtin.sh  克隆源码，编译缺失的绑定
  step3-system.sh           构建/安装 flock + renameNoReplace，修平台守卫
  step4-selinux.sh          link() 回退
  step5-verify.sh           加载并实跑每个绑定
  build-require-builtin.sh  复刻上游 build.ts 的 clang 命令行
src/node-addon-system/
  system.cc                 N-API 绑定：tryLock、renameNoReplace
  system.node               预编译 aarch64 绑定（回退用）
patch/
  patch-session-persistence.mjs   针对两个 JS 包的锚点补丁器
docs/
  technical-notes.md        N-API 接口契约的深入说明
```

## 状态

已在 Termux / aarch64 / Node v26.4.0 / clang 21.1.8，dsh 0.2.1-rc.2、
koffi 3.1.1 上验证。

**这不是官方支持路径。** 这里的一切都在修改已安装 npm 包内部的文件。
升级即失效，上游测试不覆盖，dsh 内部实现也可能随时改变。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
