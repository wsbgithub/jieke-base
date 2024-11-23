这篇文章我们来介绍 fork 炸弹与进程数量限制相关的知识。


## 进程数量限制

在 Linux 系统中，进程的数量是有上限的，可以通过 `/proc/sys/kernel/pid_max` 进行查看和设置这个上限。在我的 64 位 Centos7.4 机器上，这个默认值为 32768。32 位机器上，pid_max 最大值为 32768，在 64 位的机器上，这个值最大可以到 2^22 次方（约 420 万）。

为了防止单个用户耗尽了所有的进程数，Linux 对单个用户能创建的进程数量也做了限制，使用 ulimit -a 命令可以方便地查看这些限制：

```
$ ulimit -a
-t: cpu time (seconds)              unlimited
-f: file size (blocks)              unlimited
-d: data seg size (kbytes)          unlimited
-s: stack size (kbytes)             8192
-c: core file size (blocks)         0
-m: resident set size (kbytes)      unlimited
-u: processes                       4096
-n: file descriptors                1024
-l: locked-in-memory size (kbytes)  64
-v: address space (kbytes)          unlimited
-x: file locks                      unlimited
-i: pending signals                 7256
-q: bytes in POSIX msg queues       819200
-e: max nice                        0
-r: max rt priority                 0
-N 15:                              unlimited
```

在 "processes" 那一行的 4096 就是当前用户能创建的最大的进程数。


## fork 炸弹

提到进程数量限制，不得不提到著名的进程 fork 炸弹，这是一种通过无限制地创建新进程来耗尽系统资源的攻击方式，最经典的 Fork 炸弹由 Jaromil 在 2002 年设计，仅用 13 个字符实现。其源码如下：

```
:(){:|:&};:
```

这段代码看似简单，但其背后的机制非常巧妙。下面我们详细解析其工作原理。

这段脚本的原理是定义了一个名为` : `的函数，该函数会调用自身两次，并将其放入后台执行，从而导致无限递归。

`:()` 是函数定义，它定义了一个名为 `:` 的函数，函数名可以是任意字符。

`{:|:&}` 是函数体，它包含了一个递归调用和进程控制操作：

* `:`：调用自身，即递归调用。
* `|`：管道操作符，将输出传递给另一个进程，`:|:` 表示把当前函数的一个副本通过管道传递给另一个副本。
* `&`：将进程放入后台执行。

最后的 `:` 表示函数调用，这部分调用了刚刚定义的函数` :`，从而启动了递归过程。


我们也可以用下面的 C 代码来实现类似的功能：

```
#include <unistd.h>

int main(void) {
  while (1)
    if (fork() < 0) {
      sleep(1);
    }
}
```

编译上面的代码，然后将 forkbomb 放在后台执行：

```
gcc -o forkbomb forkbomb.c
./forkbomb &
```

输出的结果如下所示：

```
$ ./forkbomb &
[1] 15936

zsh: fork failed: resource temporarily unavailable
```

这时再在命令行中执行任何命令，都会提示失败：

```
$ ps
zsh: fork failed: resource temporarily unavailable
```

这个时候想杀掉  forkbomb 进程也无法实现，因为执行命令也需要新建一个进程，而 forkbomb 程序已经耗尽了当前用户所有的进程数。即使通过 SSH 登录这台机器也会失败，提示如下：

```
$ ssh ya@c4
shell request failed on channel 0
```

这时我们以 root 用户 ssh 登录这台机器是可以的，因为 forkbomb 程序只是耗尽了普通用户 `ya` 的所有进程数。使用 ps 查看所有用户启动的进程数统计，如下所示：

```
[root@c4 ~]# ps -A -o user | sort | uniq -c
      1 chrony
      1 dbus
      1 polkitd
      5 postfix
     91 root
      1 USER
   4096 ya
```

可以看到 ya 用户正好启动了 4096 个进程，使用 ps 或者 pgrep 统计一下 forkbomb 的进程数量，可以看到一共启动了 4092 个 forkbomb 程序。

```
[root@c4 ~]# pgrep forkbomb | wc -l
4092
```

可以使用 kill 杀掉所有的 forkbomb 进程。

```
[root@c4 ~]# pgrep forkbomb | xargs kill
```

这时在普通用户 ya 下，就可以正常执行所有的命令了。



## Android ADB 提权漏洞 RageAgainstTheCage

弄清楚了进程的数量限制，我们来看看早年非常有名的 Android ADB 提权漏洞 RageAgainstTheCage，这个漏洞被广泛用于 root 工具中。其原理是 adb 开始运行时是以 root 用户运行的，在运行过程中把自己降级为 shell 用户，如下所示：

```c
int adb_main(int is_daemon) {
    // ...
    if (secure) {
        // ...
        /* then switch user and group to "shell" */
        setgid(AID_SHELL);
        setuid(AID_SHELL);
        // ...
    }
}
```

google 的工程师在写这个代码是没有去检查 setgid、setuid 的返回值，想当然地认为从 root 用户把自己降级为 shell 用户一定会成功。

就比如公司董事长下了一个指令，要求把自己的职位变为基层牛马码农，然后就认为已经成为程序员牛马的一员。但是殊不知这个过程不一定会成功，比如公司系统有一个硬性规定，程序员最多只能有 100 人，当前已经招满了 100 人了，董事长想成为程序员的梦想破裂。

利用这个漏洞的过程如下：

- 使用 fork 疯狂创建进程，耗尽 shell 这个用户的进程数量；
- 杀掉 adb 进程，再次 fork，这时候 adb 的 setuid 就失败了；
- 现在的 adb 进程还是以 root 用户运行的，接下来可以为所欲为了。


这个漏洞影响了 Android 2.2 及之前的版本，使得攻击者可以通过 adb 获得 root 权限，从而完全控制设备。不过该漏洞在后续 Android 版本中得到了修复，Google 在 adb 的 setuid 和 setgid 调用后都增加了返回值检查，如果降权失败就会直接退出，避免了权限提升。


## 小结

经过上面的介绍，我们就知道需要特别注意 Linux 系统中进程数量的限制，避免单个用户或系统耗尽进程数量上限，同时在编写权限相关的代码时，一定要检查 setuid/setgid 等系统调用的返回值，确保操作是成功的才继续后面的流程。


