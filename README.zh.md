# dsh-termux-fix

**让 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) 跑在 Termux / Android 上。**

简体中文 · [English](README.md)

---

`dsh` 只发布了 linux、macOS 和 Windows 版本。在 Android 上它能启动，然后在不同的层各摔一跤。这个仓库把它们收集成一个可重复运行、幂等的安装脚本。

> [!IMPORTANT]
> 本项目只保证与**最新版** `@deepseek-ai/dsh` 的兼容性，不保证与旧版 dsh 兼容。补丁是按已安装包内部的精确文本锚点打上去的，这些锚点在版本之间会移动。dsh 更新之后，请执行 `git pull` 拉取最新代码以获得对应的补丁，或者等待适配完成。锚点对不上时，相关步骤会以 `upstream layout changed` 退出，而不会打到错误的位置。

```
$ git clone https://github.com/Mooling0602/dsh-termux-fix
$ cd dsh-termux-fix
$ ./scripts/install-dsh.sh            # 装 dsh，然后打补丁
$ dsh web                             # 现在能起来了
```

> **要用 `--ignore-scripts` 装，不能直接 `npm install -g`。** 直接跑 `npm install -g @deepseek-ai/dsh` 在 Termux/Android 上**会失败**：koffi 的 install 脚本要编译 C++，其中的 `statx()` 分支在 bionic 上编不过，脚本以 1 退出，npm 随后回滚整个全局安装，结果一个 dsh 都没留下。`scripts/install-dsh.sh` 用 `--ignore-scripts` 安装，然后跑 `./install.sh`，把跳过的脚本本该产出的原生绑定全部补上。加 `--with-tui` 可以在同一次安装里带上 `@deepseek-harness-tui/dsh-tui`。

## 为什么跑不起来

Android 与 Linux 足够相似，能骗过所有表面检查；又足够不同，在七个独立的地方失败。这些都不是配置问题，而是 dsh 的假设与 Android 的实际能力对不上。

| # | 组件 | 失效的假设 | 修法 |
|---|---|---|---|
| 1 | `koffi` | `<sys/stat.h>` 声明了 `statx()` | 提供已排除 `statx` 的预编译绑定；对不上才编译 |
| 2 | `node-addon-require-builtin` | 存在 `android-arm64` 预编译产物 | 从上游源码编译 |
| 3 | `node-addon-system` | 存在 `android-arm64` 预编译产物 | 用自写的最小 N-API 绑定顶替 |
| 4 | 会话持久化、附件 | `link(2)` 可用 | 全部改成 `renameat2` / `copyFile` |
| 5 | 验证 | — | 加载每个绑定并实跑 |
| 6 | 本地语音输入 | 存在 `android-arm64` 的 sherpa-onnx | 用上游官方 Termux 版编译 N-API 封装 |
| 7 | 持久终端 (pty) | `process.platform` 只会是 linux/darwin/win32；且存在 `android-arm64` 的 node-pty | 让 inspector 走 Linux 分支；提供预编译的 `pty.node` |

第 0 步性质不同：它负责装好上面几步要用的工具链（`clang`、`cmake`、`git` 等）。之所以有这一步，是因为缺 `cmake` 过去只会表现为 `koffi build failed`，真正的原因埋在堆栈里——见 issue #1。

### 语音：一行报错，两个毛病

语音输入失败时只给一句没什么信息量的话：

```
Error: Local speech is unavailable for android-arm64
```

它来自 `dsh-experimental-speech-to-text-sensevoice` 里写死的平台白名单，只列了 darwin/linux/win32。把 `android-arm64` 加进去是**必要但不充分**的——下一个失败点是原生依赖：

`sherpa-onnx-node` 只发 linux、darwin、win32 的预编译产物。其中 `linux-arm64` 那份动态链接的是 **glibc**（`libc.so.6`、`ld-linux-aarch64.so.1`、`libstdc++.so.6`）。Android 用的是 **bionic**，所以那个二进制根本加载不了——这不是路径问题，是 libc 就不一样。

出路在于：上游其实发布了 `android-aarch64-termux-shared` 版本，是针对 bionic 编译的，只是没走 npm 分发。第 6 步下载那个发布包，只编译上面那层薄薄的 N-API 封装，然后和 JS 包放在一起。

有个坑值得单独说：**Android 的 linker 完全不处理 `DT_RPATH` 和 `DT_RUNPATH`**——它会打印 `unused DT entry: DT_RPATH ... (ignoring)` 然后照常往下走。所以既不能靠 rpath 让 addon 找到同目录的 `.so`，dsh 进程里也没有 `LD_LIBRARY_PATH`。补丁因此在 require addon 之前用 `process.dlopen` 预加载那两个共享库，把它们放进全局符号表，`OrtGetApiBase` 才解析得到。

### koffi 走预编译绑定

`src/koffi/koffi.node` 是用打过补丁的源码编好的一份 aarch64 绑定。第 1 步直接安装它，并验证它真能加载——用的是和 cnoke 一样的检查（`node -e "require('koffi')"`）。

这么做不是为了快。**有一份能用的绑定，就意味着 cmake 根本不会被调用**，而 cmake 恰恰是整套东西在 Termux 上最不可靠的一环：issue #1 和 #2 都是 cmake 出问题（先是没装，后来是它对着更新的 libc++ 编译、装着的 libc++ 却偏旧），两次都和 koffi 本身无关。cnoke 在 `checkPrebuild()` 里遇到有效预编译产物会直接返回，所以只要它在，编译器和 cmake 都不会启动。

这份绑定是 N-API 的，因此不受 Node 大版本影响；但它绑定 koffi 的版本。`koffi.json` 记着版本、架构和校验和，任何一项对不上，第 1 步就回退到从源码编译——换个 koffi 版本依然能用，只是那时才需要工具链。

### 终端：两道门，缺一不可

打开持久终端时报的只有一句 `terminal inspection is unsupported on platform android`，但底下压着两个互不相干的问题，只修一个仍然是打不开。

**第一道：`process.platform` 是 `android`，不是 `linux`。** dsh 的 `createProcessInspector()` 只认 `linux`/`darwin`/`win32`，其余直接抛错——而这个函数在插件加载时就调用，于是整个终端服务起不来。但 Android 内核就是 Linux：`/proc` 布局一致，inspector 读的 arm64 syscall 号（`read`=63、`pselect`=72、`ppoll`=73、`epoll_pwait`=22）也完全一样。所以让它走 `LinuxProcessInspector` 是语义正确的，不是权宜之计。

**第二道：`node-pty` 没有 android 预编译产物。** 它的加载器去 `prebuilds/<platform>-<arch>/pty.node` 找，也就是 `prebuilds/android-arm64/`，上游没有这个目录。而现成的 `linux-arm64` 那份**不能直接用**：它动态链接 glibc 的 `libutil.so.1`，Android 用 bionic，`libutil` 早已并进 libc：

```
dlopen failed: library "libutil.so.1" not found
```

所以只能针对 bionic 自己编。`src/node-pty/pty.node` 就是这么来的一份 aarch64 绑定，编自**未打补丁**的上游 `src/unix/pty.cc`——`forkpty(3)` 在 bionic 上本来就有，不需要改源码。链接时不加 `-lutil`（bionic 不需要），也不加 rpath（Android 的 linker 会忽略）。

和 koffi 一样优先用预编译产物，`pty.json` 记着 node-pty 版本、架构和校验和，对不上才回退到 `scripts/build-node-pty.sh` 现场编译——那样就需要 `clang` 了。第 7 步最后会真的 fork 一个 shell 并读回它的回显，因为仅仅 `require()` 成功并不能证明 `forkpty` 在 bionic 上可用。

### 最麻烦的一个：SELinux 禁止 `link()`

这一条最耗时，因为它不是关于 capabilities 或文件系统的错误——**Android 的 SELinux 策略直接拒绝 `link(2)`**，每次调用都返回 `EACCES`/`EPERM`。

dsh 在三处用 `link()`，而且三处都在做同一件特定的事：**原子独占创建发布**。把暂存文件链到最终路径，要么成功（文件同时存在于两个名字下，再删掉暂存名），要么因为目标已存在而返回 `EEXIST`。这是 compare-and-swap，不是拷贝。

所以替换方案不能是普通 `rename()`——那会静默覆盖并发写入者的结果。两个回退都保住了原语义：

| 位置 | 回退方案 | 为何等价 |
|---|---|---|
| 会话发布（ESM + CJS） | `renameat2(RENAME_NOREPLACE)` | 内核级原子独占创建；冲突时同样报 `EEXIST` |
| 附件发布 | `copyFile` | 目标是内容寻址（sha256），并发重复写入字节相同；随后的摘要校验仍然把关 |

前者需要 Node 公开 API 没有暴露的系统调用，这正是第 3 步存在的原因：`src/node-addon-system/system.cc` 是一个小型 N-API 绑定，同时提供 `flock`（dsh 需要）和 `renameNoReplace`（我们的补丁需要）。

## 快速开始

```bash
git clone https://github.com/Mooling0602/dsh-termux-fix
cd dsh-termux-fix
./scripts/install-dsh.sh --with-tui   # 装 dsh + dsh-tui，然后打补丁
./install.sh --check                  # 看还缺什么（全绿就装完了）
```

然后重启 `dsh`。如果 dsh 已经装好、只想打补丁，单独跑 `./install.sh` 仍然是对的。

### 手动安装 dsh

`scripts/install-dsh.sh` 只是把下面两步包了一下：

```bash
npm install -g --ignore-scripts @deepseek-ai/dsh    # --ignore-scripts 是必须的
./install.sh                                        # 补上被跳过的绑定
```

这个 flag 不是图快。开着脚本时，koffi 的 `install` 钩子会跑 CNoke，尝试编译 `lib/native/base/base.cc`，在 `statx()` 调用处（第 2967 行）报 `cannot initialize a member subobject of type '__u32' ... with an lvalue of type 'const char *'` 并以 1 退出。npm 把任何一个生命周期脚本失败都当成整个安装失败，回滚整棵树，于是 dsh 根本没装上。跳过脚本、之后再打补丁，得到的最终状态一样，只是不做那次注定失败的编译。

**装第二个会把 dsh 拉成依赖的全局包**（比如 `dsh-tui`）时同理：那里也要带 `--ignore-scripts`，否则 koffi 的钩子会再触发一次，把那次安装一并回滚。装完要重跑 `./install.sh`，因为新安装把已有补丁抹掉了。

## 用法

```
./install.sh              应用全部步骤。幂等，可重复运行。
./install.sh --check      只报告各补丁状态，不做任何改动。
./install.sh --step 3     只跑某一步（0-8）。
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

  1 koffi binding                    loads (koffi 3.1.1)
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

> **补丁改的是已安装包内的文件，任何重装或升级都会把它们抹掉。** 升级就是重跑 `./scripts/install-dsh.sh`（或者 dsh 已装好时，自己跑 `npm install -g --ignore-scripts @deepseek-ai/dsh` 再跑 `./install.sh`）。注意：用常规方式重装——不带 `--ignore-scripts`——不只是抹掉补丁，而是直接失败并把 dsh 回滚掉。

只有 `koffi` 需要真正重新编译；另外两个走 N-API v9，能跨 Node 版本存活。第 2 步在绑定已存在时会直接跳过，所以重跑成本很低。

**第 6 步是最脆的一个。** 它往 `sherpa-onnx-node` 里写文件，而这个包是 npm 作为 voice-input bundle 的传递依赖装进来的。重装会抹掉编译好的 `.node` 和那几个 `.so`。更麻烦的是 dsh profile 用的是 pnpm，`pnpm install` 会重建整个 store，直接把你送回 `Local speech is unavailable for android-arm64`。任何依赖变动之后都重跑 `./install.sh --step 6`。构建产物留在 `$DSH_FIX_WORKDIR/sherpa-onnx/`，所以重建只是链接一步，不用重新下载——除非你把那个目录清了。

## 要求

- Android 上的 Termux，**aarch64**（arm64）。预编译的 `system.node` 仅支持 aarch64；其他架构需从 `system.cc` 重新编译。第 6 步同样依赖上游的 `android-aarch64` 发布包。
- **先装好 `@deepseek-ai/dsh`，且不能带生命周期脚本。** 跑 `./install.sh` 之前先跑 `./scripts/install-dsh.sh`（或 `npm install -g --ignore-scripts @deepseek-ai/dsh`）；这些补丁改的是已安装包，没装就无处可改。直接 `npm install -g @deepseek-ai/dsh` 会卡在 koffi 编译上并回滚，什么都不会装——见[手动安装 dsh](#手动安装-dsh)。用 `npm root -g` 确认位置。
- Node.js ≥ 20，且头文件位于 `$PREFIX/include/node`（`pkg install nodejs` 已包含）。
- `clang`、`cmake`、`make`、`git`、`tar`、`curl`。**第 0 步会用 `pkg` 装好这些**，已装时自动跳过，所以一般不用手动装。之所以还列在这里，是因为如果你跳过第 0 步，第 1 步及之后会假定它们存在。其中 `cmake` 只在预编译的 koffi 绑定不能用时才需要——见下。
- 第 2、6 步需要网络（克隆源码、下载 sherpa 发布包）；产物已存在时跳过。
- 语音功能需要在 dsh profile 里启用 voice-input bundle。没启用时 `--check` 会显示 `6 speech package  not installed`。

## 排错

**`Error: dsh: plugin tree failed to load`**——通常是插件问题，与这些补丁无关。看完整堆栈；缺某个 npm 包是另一回事。

**`no sandbox backend is usable on this host`**——Termux 既没有 bubblewrap，内核也没有启用 Landlock，所以 dsh 的 `workspace-write` 沙箱模式会拒绝执行命令。这**不是**本仓库能修的，属于运行参数选择：在这台机器上执行工具请用 `danger-full-access`。

**dsh 自己的文件工具报 `EACCES ... cannot write <file>`**——与第 4 步同根因：dsh 的原子写入用了 `link()`。改用 `bash` 重定向写文件即可。第 4 步修的是会话与附件路径；通用的文件工具路径属于上游，此处未打补丁。

**语音仍然报 `Local speech is unavailable for android-arm64`**——第 6 步没跑，或者被重装抹掉了。`./install.sh --check` 会给第 6 步列三行状态，任何一行是 `MISSING`/`NOT patched` 就重跑 `--step 6`。

**`dlopen failed: cannot locate symbol "OrtGetApiBase"`**——addon 比它的依赖先加载了，说明 `addon.js` 的预加载补丁没打上，重跑 `--step 6`。

**模型下载卡住或失败**——插件会先试 `huggingface.co`，再试 `hf-mirror.com`，3 秒内谁先响应就用谁。国内通常第一个连不上。想强制指定，就在插件配置里设 `modelOrigin: https://hf-mirror.com`。模型是在 dsh 设置页首次使用时下载的，不由本脚本负责。

**`CMake does not seem to be available`**——这句报错有误导性。cnoke 判断 cmake 可用与否只看一个测试：

```js
let proc = spawnSync("cmake", ["--version"]);
if (proc.status === 0) { cmake_bin = "cmake" } else { throw ... }
```

所以它会在**两种不同情况**下出现，而只有一种是「没装」：

1. **cmake 没装** → `pkg install cmake`，或 `./install.sh --step 0`。
2. **cmake 装了但跑不起来**——升级装坏、缺共享库，或者 `$PREFIX/bin/cmake` 是个坏副本盖住了能用的那个。此时 `command -v cmake` 是成功的，所以只检查「在不在」会放行，然后构建照样失败。

第 1 步现在用和 cnoke 完全一样的判据探测，并把 cmake 自己的 stderr 打出来，第二种情况不会再伪装成第一种：

```
err cmake is present but not runnable — cnoke will refuse to build.
       'cmake --version' failed with:
         CANNOT LINK EXECUTABLE "cmake": library "libcmake.so" not found

       If it is genuinely missing:  pkg install cmake
       If it is installed but broken: pkg reinstall cmake
```

还有**第三种**情况，修法不一样。如果 `cmake --version` 在加载阶段就失败，报缺 C++ 符号：

```
CANNOT LINK EXECUTABLE "cmake": cannot locate symbol
  "_ZNSt6__ndk113__hash_memoryEPKvm" referenced by ".../bin/cmake"
```

那是 cmake 和 libc++ **版本不同步**——cmake 是对着比现装更新的 libc++ 编译的。`__hash_memory` 是 libc++ 21 才加入的符号，所以 libc++ 偏旧就会出现这句。**重装 cmake 修不好**，因为过时的不是 cmake，是 libc++。两个一起升：

```bash
pkg upgrade
```

这属于「部分升级」，不是包坏了。常见于上次 `pkg upgrade` 被中断，或者单独 `pkg install cmake` 时镜像已经前进、而本机 libc++ 还停在旧版本。

手工排查：

```bash
command -v cmake        # 解析到哪——注意 PATH 靠前位置有没有旧副本
cmake --version         # 这才是 cnoke 真正检查的；非 0 就是不可用
ldd "$PREFIX/bin/cmake" # 实际会加载哪个 libc++
pkg upgrade             # 修 cmake/libc++ 版本不同步
pkg reinstall cmake     # 仅当 libc++ 是新的、cmake 自身损坏时
```

`--check` 会区分这两种状态：

```
0 toolchain                        complete
0 toolchain                        MISSING: cmake
0 toolchain                        BROKEN: cmake (installed, will not run)
```

**`upstream layout changed`**——某一步的锚点出现的次数不是恰好 1 次，说明上游挪了代码。不要强行绕过；带上 dsh 版本提 issue。

### 已知缺口

`sharp` 那个失败**不是**本项目能修的，也与用 `--ignore-scripts` 安装无关。它属于"缺平台包"问题，没有补丁可打：这个包在运行时按平台解析一个只能由 npm 通过 `optionalDependencies` 提供的二进制，而 registry 上没有 Android 条目。

**`Could not load the "sharp" module using the android-arm64 runtime`**——图片附件。`sharp@0.35.x` 没有纯 JS 兜底，运行时会选 `@img/sharp-<platform>-<arch>` 包；这些包的 `os` 字段里都没有 `android`，于是 npm 全部跳过，只装上了 `@img/colour`。它由 `@deepseek-ai/dsh-attachment-local` 惰性调用，所以插件本身能加载，纯文本使用不受影响——只有第一次做图片归一化时抛错。本仓库无法修：要让图片链路可用，得把 `sharp` 或 libvips 针对 bionic 编出来，而上游没有这样的发布包。

另外两个同形状的缺口**已经修掉了**，由 step 8 负责（早期版本把它们记作"上游问题、此处不修"）：

**`Could not find @vscode/ripgrep-android-arm64`**——`glob` 与 `grep` 工具报 `SEARCH_FAILED ... ripgrep launch failed`。`dsh-tool-fs-search` 通过 `@vscode/ripgrep` 定位 ripgrep，后者要求存在 `@vscode/ripgrep-<platform>-<arch>/bin/rg`；registry 上有十二个这样的包，没有一个面向 Android。修法是把 `@vscode/ripgrep-android-arm64/bin/rg` 建成指向系统 `rg` 的符号链接——`require.resolve()` 只要文件在就行，而链接保证 `pkg upgrade ripgrep` 之后 dsh 用的是同一个二进制。

**`write` 无法创建新文件**——`EACCES ... link '....tmpdir/xxx.tmp' -> 'xxx'`。`dsh-fs-local` 用一个同目录下的私有暂存文件发布写入，新文件走 `link(2)`；Android SELinux 直接拒绝硬链接，所以只要目标文件还不存在，`write` 就必然失败（改已有文件走的是 `rename(2)`，因此不受影响）。修法是捕获 `EACCES`/`EPERM` 后改用 `renameat2(RENAME_NOREPLACE)`：原子、冲突时报 `EEXIST`，与 `link`-when-absent 的契约一致，由 step 3 已经提供的 `system.node` 绑定实现。

这两个都是惰性触发的：第一次写入 / 第一次搜索才暴露，启动时看不出问题。打补丁后需要重启 dsh 才生效。

## 实现说明

每一步都是 [`scripts/`](scripts/) 下的独立脚本，可单独运行。安装器只负责编排与汇报。

补丁用**精确文本锚点**应用，不用正则。锚点出现次数不等于 1 时脚本会拒绝执行——因为这一带补丁一旦打错位置，不会立刻报错，而是在并发场景下损坏会话文件。打不上补丁是安全的失败方式。

### 仓库结构

```
install.sh                  入口：--check / --step / --list / --help
scripts/
  install-dsh.sh            用 --ignore-scripts 装 dsh，然后打补丁
  lib.sh                    共享函数、模块定位
  step0-deps.sh             用 pkg 安装工具链
  step1-koffi.sh            安装预编译绑定，不匹配才 statx -> fstatat 编译
  step2-require-builtin.sh  克隆源码，编译缺失的绑定
  step3-system.sh           构建/安装 flock + renameNoReplace，修平台守卫
  step4-selinux.sh          link() 回退
  step5-verify.sh           加载并实跑每个绑定
  step6-speech.sh           下载上游 Termux 发布包，编译语音 addon
  step7-terminal.sh         终端平台守卫 + 安装/编译 pty 绑定
  step8-platform-gaps.sh    ripgrep android 垫片 + fs-local 的 link() 回退
  build-require-builtin.sh  复刻上游 build.ts 的 clang 命令行
  build-sherpa-addon.sh     sherpa N-API 封装的 clang 命令行
  build-node-pty.sh         针对 bionic 编译 node-pty 的 pty.cc
src/node-addon-system/
  system.cc                 N-API 绑定：tryLock、renameNoReplace
  system.node               预编译 aarch64 绑定（回退用）
src/koffi/
  koffi.node                预编译 aarch64 koffi 绑定，已排除 statx
  koffi.json                上者的版本、架构与校验和
src/node-pty/
  pty.node                  预编译 aarch64 pty 绑定，针对 bionic 编译
  pty.json                  上者的版本、架构与校验和
patch/
  patch-session-persistence.mjs   针对两个 JS 包的锚点补丁器
  patch-sherpa-addon.mjs          库预加载 + sensevoice 平台白名单
  patch-terminal-android.mjs      inspector 平台守卫 + node-pty 加载路径
  patch-platform-gaps.mjs         ripgrep android 垫片 + fs-local 的 link() 回退
docs/
  technical-notes.md        N-API 接口契约的深入说明
```

## 状态

已在 Termux / aarch64 / Node v26.4.0 / clang 21.1.8，dsh 0.2.1-rc.2、koffi 3.1.1、sherpa-onnx 1.13.8 上验证。

**这不是官方支持路径。** 这里的一切都在修改已安装 npm 包内部的文件。升级即失效，上游测试不覆盖，dsh 内部实现也可能随时改变。

## 提交 Issue

这些补丁的目标一直在变：**某一步失效，往往是因为 dsh 改了，而不是本仓库坏了。** 提 issue 之前先拉取最新提交，可能已经修好了。

```bash
cd dsh-termux-fix
git pull
./install.sh --check        # 完整粘贴输出
git rev-parse --short HEAD  # 这个也要贴
```

请附上 `git rev-parse --short HEAD` 的短 hash。没有它，问题没法复现：你看到的行为可能来自旧版本，而维护者无从判断你实际跑的是哪份代码。同时附上 dsh 版本、`node -v` 和 `uname -m`。

Issue 模板会要求填这些。缺少 commit hash 的 issue 可能会被要求拉取后重新提交。

## 许可证

MIT——见 [LICENSE](LICENSE)。
