# 技术说明

如果你要修改这些补丁或移植到其他架构，这里是需要知道的实现细节。

简体中文 · [English](technical-notes.md)

## `system.cc` 里的 N-API 接口契约

两个函数都是从 `node-addon-system/lib/flock.js` 反推出来的，细节都不显然。
写错不会崩溃，而是静默地行为异常。

### `tryLock(fd, cb)`

```c
int rc = flock((int)fd, LOCK_EX | LOCK_NB);
int32_t result = (rc == 0) ? 0 : errno;
// cb(result)
```

两个要点：

1. **非阻塞。** `LOCK_NB` 意味着调用从不等待，所以同步实现是正确的，不需要异步。
2. **传正数 errno。** 回调必须收到 `EAGAIN` 的 `11`，而不是 `-11`。
   `flock.js` 用 `getSystemErrorName(-errno)` 转换，而 Node 的
   `getSystemErrorName` 只接受负整数。传负值进去会被再取一次负，得到垃圾结果。

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

`SYS_renameat2` 未定义时回退为 `276`，即 aarch64 的 asm-generic 编号。
**其他架构需要各自的编号**（x86_64：316，arm：382）。由于有 `#ifndef` 保护，
头文件里的正确定义总是优先，所以这只在 libc 不导出该宏的平台上才有影响。

路径被复制进 4096 字节的栈缓冲；超长路径抛 TypeError，而非截断。

## 为什么 `link()` 不是"不支持"那么简单

值得说准确，因为错误的表述会让人去查文件系统配置。

Android 的 SELinux 策略对应用进程的 `link(2)` 返回 `EACCES`，而且这个拒绝
发生在文件系统被查询之前——同一个 `link()` 调用在布局完全相同的普通 Linux 上是成功的。
根据命中的具体策略规则，`errno` 可能是 `EACCES` 或 `EPERM`，所以补丁两个都判。

推论：没有任何挂载选项、`chmod` 或换路径能解决。只有两条路——不用 `link()`，
或者放弃原子性。

## 为什么附件用 `copyFile` 而不是 `renameat2`

附件路径是内容寻址的：目标文件名由内容的 sha256 决定。因此两个并发写入者
产生的是逐字节相同的目标，`copyFile` 竞争是安全的——输家覆盖的是同样的字节。
发布之后的摘要校验照常执行，仍然守住完整性。

会话持久化没有这个性质：每次会话更新产生的暂存文件都不同，
在那里用 `copyFile` 就是真正的后写者覆盖。所以它走系统调用那条路。

## 基于锚点的补丁

`patch-session-persistence.mjs` 用精确子串定位每个改写点，并要求它恰好出现一次：

```js
if (count(src, anchor) !== 1) {
    console.error(`anchor found ${count(src, anchor)} times (expected 1), upstream layout changed`);
    process.exit(1);
}
```

这是**故意做脆**的。用正则或模糊匹配的话，上游一改代码它还能"正常工作"，
却改在错误的位置——而在这一带，改错位置的补丁只在并发下损坏会话文件，
且要等到安装看起来早已成功之后才发作。

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

功能上无害，观感很差，而且会让 `--check` 无法区分"打过一次"和"打过很多次"。
现在的实现会先检查标记，已存在则跳过。

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

中间隔着一个函数名。模式永远匹配不上，`infn` 一直是 0，awk 原样输出，
`mv` 把它写了回去。脚本随后检查 `grep -q "StatAt"`——那问的是**函数**在不在，
不是**补丁**打没打上，所以永远通过。

只改模式仍然不对。`StatAt` 的函数体一直延伸到约 3050 行，里面还有第二处
`#if defined(__linux__)`（第 3048 行），用 `std::chrono` 手工计算
`st_mtim`/`st_ctim`。它不使用 `statx`，在 Android 上不能动。

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

双向验证过：把文件还原成未打补丁状态再跑一遍，得到与补丁态**逐字节一致**的结果；
对已打补丁的文件重跑，md5 不变。

## 语音：为什么 rpath 在 Android 上不管用

这条值得记下来，因为这个失败看起来像"缺库"，会让人一路去查路径。

编译出的 addon 需要 `libsherpa-onnx-c-api.so` 和 `libonnxruntime.so`。
常规做法是写个 rpath 让 loader 找到同目录的兄弟文件：

```bash
c++ ... -Wl,-rpath,'$ORIGIN' -o sherpa-onnx.node
```

在 glibc 上这样就行。在 Android 上不行，而且 linker 会明说：

```
WARNING: linker: Warning: "...sherpa-onnx.node" unused DT entry: DT_RPATH
  (type 0xf arg 0x241c) (ignoring)
```

bionic 的 loader **同时忽略 `DT_RPATH` 和 `DT_RUNPATH`**。参与的只有
`LD_LIBRARY_PATH`、按默认路径解析的 `DT_NEEDED`，以及已经加载过的库。
dsh 不导出 `LD_LIBRARY_PATH`，而在进程内部再设也太晚了，所以实际可选的方案是：

1. 改 `addon.js`，在 require addon 之前用 `process.dlopen` 逐个加载依赖 ——
   本仓库的做法；
2. 把 `.so` 装进默认搜索路径（`$PREFIX/lib`）—— 能用，但污染共享目录，
   而且多版本会撞车；
3. 用 shell 包装 dsh 启动并导出 `LD_LIBRARY_PATH` —— 能用，但 dsh 被别的
   方式拉起时（服务、快捷方式）就失效了。

方案 1 侵入性最小。注意对普通共享库调 `process.dlopen` 会抛
`Module did not self-register`。这个错误是**预期且无害的**：那时库已经映射进进程了，
而这正是我们要的。补丁是有意吞掉它的。

## 语音：glibc 与 bionic

预编译的 `sherpa-onnx-linux-arm64` 二进制依赖：

```
NEEDED  libsherpa-onnx-c-api.so
NEEDED  libonnxruntime.so
NEEDED  libstdc++.so.6
NEEDED  libc.so.6
NEEDED  ld-linux-aarch64.so.1
```

`libc.so.6` 和 `ld-linux-aarch64.so.1` 是 glibc。Termux 的二进制链的是 bionic
的 `libc.so` 和 `libdl.so`。两者之间没有兼容层，所以把 linux-arm64 那份拷到
Android 上不可能跑起来——rpath、`LD_LIBRARY_PATH`、`patchelf` 都救不了。

作为对照，上游的 `android-aarch64-termux-shared` 发布包依赖的是：

```
NEEDED  libandroid.so
NEEDED  liblog.so
NEEDED  libc.so
NEEDED  libc++_shared.so
```

这是 bionic 构建，能加载。它唯一缺的就是那层 N-API 封装，所以第 6 步编译
约 18 个 `.cc` 文件并链接到这个发布包，而不是从源码重编 sherpa-onnx 和
onnxruntime（那需要 CMake、protobuf，构建时间非常长）。

## 移植到其他架构

有三处假设 aarch64：

1. `src/node-addon-system/system.node` —— 预编译二进制，需重新编译 `system.cc`。
2. `SYS_renameat2` 回退常量 `276` —— 见上表。
3. `node-addon-system-android-arm64` —— 包名必须匹配 `${platform}-${arch}`，
   因为 `flock.js` 是按这个确切字符串解析的。

第 1、2、4 步与架构无关。
