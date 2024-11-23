

## 进程在 Linux 中长啥样？

为了理解进程相关的概念，需要首先弄懂进程在 Linux 内核中是如何表示的。

在 Linux 中，无论进程还是线程，在内核中都叫 task，用结构体 task_struct 来表示，这个结构比较庞大，源码有几百行之多。我摘取了部分字段放在了下面，可以对 task_struct 有一个大致的了解。如下图所示：

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/51cc3c36fc8444138a9f41ec88994b27~tplv-k3u1fbpfcp-zoom-1.image)

task_struct 包含了很多有用的信息，比如进程的状态 state、进程 pid、进程打开的文件描述符 files、内存管理结构体指针 mm、进程所属的文件系统信息等。


使用 systemtap 可以探究 task_struct 的内部细节，一个简单的模板如下：

```
%{
#include <linux/list.h>
#include <linux/sched.h>
%}

function process_list ()
%{
    struct task_struct *p;
    for_each_process(p) {
        _stp_printf("process: %s, pid: %d", p->comm, p->pid);
    }
%}
probe begin {
    process_list();
    exit();
}
```
通过 for_each_process 方法可以遍历当前系统所有的 task_struct，在 for 循环中就可以获取到 task_struct 的所有内部字段了。



### 进程状态 state

task_struct 结构体中的 state 字段表示进程的状态。

```
struct task_struct {
	volatile long state;	/* -1 unrunnable, 0 runnable, >0 stopped */
	...
}
```

完整的 state 定义在 `include/linux/sched.h` 头文件中。

```
#define TASK_RUNNING		0
#define TASK_INTERRUPTIBLE	1
#define TASK_UNINTERRUPTIBLE	2
#define __TASK_STOPPED		4
#define __TASK_TRACED		8
/* in tsk->exit_state */
#define EXIT_ZOMBIE		16
#define EXIT_DEAD		32
/* in tsk->state again */
#define TASK_DEAD		64
#define TASK_WAKEKILL		128
#define TASK_WAKING		256
#define TASK_PARKED		512
#define TASK_STATE_MAX		1024
```

这些状态会在后面的小节中再详细介绍。


### pid 和 tgid 

task_struct 中与进程 id 的有关的主要是下面这两个：

```c
struct task_struct {
    pid_t pid;
    pid_t tgid;
}
```

那为什么需要两个 id 呢？前面提到过进程和线程本质都是 task_struct，理论上用 pid 就可以唯一标识一个 task 了。

进程中的每个线程的 pid 都不一样，但对外表现出来为一个进程整体，它们有一个共同的 thread group ID，简称 tgid。

以下面的代码为例：

```
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>

void *foo(void *args) {
    sleep(1000);
}

int main() {
    pthread_t t[4];
    int i;
    for (i = 0; i < 4; ++i) {
        pthread_create(&t[i], NULL, foo, NULL);
    }
    for (i = 0; i < 4; ++i) {
        pthread_join(t[i], NULL);
    }
    return 0;
}
```

编译运行上面这段代码：

```
$ gcc pid_tgid_test.c -lpthread 
```

使用 ps -T 可以查看进程所有的线程，这个例子会有 1 个主线程，4 个子线程。

```
$ ps -T -e -o pid,tid,state,command

  PID   TID S COMMAND
13538 13538 S ./a.out
13538 13539 S ./a.out
13538 13540 S ./a.out
13538 13541 S ./a.out
13538 13542 S ./a.out
```

ps 输出中的 PID 实际上是 task_struct 中 tgid，TID 才是真正 task_struct 中的 pid，如下图所示：


![pid_tgid](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/3b233f5ba1c244d5b095cfe1b5a1e96b~tplv-k3u1fbpfcp-zoom-1.image)



### 内存管理 mm

task_struct 跟内存管理相关的最重要的字段是 mm。

```
struct task_struct {
	struct mm_struct *mm;
}
```

每个进程都有自己独立的虚拟地址空间，使用 mm_struct 结构体来管理内存。这里的 mm 指针指向了 mm_struct 结构体，包含了内存资源的页表、内存映射等，它的部分源码如下：

```
struct mm_struct {
	struct vm_area_struct * mmap;		/* list of VMAs */
	struct rb_root mm_rb;
	...
	pgd_t * pgd;
	...
}
```

mm_struct 结构体包含了串联起 VMA 的单链表 mmap。为了更快地查找和分裂更新，这里还有一个红黑树结构表示的 mm_rb。pgd 字段指向 PGD 页表，这部分内容在内存管理的章节会有更详细的介绍。


### 文件与文件系统

task_struct 中跟文件相关在字段最常用的是下面这两个：

```
struct task_struct {
	struct fs_struct *fs;
/* open file information */
	struct files_struct *files;
}
```
task_struct 中的 fs 字段是一个 fs_struct 结构体指针，包含了进程运行的目录信息，比如我们在命令行中 cat 一个文件时，比如 "cat a.txt"，为什么没有指定 a.txt 的绝对路径也可以打开这个文件呢？进程运行的当前目录是保存在 cat 进程的 fs_struct 的 pwd 字段里，通过相对路径去访问 a.txt 时，我们就知道了 a.txt 文件的完整路径是什么。

在 Linux 中一切皆文件，打开的文件属于进程的资源。task_struct 中的 files 字段是一个 files_struct 结构体指针，files_struct 结构体里最重要的就是打开的文件描述符列表。

一个进程启动，系统就默认会分配三个文件描述符，文件描述符 0 表示 stdin 标准输入，文件描述符 1 表示 stdout 标准输出，文件描述符 2 表示 stderr 标准错误输出。后面进程打开文件 fd 从 3 开始分配。以下面的 C 代码为例，使用 open 系统调用打开当前目录的 a.txt 文件，如下所示：

```
#include <stdio.h>
#include <fcntl.h>
int main() {
    int fd = open("a.txt", O_RDONLY);
    printf("fd is %d\n", fd);
    getchar();
    return 0;
}
```

运行上面的代码输出结果如下：

```
$ gcc test.c; ./a.out

fd is 3
```

随后使用 `pidof a.out` 查看这个进程的 pid，这里为 28200，在 linux 的 `/proc/<pid>/fd` 目录里记录了进程打开的所有文件句柄，如下所示：

```
$ ls -l /proc/28200/fd

lrwx------. 1 ya ya 64 Apr 25 21:50 0 -> /dev/pts/2
lrwx------. 1 ya ya 64 Apr 25 21:50 1 -> /dev/pts/2
lrwx------. 1 ya ya 64 Apr 25 21:50 2 -> /dev/pts/2
lr-x------. 1 ya ya 64 Apr 25 21:50 3 -> /home/ya/dev/tmp/a.txt
```
可以看到这个进程打开了 4 个文件，其中 0~2 指向了 /dev/pts/2 这个伪终端，3 号指向了 a.txt 文件。


### 退出码

task_struct 中 exit_code 表示进程的退出码：

```
struct task_struct {
    int exit_code;
}
```

我们后面会介绍子进程退出时，父进程可以通过 waitpid 的方式获取到子进程退出的原因，就是通过这个字段来得到的。

进程的退出有很多种原因，有可能进程正常调用 exit 函数退出，也有可能是被信号杀死，exit_code 值的含义如下：

![process-exitcode](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/fc1cb5eb28f748428e6f18e49271df17~tplv-k3u1fbpfcp-zoom-1.image)


以下面的代码为例：

```
#include <unistd.h>
#include <stdio.h>

int main() {
    pid_t pid;
    pid = fork();

    if (pid == 0) {
        printf("child: %d\n", getpid());
        exit(7);
    } else {
        printf("parent: %d\n", getpid());
        getchar();
    }
    return 0;
}
```

运行后，fork 的子进程通过调用 exit 函数退出变为僵尸进程。我们来用 systemtap 的脚本来查看这个子进程的 exit_code：

```
%{
#include <linux/list.h>
#include <linux/sched.h>
%}

function process_list ()
%{
    struct task_struct *p;
    for_each_process(p) {
        _stp_printf("process: %s, pid: %d, exit_code: 0x%lx\n", p->comm, p->pid, p->exit_code);
    }
%}
probe begin {
    process_list();
    exit();
}
```

运行这段 systemtap 的脚本：

```
$ sudo stap -g task_dump.stp

process: a.out, pid: 2005, exit_code: 0x0
process: a.out, pid: 2006, exit_code: 0x700
```

因为子进程是正常终止，符合图中第一种情况，高八位是退出状态（0x07），低八位全是 0，所以 exit_code = 0x07 << 8 + 0x00 = 0x0700。

接下来稍微修改一下上面的测试程序，让子进程先不退出：

```
#include <unistd.h>
#include <stdio.h>

int main() {
    pid_t pid;
    pid = fork();

    if (pid == 0) {
        printf("child: %d\n", getpid());
        getchar();
    } else {
        printf("parent: %d\n", getpid());
        getchar();
    }
    return 0;
}
```

编译运行上面的程序：

```
parent: 2822
child: 2823
```

然后使用 kill -9 杀掉子进程，再次使用 systemtap 查看进程 exit_code。

```
$ sudo stap -g task_dump.stp

process: a.out, pid: 2822, exit_code: 0x0
process: a.out, pid: 2823, exit_code: 0x9
```

此时的退出码为 0x09，这是因为进程为信号所杀死，符合图中第二种情况 ，低七位表示终止信号，也就是 0x00 << 8 + 0x09 = 0x09。

