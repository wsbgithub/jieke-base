在多核处理器上，每个核心都有自己的 TLB（Translation Lookaside Buffer），专门用来加快虚拟地址到物理地址的转换，它比内存要快得多。TLB 缓存了地址转换中出现最频繁的那些地址，无需访问内存中的页表即可从 TLB 中直接获得地址数据，因而大大加速了地址转换，TLB 可以理解为页表的 cache。

在多核处理器上进程切换频繁，虚拟内存页表更新以后，之前进程的 TLB 随之失效，需要重新刷新，频繁的 TLB 失效会对性能带来很大的影响。

于是 Linux 中提供了 CPU 亲和性（cpu affinity）的特性，它指的是可以指定进程固定在某一个或某几个 CPU 核上运行，俗称为绑核。

一个典型的场景是 Nginx。Nginx 采用一个 master 进程和多个 worker 进程的架构，在多核处理器上，多个 worker 进程被调度到不同的 CPU 上执行。于是 Nginx 也提供的配置参数，允许将 worker 进程绑定到指定的 CPU 上。

Nginx 的 CPU 亲和性配置比较简单，通过 worker_cpu_affinity 指令配置即可。比如一个可能的配置项如下：

```
worker_processes    4;
worker_cpu_affinity 0001 0010 0100 1000;
```

worker_cpu_affinity 后面的数字表示 0~n 号 worker 进程的 CPU 二进制掩码，这里配置就可以让 0 号 master 进程运行在 0 号 CPU 上，1 号 master 进程运行在 1 号 CPU 上，以此类推。如果想让某一个 worker 进程运行在第 0 号和 第 1 号两个 CPU 上，可以将对应的 CPU 掩码设置为 0011。

通过 ps 命令可以进程的 affinity：

```
$ ps -efHF | grep nginx

UID        PID  PPID  C    SZ   RSS PSR STIME TTY          TIME CMD
www-data 16275  1840  0 35946  6304   0 02:13 ?        00:00:00     nginx: worker process
www-data 16276  1840  0 35946  6304   1 02:13 ?        00:00:00     nginx: worker process
www-data 16277  1840  0 35946  6304   2 02:13 ?        00:00:00     nginx: worker process
www-data 16279  1840  0 35946  6304   3 02:13 ?        00:00:00     nginx: worker process
```

其中 PSR 列对应的就是当前进程所在的 CPU 号，可以看到这四个 worker 进程都绑定到了特定的核上了。


## taskset

Linux 提供了一个 taskset 命令修改进程的 CPU 亲和性。以下面的 busy 程序为例：

```
./busy -j4
```

在我的双核机器上，这个进程跑满了 200% 的 CPU，此时执行 taskset 命令将这个进程绑定到 1 号 CPU 上。

```
$ taskset -cp 1 `pidof busy`
pid 29852's current affinity list: 0,1
pid 29852's new affinity list: 1
```

执行完以后发现 CPU 并没有降下来，依然是 200%，这是因为 taskset 从名字也可以看出来，它是对 task 进行设置，而不是对整个进程。通过 ps 也可以看得出来。

```
$ ps -T -eF | grep busy
UID        PID  SPID  PPID  C    SZ   RSS PSR STIME TTY          TIME CMD
ya       29852 29852  5403  0  5725   380   1 22:32 pts/15   00:00:00 ./busy -j2
ya       29852 29853  5403 60  5725   380   0 22:32 pts/15   00:12:26 ./busy -j2
ya       29852 29854  5403 60  5725   380   1 22:32 pts/15   00:12:27 ./busy -j2
```

可以看到 busy 进程中有三个线程，29852、29853、29854，其中 29852 是 main 线程，负责启动两个死循环线程 29853 和 29854。经过上面的 taskset 设置，只是把主线程 29852 绑到了第 1 个 CPU。其它两个线程并有做绑定，29853 线程还是跑在第 0 个 CPU 上。


如果要对整个进程的所有线程设置 affinity，可以加上 -a 参数。


```
$ taskset -a -cp 1 `pidof busy`
pid 29852's current affinity list: 0,1
pid 29852's new affinity list: 1
pid 29853's current affinity list: 0,1
pid 29853's new affinity list: 1
pid 29854's current affinity list: 0,1
pid 29854's new affinity list: 1
```

此时再次查看 top，busy 进程的 CPU 就下降到 100% 了。

```
$top

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
29852 ya        20   0   22900    380    300 S 100.3  0.0   4:00.66 busy
```




## 代码中设置 affinity

通过下面两个函数可以设置和获取线程的 affinity：

```
#define _GNU_SOURCE
#include <sched.h>
int sched_setaffinity(pid_t pid, size_t len, const cpu_set_t *set);
int sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *set);
```

sched_setaffinity 的第一个参数实际是线程 id，size 是第三个 set 参数的字节数，也就是 sizeof(cpu_set_t)。最后一个参数 set 是一个位掩码，数据类型为 cpu_set_t。简单的用法如下所示：

```
cpu_set_t mask;
const size_t size = sizeof(mask);
CPU_ZERO(&mask);
CPU_SET(1, &mask);

sched_setaffinity(pid, size, &mask);
```

这样就把 pid 线程绑定到了第 1 号 CPU 上。

Java 中没有提供设置 affinity 的方法，有一个开源项目通过 jni 的方式提供了这一能力：[Java-Thread-Affinity](https://github.com/OpenHFT/Java-Thread-Affinity) ，它的核心原理也是通过 sched_setaffinity 来设置线程的 CPU 亲和性。


## 超线程

超线程（Hyper-Threading，HT）是 Intel 在 2002 年推出的一种硬件技术，它允许单个物理 CPU 核心模拟两个逻辑 CPU 核心，从而可以在单个物理核心上同时运行多个线程。

在超线程下，每个线程都有自己的程序计数器（PC）、寄存器，对于 CPU 而已，访问内存可能需要几百个时钟周期，当一个线程由于等待内存访问或其他原因而暂停时，CPU 就可以切换到另一个线程上继续执行，从而充分利用了 CPU 的执行资源，提高了整体吞吐量，提高了 CPU 的利用效率。


## 如何知道当前机器是否开启了超线程

我们可以 lscpu 来查看，在我的机器上，它的输出如下：

```
$ lscpu
Architecture:        x86_64
CPU op-mode(s):      32-bit, 64-bit
Byte Order:          Little Endian
CPU(s):              12
On-line CPU(s) list: 0-11
Thread(s) per core:  2
Core(s) per socket:  6
Socket(s):           1
NUMA node(s):        1
Vendor ID:           GenuineIntel
CPU family:          6
Model:               158
Model name:          Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz
Stepping:            10
CPU MHz:             1252.550
CPU max MHz:         4600.0000
CPU min MHz:         800.0000
BogoMIPS:            6399.96
Virtualization:      VT-x
L1d cache:           32K
L1i cache:           32K
L2 cache:            256K
L3 cache:            12288K
NUMA node0 CPU(s):   0-11
```

这里判断 CPU 是否开启超线程的关键信息是：

```
Thread(s) per core:  2
Core(s) per socket:  6
Socket(s):           1
CPU(s):              12
```


这里表示每个 CPU 核上有 2 个线程，CPU 有 6 个物理核心，也就是说，每个核心被模拟为了两个逻辑 CPU，总的逻辑 CPU 数是 12。


在我的云主机上 lscpu 的结果如下：

```
ubuntu@VM-12-5-ubuntu:~$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         46 bits physical, 48 bits virtual
  Byte Order:            Little Endian
CPU(s):                  4
  On-line CPU(s) list:   0-3
2.50GHz
    CPU family:          6
    Model:               85
    Thread(s) per core:  1
    Core(s) per socket:  4
    Socket(s):           1
    Stepping:            5
```

可以看到 Thread(s) per core 为 1，有 4 个物理核心，没有开超线程。



## 如何知道哪两个逻辑 CPU（超线程）属于一个 CPU

可以 `/sys/devices/system/cpu/cpu{x}/topology/thread_siblings_list` 查看两个超线程是成对的，比如在我的机器上，0 号和 6 号超线程是成对的，1 号和 7 号是成对的。
 
```shell
$ cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
0,6
$ cat /sys/devices/system/cpu/cpu1/topology/thread_siblings_list
1,7
$ cat /sys/devices/system/cpu/cpu2/topology/thread_siblings_list
2,8
```

## 小结

这篇文章介绍了 CPU 亲和性和超线程相关的内容。在多核处理器上，CPU 亲和性（CPU affinity）可以显著提高性能。通过将进程或线程绑定到特定的 CPU 核心，可以减少频繁的 TLB 失效，提高地址转换效率。Nginx 和 Java-Thread-Affinity 等工具和库提供了便捷的配置和管理方法。

此外，我们还介绍了超线程相关的知识，超线程技术进一步提升了 CPU 利用率。通过合理配置和使用这些技术，可以显著优化系统性能。


