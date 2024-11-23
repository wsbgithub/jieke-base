在 Linux 中 SCHED_NORMAL 的调度策略一般属于 CFS（Completely Fair Scheduler，完全公平调度），这个调度器为不同的进程提供了完全公平的调度，其本质是一个基于权重的优先级调度算法，保证不会有进程会长时间得不到运行时间片进入饥饿。调度器充当了法官的角色，总是查找运行进程中受到最不公平待遇的进程，调度此进程让其运行。


## 虚拟执行时间（vruntime）

CFS 算法通过进程的虚拟时间（vruntime）来平衡运行中进程的 CPU 时间片。CPU 提供了一个时钟，隔一段时间都会触发一次 tick，随着 tick 的推进，在 CPU 上运行的进程的 vruntime 也会增加。此时没有执行的进程的 vruntime 不增加。

每个进程都有一个 vruntime 值，每次需要调度时，就选取运行队列中 vruntime 最小的那个进程来运行。

CFS 算法中，进程的优先级被弱化，强调更多的是进程的权重（weight）。权重大的进程，其虚拟时钟比真实时钟跑得慢，vruntime 增加较慢。优先级低，也就是权重小的进程，其虚拟时钟比真实时钟跑得快，vruntime 增加较快。

接下来以一个实际的例子来看看，有 A、B、C 三个进程，这三个当前权重比例分别是 1/2、1/4、1/4，假设进程 A 获得一次 CPU 调度 vruntime 增加 2，根据上面的介绍，B 和 C 进程每次调度 vruntime 会增加 4。

接下来我们来按时间顺序推导 vruntime 的变化过程。假定后面 vruntime 相同的的情况下，执行顺序是 A 先于 B 先于 C，这个先后顺序对最终的结果没有影响。

假设一开始 vruntime 都为 0。

- 第 1 个时间片，进程 A 得到调度执行，vruntime 增加 2，B 和 C 的 vruntime 为 0。
- 第 2 个时间片，进程 B 和 C 的 vruntime 比 A 小，这里 B 被调度执行，vruntime 增加到 4。
- 第 3 个时间片，进程 C 被调度执行，vruntime 增加到 4。
- 第 4 个时间片 A 被重新调度执行，vruntime 增加到 4。
- 接下来的过程完全类似。

整个过程如下图所示：

![vruntime](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/31662da881294fd29222beb54f0f43ae~tplv-k3u1fbpfcp-zoom-1.image)


可以看到从拉长时间来看，权重高的 A 进程执行的次数比 B 和 C 多一倍，这正是进程权重对调度的影响。



## 普通进程与 nice 值

对于普通进程而言，一般不说优先级，而是用 nice 值。

nice 如其字面意思，表示一个进程的友好程度，索取越多，越不 nice。在 Linux 中 nice 值的范围为 `-20`~`+19`，默认情况下，普通进程的 nice 值为 0。


### nice 值对 vruntime 的影响

vruntime 的具体计算方式如下：

> vruntime += 实际运行时间 delta_exec * NICE_0_LOAD / 权重

其中 NICE_0_LOAD 表示 nice 值为 0 的进程的权重，delta_exec 代表当前进程本次运行时间。

Linux 维护了一个 nice 值优先级到权重的映射关系表，nice 值为 0 的进程的权重是 1024。


```
static const int prio_to_weight[40] = {
 /* -20 */     88761,     71755,     56483,     46273,     36291,
 /* -15 */     29154,     23254,     18705,     14949,     11916,
 /* -10 */      9548,      7620,      6100,      4904,      3906,
 /*  -5 */      3121,      2501,      1991,      1586,      1277,
 /*   0 */      1024,       820,       655,       526,       423,
 /*   5 */       335,       272,       215,       172,       137,
 /*  10 */       110,        87,        70,        56,        45,
 /*  15 */        36,        29,        23,        18,        15,
};
```

nice 值为 -5 的权重值为 3121，差不多是 nice 值为 0 的进程的三倍。

```
vruntime（NICE:-5） += delta_exec * 1024 / 3121
```

也就是：

```
vruntime（NICE:-5） += delta_exec / 3
```


对于一个 nice 值为 0 的进程而言，vruntime 计算方式如下：

```
vruntime（NICE:0） += delta_exec
```

也就是说，nice 值为 -5 的进程执行三次左右才会跟 nice 值为 0 的进程增加的 vruntime 差不多。

我们来做一个实验，启动两个 busy -j2 进程，默认情况下，在我的双核虚拟机上，这个两个进程平分了 200% 的 CPU 资源，各占了 100% 的 CPU。

```
$ top

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
20342 ya        20   0   22900    380    300 S 100.0  0.0   0:26.16 busy
20416 ya        20   0   22900    384    300 S  99.7  0.0   0:07.57 busy
```

接下来我们使用 renice 命令设置其中一个进程的 NICE 值：

```
$ sudo renice -n -5 -g 20342

20342 (process group ID) old priority 0, new priority -5
```

此时 top 命令的 CPU 占用已经出现了改变：


```
$ top

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
20342 ya        15  -5   22900    380    300 S 149.8  0.0   2:17.38 busy
20416 ya        20   0   22900    384    300 S  49.2  0.0   1:46.84 busy
```

nice 值为 -5 的进程 CPU 占用率提高到了 150%，nice 值为 0 的进程 CPU 占用率降低到了 50%。这里三倍之差，正是 nice 值带来的 3121:1024 的权重影响。


### 调度周期

在 CFS 中，有一个概念叫延迟目标（latency target），意思是让每个可运行进程在 latency target 的时间间隔都至少有机会运行一次。如果 latency target 为 10ms，现在有两个相同优先级进程待运行，则每个 10ms 的时间间隔中每个进程会分到 5ms，如果有十个进程，则每个进程在这 10ms 内会分到 1ms。

这个时间间隔由系统变量 `/proc/sys/kernel/sched_latency_ns` 决定，表示一个调度周期，以纳秒为单位。

```
$ cat /proc/sys/kernel/sched_latency_ns
                                                                      
12000000
```

在我的 CentOS 7 机器上，这个值为 12000000 ns，也就是 12ms，也就是每个进程等待 CPU 的时间最长不超过 12ms。

CFS 算法远没有想象的那么简单，接下来就几个问题做一下深入的分析。


首先来看：如果进程数量过多，会不会造成每个进程执行的时间片非常短？

前面提到 CPU 的调度间隔由 sched_latency_ns 变量决定，如果进程的数量过多，每个进程执行的时间就不会非常短。还是以 latency target 等于 10ms 为例，如果有 1000 个进程，则每个进程只能分到 0.01ms，这样会带来大量的进程切换。

CFS 也考虑到了这个问题，引入了进程占用 CPU 的最小时间 sched_min_granularity_ns 变量。如果运行进程数 `nr_running * sched_min_granularity_ns` 大于调度周期 sched_latency_ns 的话，那么后面调度周期将由 `sched_min_granularity_ns * nr_running` 决定。这样就不会出现因为进程数过多带来的单个进程获取的 CPU 时间片太小的问题，只是调度周期会变长。

可以用下面的公式来理解 CFS 的调度周期：

```
period = max(sched_latency_ns, sched_min_granularity_ns * nr_tasks)
```


在 Linux 中，这个值由 `/proc/sys/kernel/sched_min_granularity_ns` 决定。

```
$ cat /proc/sys/kernel/sched_min_granularity_ns

10000000
```

这个值在我的 Centos7 机器上值为 10ms。


> 新创建的进程 vruntime 是 0 吗？
    
根据前面的描述，vruntime 最小的进程会最优先被调度，如果新创建的进程 vruntime 为 0，那么对于老进程就太不公平了。于是 CFS 为每个运行队列维护了整个队列 vruntime 的最小值（min_vruntime），进程初始的 vruntime 会被限制不会小于 min_vruntime。

除了有上面的限制之外，新创建的进程的 vruntime 还与下面两个属性有关系。

- 调度特性 START_DEBIT；
- 系统变量 kernel.sched_child_runs_first。

**1. START_DEBIT**

START_DEBIT：如果这个调度特性 bit 位被设置，新进程的第一次运行要有一定延迟才会被调度，本质是把新进程的 vruntime 设置得更大一些。

**2. kernel.sched_child_runs_first**

如果这个值为 1，则新创建的子进程要先于父进程执行。

内核中的实现是其对比了子进程和父进程的 vruntime，在 kernel.sched_child_runs_first 的值为 1 的情况下，如果父进程的 vruntime 大于子进程，则会对调父子进程的的 vruntime，这样子进程就会先于父进程被调度执行。



## CFS 调度算法的底层结构

CFS 需要有一个高效的数据结构来支撑对 vruntime 进行排序，同时 vruntime 变化得非常频繁，更新以后也需要很快的重新排序。

为了支持 CFS 调度算法，Linux 底层使用红黑树来管理这些待运行的进程，平衡了查找最小值和更新速度。红黑树是一颗平衡树，越左侧节点的虚拟运行时间值越小，进程再次被调度的可能性越高。

红黑树中每个节点上保存的是进程（线程）虚拟运行时间（vitrual runtime），如下图所示：


<p align=center><img src="https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/efb9000470b84166811cbc36c3feda73~tplv-k3u1fbpfcp-zoom-1.image" alt=""  width="70%"/></p>

查找最左侧节点的的复杂度为 O(1)，非常适合 CFS 调度算法用来查找运行进程中受到最不公平待遇的进程。


## 从 CFS 看 CPU 密集型和 IO 密集型应用

CPU 密集型的进程对 CPU 的性能要求比较高，要求多数时间花在 CPU 上面做计算，比如常见的视频转码等。IO 密集型的应用对 CPU 的性能要求不高，但对能及时抢到 CPU 很敏感。

前面提到的 vruntime 的计算公式： `vruntime += 实际运行时间 delta_exec * NICE_0_LOAD / 权重`

对于 IO 密集型的应用，delta_exec 增长得比较慢，对应进程（线程）的 vruntime 增加就慢一些，在它 IO 事件 ready 想要被调度执行时，因为 vruntime 小，就更容易被 CFS 选中执行，不能让老实人吃亏啊。

从这个角度来看，CFS 对 IO 密集型的应用也做好很好的兼顾。