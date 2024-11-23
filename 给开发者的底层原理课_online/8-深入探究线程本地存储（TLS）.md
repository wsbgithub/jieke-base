线程本地存储（Thread-Local Storage，简称 TLS）是应用非常广泛的一种编程技巧，用于在多线程环境中为每个线程提供私有的数据存储区域。

在多线程编程中，多线程可以共享访问相同的内存数据，这意味着不同线程可能会同时读写同一份数据，导致数据不一致，这就带来了潜在的线程安全问题。

TLS 提供了一种方式，确保每个线程有自己的变量副本，其他线程不能访问或修改这些私有数据，避免了多线程间的数据的竞争。

TLS 在编程语言中非常多应用场景，比如 `C++` 引入了`thread_local` 关键字，用于声明线程本地变量，Java 通过 ThreadLocal 类提供了线程本地变量的支持。

这个小节我们来深入探究 TLS 的底层实现原理。


## TLS 初探

TLS 使得每个线程看起来都有独立的存储空间，接下来用一个简单的 C 语言的例子来介绍 TLS 的使用：

```c
#include <stdio.h>
#include <pthread.h>

// 定义全局变量
//__thread int g_foo = 0x12345678;
//__thread int g_bar = 0x55555555;

int g_foo = 0x12345678;
int g_bar = 0x55555555;

void *thread_func(void *arg) {
    g_foo += 1;
    g_bar += 2;
    printf("in new  thread, g_foo[%p]=0x%x, g_bar[%p]=0x%x\n", &g_foo, g_foo, &g_bar, g_bar);
    return NULL;
}

int main() {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, thread_func, NULL);
    pthread_create(&t2, NULL, thread_func, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    printf("in main thread, g_foo[%p]=0x%x, g_bar[%p]=0x%x\n", &g_foo, g_foo, &g_bar, g_bar);
    return 0;
}
```

上面的代码中，首先定义了两个全局变量 `g_foo`、`g_bar`，赋值为 0，在两个新线程中修改全局变量的值，然后在 main 线程中打印两个全局变量的值，输出的结果如下：

```c
in new  thread, g_foo[0x601040]=0x12345679, g_bar[0x601044]=0x55555557
in new  thread, g_foo[0x601040]=0x1234567a, g_bar[0x601044]=0x55555559
in main thread, g_foo[0x601040]=0x1234567a, g_bar[0x601044]=0x55555559

```

可以看到三个线程中 `g_foo` 变量的地址是一样的，新线程中修改的 `g_foo` 影响了 main 线程对 `g_foo` 的读取。`g_bar` 变量也是如此。

接下来我们做细微的调整，定义全局变量 `g_foo` 时增加了 `__thread` 关键字，其它不变。

```c
// 定义全局变量
__thread int g_foo = 0x12345678;
__thread int g_bar = 0x55555555;
```

再次编译运行上面的程序，可以看到此时两个线程中 `g_foo` 变量的地址是不一样的，新线程对全局变量 `g_foo` 的修改，并没有影响 main 线程对全局变量 `g_foo` 的读取。

    in new  thread, g_foo[0x7f08ef35d6f8]=0x12345679, g_bar[0x7f08ef35d6fc]=0x55555557
    in new  thread, g_foo[0x7f08eeb5c6f8]=0x12345679, g_bar[0x7f08eeb5c6fc]=0x55555557
    in main thread, g_foo[0x7f08efb6e738]=0x12345678, g_bar[0x7f08efb6e73c]=0x55555555

看起来很神奇，用同一个全局变量名去访问一个变量却得到了不同的结果。接下来我们用 GDB 来看一下加了 `__thread` 以后，程序到底发生了什么变化。

在 thread\_func 函数处加一个断点，然后 r 运行整个程序。

    $ gdb ./tls_test_01

    (gdb) b thread_func
    Breakpoint 1 at 0x400619: file tls_test_01.c, line 9.
    (gdb) r

使用 GDB 的 `disas` 命令查看 `thread_func` 的汇编代码。

```
11      void *thread_func(void *arg) {
   0x000000000040060d <+0>:     push   %rbp
   0x000000000040060e <+1>:     mov    %rsp,%rbp
   0x0000000000400611 <+4>:     sub    $0x10,%rsp
   0x0000000000400615 <+8>:     mov    %rdi,-0x8(%rbp)

12          g_foo += 1;
=> 0x0000000000400619 <+12>:    mov    %fs:0xfffffffffffffff8,%eax
   0x0000000000400621 <+20>:    add    $0x1,%eax
   0x0000000000400624 <+23>:    mov    %eax,%fs:0xfffffffffffffff8

13          g_bar += 2;
   0x000000000040062c <+31>:    mov    %fs:0xfffffffffffffffc,%eax
   0x0000000000400634 <+39>:    add    $0x2,%eax
   0x0000000000400637 <+42>:    mov    %eax,%fs:0xfffffffffffffffc

```

这里出现了 fs 寄存器，我们先来了解一下它。


## FS 寄存器

在 `x86-64` 体系结构中有 6 个段寄存器：`CS, SS, DS, ES, FS, GS`。它们分别用于代码段、堆栈段、数据段、附加段、FS 段、GS 段：

1.  CS（Code Segment）：代码段寄存器，用于存放程序代码访问程序代码段。
2.  SS（Stack Segment）：堆栈段寄存器，用于存放程序堆栈的。
3.  DS（Data Segment）：数据段寄存器，用于存放程序数据的段选择子，访问程序数据段。
4.  ES（Extra Segment）：附加段寄存器，用于存放附加段的段选择子，较少使用。
5.  FS（FS Segment）：FS 段寄存器，用来指向「更多」的附加数据（因为 F 在字母排序在 E 之后）。
6.  GS（GS Segment）：GS 段寄存器，也是用来指向「更多」的附加数据（因为 G 排在 F 后面）。

FS 可以认为是 ES（Extra Segment）的扩展版本，FS 寄存器 X86 架构下的一种特殊的段寄存器，经常被操作系统用来存储线程 TLS 数据，FS 寄存器存放的是一个指针，它指向一个 TLS 结构体（TCB）。

接下来我们用 gdb 来深入探究 FS 寄存器。

GDB 提供了一个 `$fs_base` 的伪寄存器来直接获取 FS 寄存器的值：

    (gdb) info register fs_base
    fs_base        0x7ffff77c2700      140737345496832

用 `thread apply all` 来查看一下当前所有线程的 fs\_base 值：

    (gdb) thread apply all info register fs_base

    Thread 3 (Thread 0x7ffff6fc1700 (LWP 7788) "tls_test_01"):
    fs_base        0x7ffff6fc1700      140737337104128

    Thread 2 (Thread 0x7ffff77c2700 (LWP 7787) "tls_test_01"):
    fs_base        0x7ffff77c2700      140737345496832

    Thread 1 (Thread 0x7ffff7fce740 (LWP 7676) "tls_test_01"):
    fs_base        0x7ffff7fce740      140737353934656

可能很多同学有疑问，为什么要用这个奇奇怪怪的伪寄存器 `$fs_base`，GDB 的 `info register` 不是可以直接看 fs 寄存器的值吗？如果你做动手试一下就会发现，GDB 中的 fs 寄存器的值始终都是 0。

回到上面的汇编代码分析，可以看到 `g_foo += 1` 对应的汇编代码读取 FS 段寄存器指向的内存地址偏移 `-8` 处的值（`$fs - 8`），对该值加 1，然后将结果存回同一内存地址。可以推断出 g\_foo 存储在 `$fs - 8` 地址处，`g_bar` 的值存储在 `$fs - 4` 地址处。

我们可以用 gdb 查看一下是否如此：

    (gdb) info register fs_base
    fs_base        0x7ffff77c2700      140737345496832

    (gdb) x/16bx $fs_base-8
    // 前 4 字节为 g_foo，后 4 字节为 g_bar
    0x7ffff77c26f8:	0x78	0x56 	0x34	0x12 |	0x55	0x55	0x55	0x55
    0x7ffff77c2700:	0x00	0x27	0x7c	0xf7 |	0xff	0x7f	0x00	0x00 

可以看到 g\_foo 和 g\_bar 确实各占 4 字节，分布在 fs 寄存器指向地址的前面 8 字节处。

FS 寄存器存放的是一个指针，它指向一个 TLS 结构体（TCB），代码可以参考 glibc 的 `sysdeps/x86_64/nptl/tls.h` 文件。

```c
typedef struct
{
  void *tcb;		/* Pointer to the TCB.  Not necessarily the
			   thread descriptor used by libpthread.  */
  dtv_t *dtv;
  void *self;		/* Pointer to the thread descriptor.  */
  int multiple_threads;
  int gscope_flag;
  uintptr_t sysinfo;
  uintptr_t stack_guard;
  uintptr_t pointer_guard;
  ...
} tcbhead_t;
```

*   tcb 是一个指向线程控制块（Thread Control Block，TCB）的指针。TCB 是一个数据结构，用于存储与线程相关的所有状态和信息，包括线程 ID、栈信息、信号掩码等等。
*   `self` 是指向线程描述符（Thread Descriptor）的指针。

我们可以得到如下的内存布局图：

![tls](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/00420546714a42a39e7e32422710ff16~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=3870\&h=1033\&s=311713\&e=jpg\&b=ffffff)


## 重看 C 语言中 errno

在 C 语言中，`errno` 是用来表示函数错误状态的全局变量，在单线程环境中，errno 提供了一种简单的方式来报告错误情况。但在多线程环境中，如果多个线程共享同一个 errno 变量，可能会导致错误信息的混淆。为了解决这个问题，errno 在多线程环境中被设计为线程局部（thread-local）变量，确保每个线程都有其自己的 errno 副本，从而避免了多线程间的干扰。

我们可以先来直观感受一下，errno 是否与 TLS 有关，使用 GDB 来检查其地址，来看一下 errno 是不是在 fs\_base 的内存附近。

    (gdb) p/d (unsigned long long ) &errno - $fs_base
    $8 = -128

这表明 errno 位于 fs\_base 指向的地址偏移量 -128 字节的位置。去看 glibc 的代码可以进一步去儿呢，errno 确实是一个被 `__thread` 修饰的线程局部变量。

    extern __thread int errno attribute_tls_model_ie;


## glibc 中 pthread\_self() 是如何实现的

在 glibc 中，`pthread_self()` 函数被用来获取当前线程的 ID，其类型为 pthread\_t，类似于 Java 中 `Thread.currentThread()`。要探究 pthread\_self() 的底层实现，我们可以利用 GDB 的 disas 命令来反汇编 pthread\_self() 函数，来查看其汇编指令：

    (gdb) disas pthread_self
    Dump of assembler code for function pthread_self:
       0x00007ffff7bbcd90 <+0>:     mov    %fs:0x10,%rax
       0x00007ffff7bbcd99 <+9>:     retq   

这段汇编代码执行了两个操作:

1.  它从 FS 段寄存器指向的地址起始位置加上 0x10（16 字节）的偏移处，加载数据到 rax 寄存器。
2.  然后，该代码执行 retq 指令，将 rax 寄存器中的值返回。

可以合理猜测，位于 FS 寄存器起始地址加上 16 字节偏移的位置，很可能存储的是当前线程的句柄或唯一标识符。回看 `tcbhead_t` 结构体的布局，这个汇编指令 `mov %fs:0x10` 实际上是在读取结构体中的 self 字段的值。这个字段通常用于指向线程控制块本身，提供了一种自引用的机制，使得线程能够快速访问自己的控制数据。


## 小结

在 C 语言中，通过使用 \_\_thread 关键字可以声明线程本地变量，使得每个线程拥有独立的变量副本。通过对比使用全局变量和线程本地变量的示例代码，可以直观地看到 TLS 的效果：**全局变量在不同线程中共享，而线程本地变量在不同线程中独立存在**。

底层实现上，TLS 依赖于特定的寄存器（如 x86-64 架构中的 FS 寄存器）来存储线程的 TLS 数据。FS 寄存器指向一个 TLS 结构体（TCB），其中包含了线程的控制信息和局部变量。通过 GDB 的调试，可以深入了解 FS 寄存器的工作机制以及 TLS 数据的存储位置。

此外，C 语言中的 errno 变量在多线程环境中也被设计为线程局部变量，确保每个线程都有其独立的错误状态，避免了多线程间的干扰。

通过对 pthread\_self() 函数的分析，可以看到该函数通过 FS 寄存器快速获取当前线程的控制块，从而实现线程自引用。
