# 技术说明

如果你要修改这些补丁或移植到其他架构，这里是需要知道的实现细节。

简体中文 · [English](technical-notes.md)

## `system.cc` 里的 N-API 接口契约

两个函数都是从 `node-addon-system/lib/flock.js` 反推出来的，细节都不显然。写错不会崩溃，而是静默地行为异常。

### `tryLock(fd, cb)`

```c
int rc = flock((int)fd, LOCK_EX | LOCK_NB);
int32_t result = (rc == 0) ? 0 : errno;
// cb(result)
```

两个要点：

1. **非阻塞。** `LOCK_NB` 意味着调用从不等待，所以同步实现是正确的，不需要异步。
2. **传正数 errno。** 回调必须收到 `EAGAIN` 的 `11`，而不是 `-11`。`flock.js` 用 `getSystemErrorName(-errno)` 转换，而 Node 的 `getSystemErrorName` 只接受负整数。传负值进去会被再取一次负，得到垃圾结果。

### `renameNoReplace(oldPath, newPath, cb)`

```c
int rc = (int)syscall(SYS_renameat2, AT_FDCWD, oldpath,
                      AT_FDCWD, newpath, RENAME_NOREPLACE);
int32_t result = (rc == 0) ? 0 : errno;
// cb(result)
```

它替代 `link()` 作为原子独占创建发布：

| 结果 | `link()`（目标不存在时） | `renameat2(RENAME_NOREPLACE)` |
|---|---|---|
| 目标不存在 | 建立硬链接 | 原子地移动文件 |
| 目标已存在 | `EEXIST` | `EEXIST` |
| 半写状态可见 | 从不 | 从不 |

`SYS_renameat2` 未定义时回退为 `276`，即 aarch64 的 asm-generic 编号。**其他架构需要各自的编号**（x86_64：316，arm：382）。由于有 `#ifndef` 保护，头文件里的正确定义总是优先，所以这只在 libc 不导出该宏的平台上才有影响。

路径被复制进 4096 字节的栈缓冲；超长路径抛 TypeError，而非截断。

## 为什么 `link()` 不是"不支持"那么简单

值得说准确，因为错误的表述会让人去查文件系统配置。

Android 的 SELinux 策略对应用进程的 `link(2)` 返回 `EACCES`，而且这个拒绝发生在文件系统被查询之前——同一个 `link()` 调用在布局完全相同的普通 Linux 上是成功的。根据命中的具体策略规则，`errno` 可能是 `EACCES` 或 `EPERM`，所以补丁两个都判。

推论：没有任何挂载选项、`chmod` 或换路径能解决。只有两条路——不用 `link()`，或者放弃原子性。

## 为什么附件用 `copyFile` 而不是 `renameat2`

附件路径是内容寻址的：目标文件名由内容的 sha256 决定。因此两个并发写入者产生的是逐字节相同的目标，`copyFile` 竞争是安全的——输家覆盖的是同样的字节。发布之后的摘要校验照常执行，仍然守住完整性。

会话持久化没有这个性质：每次会话更新产生的暂存文件都不同，在那里用 `copyFile` 就是真正的后写者覆盖。所以它走系统调用那条路。

## 为什么持久化 fsync 遍历止步于 `/data/data`

`dsh-attachment-local` 并不只是写一个文件，它还要把通往该文件的整条路径都做成崩溃可持久的。`ensureDurableHome()` 把附件主目录和文件系统根交给 `ensureDurableDirectory()`，由后者在向上遍历时逐个 fsync 各级祖先目录：

```js
let level = target;
while (level !== stop) {
	const parent = dirname(level);
	await syncDirectory(parent);
	if (parent === level) return;
	level = parent;
}
```

在 Linux 上这是对的：一个目录项只有在父目录被 sync 之后才是持久的。在 Android 上这个遍历走不完，因为 `/data/data` 的权限是 `0711`、属主是系统，应用进程可以穿过它，但不能以读方式打开它：

```
EACCES: permission denied, open '/data/data'
```

这个遍历就在附件存储里，所以在 `link()` 被尝试之前，**每一次**附件发布都会失败——图片和普通文件都一样。它一直没被发现，是因为读图更早就在 `sharp` 里死掉了，而普通文件上传是较少走的路径。

补丁保留了原意、丢掉做不到的那部分：祖先目录返回 `EACCES`/`EPERM` 时结束遍历，而不是让写入失败。走到这里时，从附件主目录往下的一切都已经 sync 过，而那正是本进程所创建的部分。应用私有根之上的目录项属于包管理器；任何应用都无法 fsync 它们，进程崩溃也不会把它们丢掉。

一个细节：`syncDirectory()` 本身没有打补丁。它也会用于本进程确实会创建的目录，在那里权限失败是真正的错误，必须照常暴露出来。只有这个遍历把「文件系统拒绝再往上」当作边界。

## 基于锚点的补丁

`patch-session-persistence.mjs` 用精确子串定位每个改写点，并要求它恰好出现一次：

```js
if (count(src, anchor) !== 1) {
    console.error(`anchor found ${count(src, anchor)} times (expected 1), upstream layout changed`);
    process.exit(1);
}
```

这是**故意做脆**的。用正则或模糊匹配的话，上游一改代码它还能"正常工作"，却改在错误的位置——而在这一带，改错位置的补丁只在并发下损坏会话文件，且要等到安装看起来早已成功之后才发作。

每个补丁还有一个 `applied()` 判定，所以重复运行是空操作。

## `flock.js` 守卫的陷阱

上游：

```js
if (platform !== 'linux' && platform !== 'darwin') { throw ... }
```

想当然的 `sed`：

```bash
sed -i "s/platform !== 'linux' && platform !== 'darwin'/& && platform !== 'android'/" file
```

**不幂等**。替换结果仍然以原文本为前缀，所以每次运行都会再次匹配，再追加一条：

```js
// 跑三次之后
if (platform !== 'linux' && platform !== 'darwin'
    && platform !== 'android' && platform !== 'android' && platform !== 'android') {
```

功能上无害，观感很差，而且会让 `--check` 无法区分"打过一次"和"打过很多次"。现在的实现会先检查标记，已存在则跳过。

## koffi 锚点的陷阱

原始脚本用的是：

```awk
/^static StatResult\(/ { infn=1 }
infn && !done && /^#if defined\(__linux__\)$/ { ... }
```

`/^static StatResult\(/` 要求 `(` 紧跟 `StatResult`，但真实签名是：

```c
static StatResult StatAt(int fd, bool fd_is_directory, const char *filename, ...)
```

中间隔着一个函数名。模式永远匹配不上，`infn` 一直是 0，awk 原样输出，`mv` 把它写了回去。脚本随后检查 `grep -q "StatAt"`——那问的是**函数**在不在，不是**补丁**打没打上，所以永远通过。

只改模式仍然不对。`StatAt` 的函数体一直延伸到约 3050 行，里面还有第二处 `#if defined(__linux__)`（第 3048 行），用 `std::chrono` 手工计算 `st_mtim`/`st_ctim`。它不使用 `statx`，在 Android 上不能动。

现在的写法：

```awk
BEGIN { infn = 0; done = 0 }
/^static StatResult[[:space:]]+StatAt\(/ { infn = 1 }
infn && !done && /^#if defined\(__linux__\)$/ {
    print "#if defined(__linux__) && !defined(__ANDROID__)"; done = 1; next
}
{ print }
```

- 匹配真实签名
- 用 `done` 让扫描在第一次替换后立即停止

幂等判定也限定在函数内，而不是整个文件：

```bash
awk '/^static StatResult[[:space:]]+StatAt\(/ { infn = 1; next }
     infn && /^#if defined/ { print; exit }' "$SRC"
```

双向验证过：把文件还原成未打补丁状态再跑一遍，得到与补丁态**逐字节一致**的结果；对已打补丁的文件重跑，md5 不变。

## 为什么安装时必须跳过生命周期脚本

上面的补丁只有在 koffi 有机会被打补丁时才起作用。而直接 `npm install -g @deepseek-ai/dsh` 根本走不到那一步，原因是一个控制流陷阱，而不是编译错误本身。

koffi 声明了 `scripts.install = "node ./cnoke.cjs -P . -D src/koffi --prebuild --release"`。CNoke 的流程是：

1. `checkCompatibility()`——只检查 node 与 NAPI 版本，能过。
2. `checkPrebuild()`——用 Node 去加载这个包来判断绑定是否已可用：`spawnSync(process.execPath, ["-e", "require(process.argv[1])", package_dir])`，看 `proc.status === 0`。
3. 返回 false 时打印 `Failed to load prebuilt binary, rebuilding from source`，然后 `checkCMake()`、`configure()`、`cmake --build`。
4. 构建中任何失败都会重新抛成 `Failed to run build step`，顶层处理器调用 `process.exit(1)`。

`checkPrebuild()` 只有在绑定已经存在时才可能返回 true。全新安装时并不存在，因为 koffi 没有发布 `android-arm64` 预编译包（它的 `optionalDependencies` 覆盖了 linux、darwin、win32、freebsd、openbsd 和 loongarch，唯独没有 android）。所以这个钩子必然掉进第 3 步，必然尝试编译，也必然在 `base.cc:2967` 失败——那正是补丁要修的行，但补丁还够不到这个文件，因为此刻还没有任何东西可打补丁。

npm 的作用是把这件事从"无关紧要"变成"致命"：`install` 脚本非零退出即判定该包安装失败，而全局安装中任何一个包失败都会回滚整个事务。所以最终状态是**根本没有 dsh**，而不是"dsh 装上了但 koffi 坏了"。

在一个干净的 prefix 上用未打补丁的 koffi 实测：

```
$ npm install -g --prefix $TMPDIR/plain @deepseek-ai/dsh
...
Failed to load prebuilt binary, rebuilding from source
... base.cc:2967: error: cannot initialize a member subobject of type '__u32'
    (aka 'unsigned int') with an lvalue of type 'const char *'
make: *** [Makefile:91: all] Error 2
Failed to run build step
$ echo $?
1
```

打破这个循环只有两条路：

- 让编译成功（先打 `base.cc` 再构建）——装之前做不到，鸡生蛋问题；
- 完全跳过这个钩子，事后再补绑定。

`scripts/install-dsh.sh` 走第二条：`--ignore-scripts`，然后 `./install.sh`。最终状态相同甚至更好——第 1 步优先使用预编译绑定而不是源码构建，所以在正常机器上根本用不到 CNoke。

有两点值得知道：

- **任何把 dsh 拉成依赖的全局包都会再触发同一个钩子。** 把 `@deepseek-harness-tui/dsh-tui` 和 dsh 一起装时，koffi 的钩子会再跑一次，因为 koffi 是 `@deepseek-ai/dsh-fs-local` 的硬依赖。那次安装同样要带 `--ignore-scripts`。（`--omit=optional` 不是出路：koffi 是常规依赖，而 dsh 自己的 `optionalDependencies` 是空的。）
- **`--ignore-scripts` 是整棵树生效的，不只针对全局安装本身。** 它同时会静默 `node-pty` 的 `install` 脚本——那个预编译下载器在 Android 上也产不出可用的东西，上游没有发布 `android-arm64` 预编译包，而第 7 步提供的正是它。其余原生包由第 2、3、6 步覆盖。

## 为什么 `sharp` 以 WebAssembly 运行

`sharp` 是 dsh 用到的原生依赖里唯一一个既没有生命周期脚本、也没有可行的本地构建方案的，所以 `--ignore-scripts` 那套说法对它完全不适用。它的加载器（`dist/sharp.cjs`）按固定顺序解析平台绑定，然后抛出大家都见过的那句错：

```
Error: Could not load the "sharp" module using the android-arm64 runtime
```

这个顺序值得知道，因为最后一项才是救 Android 的：

1. `src/build/Release/sharp-<platform>-<version>.node`——包内的源码构建产物。
2. `src/build/Release/sharp-wasm32-<version>.node`——随包发布的 WebAssembly 构建。
3. 一个 `@img/sharp-<platform>-<arch>` 可选依赖，由一段按运行时平台字符串分支的 `switch` 选出。
4. `require("@img/sharp-wasm32/sharp.node")`——通用的兜底。

Android 匹配不上第 3 步的任何分支（`switch` 里没有 `android-arm64`），而它上面的几项也都不存在，因为 `sharp` 的 25 个可选平台包（15 个 binding 包 + 10 个 libvips 配套包）都没有声明 `os: ["android"]`，npm 在安装时就把它们过滤掉了。这就是为什么修法不可能是「装上正确的可选依赖」：`@img/sharp-wasm32` 是一个真实的 npm 包，只是没被声明成可选依赖，所以任何安装器都不会去取它。

为什么是拷贝，而不是直接在 dsh 树里 `npm install`：npm 把那棵树当作 lockfile 的对账目标，凡不是它自己安装的都算多余，会被剪掉——包括第 1–3 步的 koffi、pty 和 system 绑定。第 9 步把三个包（`@img/sharp-wasm32`、`@emnapi/runtime`、`tslib`）暂存在 `$DSH_FIX_WORKDIR/sharp-wasm/`，再拷贝进去。

版本锁定比看上去更要紧。wasm 包里是某一个 sharp 版本对 N-API 可见的那层接口，外加它自带的 libvips；第 9 步读取已安装的 `sharp` 版本，让 npm 精确取该版本的 `@img/sharp-wasm32@<version>`，这样将来 dsh 换了别版本的 sharp，要么拿到匹配的构建，要么这一步直接失败，而不是加载一个版本错位的桥接层。

代价是 CPU 时间：WebAssembly 构建是单线程的，且首次使用时要做模块实例化。在一张 1080×2460 的 PNG 截图上实测（Termux、aarch64）：读元数据约 0.3 s，完整解码约 0.3 s，缩放到 1568 px 再加 JPEG 编码约 0.6 s，WebP 编码约 0.25 s。这比原生绑定慢，用来处理聊天图片完全够用。原生构建还需要针对 bionic 编译 libvips；Termux 打包的是 `libvips 8.18.7`，但用 node-gyp 对着它构建 sharp，涉及面比塞一个版本匹配的 wasm 包大得多。

最后，sharp 是由附件链路惰性 require 的，所以这些包只在第一次图片操作时才会被用到。跑完安装器后请重启 dsh；上面的实测数据也是在这个状态下测得的。

## 语音：为什么 rpath 在 Android 上不管用

这条值得记下来，因为这个失败看起来像"缺库"，会让人一路去查路径。

编译出的 addon 需要 `libsherpa-onnx-c-api.so` 和 `libonnxruntime.so`。常规做法是写个 rpath 让 loader 找到同目录的兄弟文件：

```bash
c++ ... -Wl,-rpath,'$ORIGIN' -o sherpa-onnx.node
```

在 glibc 上这样就行。在 Android 上不行，而且 linker 会明说：

```
WARNING: linker: Warning: "...sherpa-onnx.node" unused DT entry: DT_RPATH
  (type 0xf arg 0x241c) (ignoring)
```

bionic 的 loader **同时忽略 `DT_RPATH` 和 `DT_RUNPATH`**。参与的只有 `LD_LIBRARY_PATH`、按默认路径解析的 `DT_NEEDED`，以及已经加载过的库。dsh 不导出 `LD_LIBRARY_PATH`，而在进程内部再设也太晚了，所以实际可选的方案是：

1. 改 `addon.js`，在 require addon 之前用 `process.dlopen` 逐个加载依赖——本仓库的做法；
2. 把 `.so` 装进默认搜索路径（`$PREFIX/lib`）——能用，但污染共享目录，而且多版本会撞车；
3. 用 shell 包装 dsh 启动并导出 `LD_LIBRARY_PATH`——能用，但 dsh 被别的方式拉起时（服务、快捷方式）就失效了。

方案 1 侵入性最小。注意对普通共享库调 `process.dlopen` 会抛 `Module did not self-register`。这个错误是**预期且无害的**：那时库已经映射进进程了，而这正是我们要的。补丁是有意吞掉它的。

## 语音：glibc 与 bionic

预编译的 `sherpa-onnx-linux-arm64` 二进制依赖：

```
NEEDED  libsherpa-onnx-c-api.so
NEEDED  libonnxruntime.so
NEEDED  libstdc++.so.6
NEEDED  libc.so.6
NEEDED  ld-linux-aarch64.so.1
```

`libc.so.6` 和 `ld-linux-aarch64.so.1` 是 glibc。Termux 的二进制链的是 bionic 的 `libc.so` 和 `libdl.so`。两者之间没有兼容层，所以把 linux-arm64 那份拷到 Android 上不可能跑起来——rpath、`LD_LIBRARY_PATH`、`patchelf` 都救不了。

作为对照，上游的 `android-aarch64-termux-shared` 发布包依赖的是：

```
NEEDED  libandroid.so
NEEDED  liblog.so
NEEDED  libc.so
NEEDED  libc++_shared.so
```

这是 bionic 构建，能加载。它唯一缺的就是那层 N-API 封装，所以第 6 步编译约 18 个 `.cc` 文件并链接到这个发布包，而不是从源码重编 sherpa-onnx 和 onnxruntime（那需要 CMake、protobuf，构建时间非常长）。

## 终端 inspector 的平台守卫

`dsh-subprocess-local` 用一个很小的 switch 构造进程 inspector：

```js
function createProcessInspector(platform = process.platform, arch = process.arch, internals = DEFAULT_INTERNALS) {
	if (platform === "linux") return new LinuxProcessInspector(arch, internals);
	if (platform === "darwin") return new MacProcessInspector(internals);
	if (platform === "win32") return createWindowsProcessInspector();
	throw new Error(`subprocess-local: terminal inspection is unsupported on platform ${platform}`);
}
```

在 Termux 上 `process.platform` 是 `"android"`，所以这里直接抛错——而且是**在插件加载阶段**抛，不是在打开终端时抛，这就是整个终端服务消失而不是降级可用的原因。

`LinuxProcessInspector` 读 `/proc/<pid>/stat`，并在判断进程是否在等 stdin 时读 `/proc/<pid>/task/<tid>/syscall`。这两个都是 Linux 内核接口，Android 原样提供。唯一与架构相关的是一张 syscall 号表：

| | `read` | `select` | `pselect` | `poll` | `ppoll` | `epoll_wait` | `epoll_pwait` |
|---|---|---|---|---|---|---|---|
| x64 | 0 | 23 | 270 | 7 | 271 | 232 | 281 |
| arm64 | 63 | — | 72 | — | 73 | — | 22 |

`arm64` 那一列在 Android 上完全正确，所以 `android` 和「能用的 inspector」之间只隔着一个字符串比较。另外注意未知架构本来就优雅降级——`linuxSyscallTables()` 返回 `undefined`，`isStdinWaiting()` 返回 `false`——可见 syscall 表从来不是那道硬门槛。

## 持久终端：glibc 的 `libutil` 与 bionic

`node-pty` 按 `prebuilds/<platform>-<arch>/pty.node` 找原生绑定，所以 Android 上它要的是 `prebuilds/android-arm64/pty.node`，上游不发这个目录。看起来最省事的办法是复用 `prebuilds/linux-arm64/pty.node`，但它立刻失败：

```
dlopen failed: library "libutil.so.1" not found
```

`forkpty(3)` 和 `openpty(3)` 在 glibc 里属于独立的 `libutil`；在 bionic 里它们是 libc 的一部分。这也解释了为什么 `binding.gyp` 只给 Linux 列了 `'-lutil'`——而给 bionic 编的绑定根本不该链接它。另外两个要避开的 glibc 习惯和 sherpa addon 踩的是同一对坑：不加 rpath（Android 的 linker 忽略 `DT_RPATH`/`DT_RUNPATH`），也不要指望 `libstdc++`（Termux 用 libc++）。

因为问题出在**位置**而不是**行为**，`pty.cc` 本身原样使用。补丁只放宽加载器的候选目录：

```js
var dirs = ['build/Release', 'build/Debug', "prebuilds/".concat(process.platform, "-").concat(process.arch)];
if (process.platform === 'android') {
    dirs.push('prebuilds/' + (process.arch === 'arm64' ? 'linux-arm64' : process.arch));
}
```

既然这个槽位本来就在加载器的候选列表里，问题就纯粹是「把文件放对位置」：在 `prebuilds/android-arm64/pty.node` 放一份 bionic 构建即可，其余什么都不用改。`pty.cc` 用未修改的上游源码，`patch/patch-terminal-android.mjs` 也只动 `dsh-subprocess-local` 的 inspector 门禁——node-pty 本身没有打补丁。

这个补丁的早期版本还往候选列表里追加过 `prebuilds/linux-arm64`。那是多余的，因为 `prebuilds/android-arm64` 本来就在数组里；而且它让报错更难读：加载器只报最后一次错误，于是缺绑定时给出的信息是 `Cannot find module './prebuilds/linux-arm64/pty.node'`，而不是真正缺失的那个路径。

## 移植到其他架构

有四处假设 aarch64：

1. `src/node-addon-system/system.node`——预编译二进制，需重新编译 `system.cc`。
2. `src/node-pty/pty.node`——预编译二进制，用 `scripts/build-node-pty.sh` 重编；加载器按 `process.arch` 找 `prebuilds/android-<arch>`，补丁无需改动。
3. `SYS_renameat2` 回退常量 `276`——见上表。
4. `node-addon-system-android-arm64`——包名必须匹配 `${platform}-${arch}`，因为 `flock.js` 是按这个确切字符串解析的。

第 1、2、4、7 步其余部分与架构无关。第 9 步根本不在这个列表里：WebAssembly 构建在任何主机上都是 wasm32，因此天生与架构无关。
