# dsh-termux-fix

**让 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) 跑在 Termux / Android 上。**

简体中文 · [English](README.md)

---

`dsh` 只发布了 linux、macOS 和 Windows 版本。在 Android 上它能启动，然后在
不同的层各摔一跤。这个仓库把它们收集成一个可重复运行、幂等的安装脚本。

```
$ npm install -g @deepseek-ai/dsh     # 1. 先装 dsh
$ cd dsh-termux-fix && ./install.sh   # 2. 再打补丁
$ dsh web                             # 3. 现在能起来了
```

> **顺序不能反。** 这些补丁改的是**已安装包内部**的文件，所以必须先装好
> `@deepseek-ai/dsh` 再跑 `install.sh`。没装的话脚本会停下来提示你装。
> 每次 `npm install -g @deepseek-ai/dsh` 之后都要重跑 `./install.sh`。

## 为什么跑不起来

Android 与 Linux 足够相似，能骗过所有表面检查；又足够不同，在六个独立的地方失败。
这些都不是配置问题，而是 dsh 的假设与 Android 的实际能力对不上。

| # | 组件 | 失效的假设 | 修法 |
|---|---|---|---|
| 1 | `koffi` | `<sys/stat.h>` 声明了 `statx()` | 把 Android 排除出 `statx` 分支，走自带的 `fstatat` 回退 |
| 2 | `node-addon-require-builtin` | 存在 `android-arm64` 预编译产物 | 从上游源码编译 |
| 3 | `node-addon-system` | 存在 `android-arm64` 预编译产物 | 用自写的最小 N-API 绑定顶替 |
| 4 | 会话持久化、附件 | `link(2)` 可用 | 全部改成 `renameat2` / `copyFile` |
| 5 | 验证 | — | 加载每个绑定并实跑 |
| 6 | 本地语音输入 | 存在 `android-arm64` 的 sherpa-onnx | 用上游官方 Termux 版编译 N-API 封装 |

第 0 步性质不同：它负责装好上面几步要用的工具链（`clang`、`cmake`、`git` 等）。
之所以有这一步，是因为缺 `cmake` 过去只会表现为 `koffi build failed`，真正的
原因埋在堆栈里——见 issue #1。

### 语音：一行报错，两个毛病

语音输入失败时只给一句没什么信息量的话：

```
Error: Local speech is unavailable for android-arm64
```

它来自 `dsh-experimental-speech-to-text-sensevoice` 里写死的平台白名单，
只列了 darwin/linux/win32。把 `android-arm64` 加进去是**必要但不充分**的——
下一个失败点是原生依赖：

`sherpa-onnx-node` 只发 linux、darwin、win32 的预编译产物。其中 `linux-arm64`
那份动态链接的是 **glibc**（`libc.so.6`、`ld-linux-aarch64.so.1`、
`libstdc++.so.6`）。Android 用的是 **bionic**，所以那个二进制根本加载不了——
这不是路径问题，是 libc 就不一样。

出路在于：上游其实发布了 `android-aarch64-termux-shared` 版本，是针对 bionic
编译的，只是没走 npm 分发。第 6 步下载那个发布包，只编译上面那层薄薄的 N-API
封装，然后和 JS 包放在一起。

有个坑值得单独说：**Android 的 linker 完全不处理 `DT_RPATH` 和 `DT_RUNPATH`**——
它会打印 `unused DT entry: DT_RPATH ... (ignoring)` 然后照常往下走。所以既不能靠
rpath 让 addon 找到同目录的 `.so`，dsh 进程里也没有 `LD_LIBRARY_PATH`。补丁因此
在 require addon 之前用 `process.dlopen` 预加载那两个共享库，把它们放进全局符号表，
`OrtGetApiBase` 才解析得到。

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
./install.sh --step 3     只跑某一步（0-6）。
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
  0 toolchain                        complete
  4 attachment-local                 patched (2 refs)
  6 sherpa addon                     present (616216 bytes)
  6 sensevoice platform gate         allows android
  6 addon library preload            patched
  6 model files                      downloaded
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

**第 6 步是最脆的一个。** 它往 `sherpa-onnx-node` 里写文件，而这个包是 npm
作为 voice-input bundle 的传递依赖装进来的。重装会抹掉编译好的 `.node` 和那几个
`.so`。更麻烦的是 dsh profile 用的是 pnpm，`pnpm install` 会重建整个 store，直接把你
送回 `Local speech is unavailable for android-arm64`。任何依赖变动之后都重跑
`./install.sh --step 6`。构建产物留在 `$DSH_FIX_WORKDIR/sherpa-onnx/`，
所以重建只是链接一步，不用重新下载——除非你把那个目录清了。

## 要求

- Android 上的 Termux，**aarch64**（arm64）。预编译的 `system.node` 仅支持
  aarch64；其他架构需从 `system.cc` 重新编译。第 6 步同样依赖上游的
  `android-aarch64` 发布包。
- **先装好 `@deepseek-ai/dsh`。** 跑 `./install.sh` 之前先
  `npm install -g @deepseek-ai/dsh`；这些补丁改的是已安装包，没装就无处可改。
  用 `npm root -g` 确认位置。
- Node.js ≥ 20，且头文件位于 `$PREFIX/include/node`（`pkg install nodejs` 已包含）。
- `clang`、`cmake`、`make`、`git`、`tar`、`curl`。
  **第 0 步会用 `pkg` 装好这些**，已装时自动跳过，所以一般不用手动装。
  之所以还列在这里，是因为如果你跳过第 0 步，第 1 步及之后会假定它们存在。
- 第 2、6 步需要网络（克隆源码、下载 sherpa 发布包）；产物已存在时跳过。
- 语音功能需要在 dsh profile 里启用 voice-input bundle。
  没启用时 `--check` 会显示 `6 speech package  not installed`。

## 排错

**`Error: dsh: plugin tree failed to load`** —— 通常是插件问题，与这些补丁无关。
看完整堆栈；缺某个 npm 包是另一回事。

**`no sandbox backend is usable on this host`** —— Termux 既没有 bubblewrap，
内核也没有启用 Landlock，所以 dsh 的 `workspace-write` 沙箱模式会拒绝执行命令。
这**不是**本仓库能修的，属于运行参数选择：在这台机器上执行工具请用 `danger-full-access`。

**dsh 自己的文件工具报 `EACCES ... cannot write <file>`** —— 与第 4 步同根因：
dsh 的原子写入用了 `link()`。改用 `bash` 重定向写文件即可。第 4 步修的是会话与
附件路径；通用的文件工具路径属于上游，此处未打补丁。

**语音仍然报 `Local speech is unavailable for android-arm64`** —— 第 6 步没跑，
或者被重装抹掉了。`./install.sh --check` 会给第 6 步列三行状态，任何一行是
`MISSING`/`NOT patched` 就重跑 `--step 6`。

**`dlopen failed: cannot locate symbol "OrtGetApiBase"`** —— addon 比它的依赖先加载了，
说明 `addon.js` 的预加载补丁没打上，重跑 `--step 6`。

**模型下载卡住或失败** —— 插件会先试 `huggingface.co`，再试 `hf-mirror.com`，
3 秒内谁先响应就用谁。国内通常第一个连不上。想强制指定，就在插件配置里设
`modelOrigin: https://hf-mirror.com`。模型是在 dsh 设置页首次使用时下载的，
不由本脚本负责。

**`CMake does not seem to be available`** —— 这句报错有误导性。cnoke 判断 cmake
可用与否只看一个测试：

```js
let proc = spawnSync("cmake", ["--version"]);
if (proc.status === 0) { cmake_bin = "cmake" } else { throw ... }
```

所以它会在**两种不同情况**下出现，而只有一种是「没装」：

1. **cmake 没装** → `pkg install cmake`，或 `./install.sh --step 0`。
2. **cmake 装了但跑不起来** —— 升级装坏、缺共享库，或者 `$PREFIX/bin/cmake`
   是个坏副本盖住了能用的那个。此时 `command -v cmake` 是成功的，所以只检查
   「在不在」会放行，然后构建照样失败。

第 1 步现在用和 cnoke 完全一样的判据探测，并把 cmake 自己的 stderr 打出来，
第二种情况不会再伪装成第一种：

```
err cmake is present but not runnable — cnoke will refuse to build.
       'cmake --version' failed with:
         CANNOT LINK EXECUTABLE "cmake": library "libcmake.so" not found

       If it is genuinely missing:  pkg install cmake
       If it is installed but broken: pkg reinstall cmake
```

手工排查：

```bash
command -v cmake     # 解析到哪——注意 PATH 靠前位置有没有旧副本
cmake --version      # 这才是 cnoke 真正检查的；非 0 就是不可用
pkg reinstall cmake  # 通常能修好「装了但坏了」的 cmake
```

`--check` 会区分这两种状态：

```
0 toolchain                        complete
0 toolchain                        MISSING: cmake
0 toolchain                        BROKEN: cmake (installed, will not run)
```

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
  step0-deps.sh             用 pkg 安装工具链
  step1-koffi.sh            statx -> fstatat
  step2-require-builtin.sh  克隆源码，编译缺失的绑定
  step3-system.sh           构建/安装 flock + renameNoReplace，修平台守卫
  step4-selinux.sh          link() 回退
  step5-verify.sh           加载并实跑每个绑定
  step6-speech.sh           下载上游 Termux 发布包，编译语音 addon
  build-require-builtin.sh  复刻上游 build.ts 的 clang 命令行
  build-sherpa-addon.sh     sherpa N-API 封装的 clang 命令行
src/node-addon-system/
  system.cc                 N-API 绑定：tryLock、renameNoReplace
  system.node               预编译 aarch64 绑定（回退用）
patch/
  patch-session-persistence.mjs   针对两个 JS 包的锚点补丁器
  patch-sherpa-addon.mjs          库预加载 + sensevoice 平台白名单
docs/
  technical-notes.md        N-API 接口契约的深入说明
```

## 状态

已在 Termux / aarch64 / Node v26.4.0 / clang 21.1.8，dsh 0.2.1-rc.2、
koffi 3.1.1、sherpa-onnx 1.13.8 上验证。

**这不是官方支持路径。** 这里的一切都在修改已安装 npm 包内部的文件。
升级即失效，上游测试不覆盖，dsh 内部实现也可能随时改变。

## 提交 Issue

这些补丁的目标一直在变：**某一步失效，往往是因为 dsh 改了，而不是本仓库坏了。**
提 issue 之前先拉取最新提交，可能已经修好了。

```bash
cd dsh-termux-fix
git pull
./install.sh --check        # 完整粘贴输出
git rev-parse --short HEAD  # 这个也要贴
```

请附上 `git rev-parse --short HEAD` 的短 hash。没有它，问题没法复现：
你看到的行为可能来自旧版本，而维护者无从判断你实际跑的是哪份代码。
同时附上 dsh 版本、`node -v` 和 `uname -m`。

Issue 模板会要求填这些。缺少 commit hash 的 issue 可能会被要求拉取后重新提交。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
