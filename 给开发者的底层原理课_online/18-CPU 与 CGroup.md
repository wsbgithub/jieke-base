CGroup 的全称是 Control Group，是容器实现环境隔离的两种关键技术之一，它对很多子系统提供精细化的控制的能力，比如下面这些：

- CPU
- 内存
- IO
- 网络



CGroup 的所有操作都是基于 cgroup virtual filesystem，这个文件系统一般挂载在 `/sys/fs/cgroup` 目录下，通过 ls 查看这个目录信息如下：

```
$ ls -l /sys/fs/cgroup 
drwxr-xr-x. 2 root root  0 Dec  6 03:07 blkio
lrwxrwxrwx. 1 root root 11 Dec  6 03:07 cpu -> cpu,cpuacct
drwxr-xr-x. 2 root root  0 Dec  6 03:07 cpu,cpuacct
lrwxrwxrwx. 1 root root 11 Dec  6 03:07 cpuacct -> cpu,cpuacct
drwxr-xr-x. 2 root root  0 Dec  6 03:07 cpuset
drwxr-xr-x. 4 root root  0 Dec  6 03:07 devices
drwxr-xr-x. 2 root root  0 Dec  6 03:07 freezer
drwxr-xr-x. 2 root root  0 Dec  6 03:07 hugetlb
drwxr-xr-x. 2 root root  0 Dec  6 03:07 memory
lrwxrwxrwx. 1 root root 16 Dec  6 03:07 net_cls -> net_cls,net_prio
drwxr-xr-x. 2 root root  0 Dec  6 03:07 net_cls,net_prio
lrwxrwxrwx. 1 root root 16 Dec  6 03:07 net_prio -> net_cls,net_prio
drwxr-xr-x. 2 root root  0 Dec  6 03:07 perf_event
drwxr-xr-x. 2 root root  0 Dec  6 03:07 pids
drwxr-xr-x. 4 root root  0 Dec  6 03:07 systemd
```

通过这个目录，可以看到 CGroup 可以控制的子系统。其中 CPU 和 memory 我们日常关注是最多的，接下来我们来看看 CGroup 与 CPU 相关的内容。


## CPU 与 CGroup

在对应的子系统中创建一个目录就可以创建一个 cgroup 了，我们 cd 进入 cpu 目录，然后创建一个目录 A：

```
$ cd /sys/fs/cgroup/cpu
$ mkdir A
```

cgroup 会自动在 A 目录中创建需要的文件：

```
$ cd /sys/fs/cgroup/cpu
$ ls -l A
total 0
-rw-r--r--. 1 root root 0 Dec 14 02:47 cgroup.clone_children
--w--w--w-. 1 root root 0 Dec 14 02:47 cgroup.event_control
-rw-r--r--. 1 root root 0 Dec 14 02:47 cgroup.procs
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpu.cfs_period_us
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpu.cfs_quota_us
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpu.rt_period_us
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpu.rt_runtime_us
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpu.shares
-r--r--r--. 1 root root 0 Dec 14 02:47 cpu.stat
-r--r--r--. 1 root root 0 Dec 14 02:47 cpuacct.stat
-rw-r--r--. 1 root root 0 Dec 14 02:47 cpuacct.usage
-r--r--r--. 1 root root 0 Dec 14 02:47 cpuacct.usage_percpu
-rw-r--r--. 1 root root 0 Dec 14 02:47 notify_on_release
-rw-r--r--. 1 root root 0 Dec 14 02:47 tasks
```

接下来我们用实际的例子来看 cgroup 实际对 cpu 的控制。还是以之前的 busy 程序为例。


### 限制进程的 CPU 资源占用

启动 busy -j4，启动 4 个死循环的线程，此时在我双核的虚拟机上，进程会跑满 200% 的 CPU 资源。

```
$ ./busy -j4

$ top -p `pidof busy`

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
14839 ya        20   0   39292    380    300 S 200.0  0.0   0:32.66 busy
```

接下来我们把这个进程加入到 cgroup 的 A 组中，只需要把进程号写入到 A 组目录下的 tasks 文件中即可。

```
$ sudo sh -c "echo 14839 > A/cgroup.procs"
```

使用 top 命令查看此时 CPU 的占用情况，还是 200%。

cgroup 提供了 `cpu.cfs_quota_us` 和 `cpu.cfs_period_us` 两个参数限制 CPU 占用的上限。

- cpu.cfs_period_us 表示运行周期，单位为微妙，默认值为 100000us，也就是 100ms。
- cpu.cfs_quota_us 表示在运行周期内这个 cgroup 组所有进程可运行的时间总量，单位同样为微妙，默认值为 -1，也就是不设置上限。

如果我们想限制上面的 busy 进程最多只能占用 30% 的 CPU，可以将 A 组的 cpu.cfs_quota_us 值改为 30000，也就是 100ms CPU 周期内 A 组的进程只能跑 30ms。

```
sudo sh -c "echo 30000 > A/cpu.cfs_quota_us"
```

此时使用 top 命令查看 busy 的占用，就可以看到 cpu 占用在 30% 左右浮动了。

```
$ top -p `pidof busy`

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
14839 ya        20   0   39292    380    300 S  30.0  0.0   7:33.30 busy
```

在多核 CPU 上，cpu.cfs_quota_us 的值可以超过 cpu.cfs_period_us，比如可以设置 cpu.cfs_quota_us 为 200000，表示最多可以占用 200% CPU。


### cpu.shares：多个 cgroup 组的权重划分

前面介绍的是单个 cgroup 组的限制情况，多个组之间也是可以做权重划分的。cpu.shares 可以用来设置各个 cgroup 使用 CPU 的相对值，默认值是 1024。如果 A 组的 cpu.shares 为 512，B 组的 cpu.shares 为 1024，则保证 A 组能使用 33.3% 的 CPU 资源，B 组能使用 66.7% 的 CPU 资源。

接下来我们来做一些实验。还是以之前的 busy 程序为例，开启两个终端，都执行 busy -j4：

```
# 终端 1
$ ./busy -j4

# 终端 2
$ ./busy -j4
```

使用 top 命令来看，这两个进程各占了 100% 左右的 CPU：

```
$ top

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
27473 ya        20   0   39292    380    300 S  99.7  0.0   0:25.98 busy
27517 ya        20   0   39292    380    300 S  99.7  0.0   0:12.08 busy
```

然后创建两个 cgroup 组 group1、group2，将上面两个进程分别添加到两个组里：


```
$ mkdir group1
$ mkdir group2
$ echo 27473 > group1/cgroup.procs
$ echo 27517 > group2/cgroup.procs

$ echo 512 > group1/cpu.shares
```

此时两个进程的 CPU 占用依然是 100% 左右，接下来修改 group1 的 cpu.shares 为  512，group2 的 cpu.shares 值保持默认值 1024。

```
$ top
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
27517 ya        20   0   39292    380    300 S 133.3  0.0  11:30.58 busy
27473 ya        20   0   39292    380    300 S  66.7  0.0  11:22.40 busy
```

此时 group1 的进程 27473 的 CPU 占用从 100% 降低到了 66.7%，group2 的进程 27517 的 CPU 占用从 100% 增加到了 133.3%，这就是因为 group1 和 group2 的 cpu.shares 权重不同带来的 CPU 资源分配上的不同效果。

值得注意的是，cpu.shares 限制的是 CPU 使用的下限，如果 group1 和 group2 的cpu.shares 维持不变，分别为 512 和 1024。在 group2 中的进程占用 CPU 很小的情况下，group1 中的进程依然可以占用超过 1/3 的 CPU 资源。如下所示，group1 的进程 27473 已经跑满了 200% 的 CPU 资源。

```
$ top

  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
27473 ya        20   0   39292    380    300 S 199.3  0.0  16:13.92 busy
```

接下来我们来看看受 cgroup 限制的进程与普通进程的一起运行的情况下，CPU 占用的情况，实验的场景如下。

创建两个 cgroup：group3、group4。

```
$ cd /sys/fs/cgroup/cpu
$ mkdir group3
$ mkdir group4
```

启动三个进程 `./busy -j8`，此时 cpu 占用情况是各占 66.6%：

```
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM     TIME+ COMMAND
 1809 ya        20   0   72076    640    488 S  71.1  0.0   0:55.83 busy
 1689 ya        20   0   72076    640    488 S  70.1  0.0   1:22.07 busy
 1701 ya        20   0   72076    640    488 S  69.4  0.0   1:13.64 busy
```

将其中两个进程分别加入到 group3 和 group4：

```
echo 1689 > group3/cgroup.procs
echo 1701 > group4/cgroup.procs
```

然后来观察者三个进程的占用情况：

```
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU %MEM
 1809 ya        20   0   72076    640    488 S 159.8  0.0
 1689 ya        20   0   72076    640    488 S  19.9  0.0
 1701 ya        20   0   72076    640    488 S  19.9  0.0
```

可以看到没有加到 cgroup 里的普通进程 1809 cpu 占用是 160% 左右，其它两个 cgroup 的进程是 20% 左右。

这是因为每个 cgroup 被当作一个调度单元来竞争 cpu，所以每个 cgroup 得到的 cpu 是 `1/(1+1+8)*200% = 20%`，普通进程是 `8/(1+1+8)*200% = 160%`。



## 一个神奇的 patch：sched_autogroup 

### sched_autogroup 原理

CFS 调度算法是善意的，强调众生平等公平，默认是以 task 为调度单元，这在实际的使用中会有一些小问题。打一个比喻，马爸爸说给全国人民发红包，每个人都发一百块。你家里有 4 口人，就会拿到 400 块，隔壁老王家有 10 口人，那就会拿到 1000 块。以家的维度来看，老王家拿到就多一些。

在软件中也有类似的例子，有一台 2 核的编译服务，如果三个用户 A、B、C 在同时使用，编译是一个 CPU 密集型操作。他们都默认使用 make -j2 来编译，这样 A、B、C 平均分到 1/3 的 CPU，如下图所示：

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/db223398eaba404681363c51bc86e81a~tplv-k3u1fbpfcp-zoom-1.image)

这个时候机智的 A 把编译调整为了 make -j4，这样他就拿到了 1/2 的 CPU，B 和 C 就只能拿到 1/4 的 CPU，如下图所示：

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/09148eea4a0c40919afeff2e929cede3~tplv-k3u1fbpfcp-zoom-1.image)

fake_make 程序的源码如下：

```
int get_job_num(int argc, char *const *argv);
void *busy(void *args) {
    while (1);
}
int main(int argc, char *argv[]) {
    int num = get_job_num(argc, argv);
    printf("job num: %d\n", num);
    pthread_t threads[num];
    int i;
    for (i = 0; i < num; ++i) {
        pthread_create(&threads[i], NULL, busy, NULL);
    }
    for (i = 0; i < num; ++i) {
        pthread_join(threads[i], NULL);
    }
    return 0;
}
```

这种情况在桌面端的体验会更加明显，如果使用 make -j64 编译安卓的同时看电影，如果 make 进程占了大部分 CPU，滑动一下鼠标都会非常卡顿。为了解决部分贪婪进程的问题，linux 引入了 sched_autogroup 的补丁，根据不同的进程类型，放入不同的组中，Linus 盛赞这个 200 行不到的补丁是一个天才的想法。

使用 sysctl 打开 sched_autogroup 特性：

```
$ sudo sysctl -w kernel.sched_autogroup_enabled=1

kernel.sched_autogroup_enabled = 1
```

重新做这个实验，退出登录 A、B、C 用户随后重新登录（备注：不用不同用户也没有问题，只要是重新登录是新会话就行，这里用多用户更好区分），然后执行 busy，A 还是启动 4 个线程，B 和 C 启动两个线程。

```
[A@c4]$ ./fake_make -j4
job num: 4

[B@c4]$ ./fake_make -j2
job num: 2

[C@c4]$ ./fake_make -j2
job num: 2
```

这时查看 CPU 占用的结果如下：

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/1e7dae3c0a924abdbdfd7bf2966c2eae~tplv-k3u1fbpfcp-zoom-1.image)

sched_autogroup 变量将属于同一个会话 session 的进程归为一个会话组，这个会话组可以看做以一个整体进行调度，这里的会话组，其实就是 cgroup。

通过 `/proc/<pid>/autogroup` 文件可以查看每个进程所属的 autogroup 信息。

```
$ cat /proc/7469/autogroup
/autogroup-7974 nice 0

$ cat /proc/8610/autogroup
/autogroup-7974 nice 0
```

可以看到这两个属于同一 session 的进程，都属于 `autogroup-7974` 这一个 cgroup 组

### 进程与会话

进程的会话（session）表示一组进程，这一组进程拥有相同的会话标识符，创建会话的进程被称为 session leader，其进程 id 就是会话 id。

我们在一个 bash 终端启动的进程都属于同一个会话，比如我们以 A 用户登录服务器以后启动三个 sleep 进程放入后台执行，如下所示：

```
$ ps -e -o pid,ppid,user,sid,comm  | grep A
  PID  PPID USER       SID COMMAND
17032 17031 A        17032 bash
18469 17032 A        17032 sleep
18470 17032 A        17032 sleep
18472 17032 A        17032 sleep
```

可以看到这三个 sleep 进程的 session ID 都是 17032，刚好是 bash 进程的 PID。

