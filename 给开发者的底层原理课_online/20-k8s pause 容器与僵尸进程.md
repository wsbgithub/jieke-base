
在 Kubernetes 中，Pod 是最小的调度单元，由一个或多个容器组成。其中有一个特殊的容器叫做 Pause 容器，它扮演着非常关键的角色：

- 提供共享的 Linux 命名空间；
- 作为 Pod 中 PID 为 1 的进程，管理 Pod 中其他容器的生命周期，“收割”被托管的僵尸进程。

这篇文章我们重点来看 pause 是如何实现收割僵尸进程的。


## pause 容器源码解析


pause 的源码在 k8s 的这个路径下：https://github.com/kubernetes-csi/driver-registrar/blob/master/vendor/k8s.io/kubernetes/build/pause/pause.c


详细的代码解释如下：

```c
static void sigdown(int signo) {
  psignal(signo, "Shutting down, got signal");
  exit(0);
}

// 重点关注这个函数：等待子进程退出，为子进程收尸
static void sigreap(int signo) {
  while (waitpid(-1, NULL, WNOHANG) > 0)
    ;
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; ++i) {
    if (!strcasecmp(argv[i], "-v")) {
      printf("pause.c %s\n", VERSION_STRING(VERSION));
      return 0;
    }
  }

  // 检查自己的 pid 是不是 1，如果不是 1，就打印一行警告信息
  if (getpid() != 1)
    /* Not an error because pause sees use outside of infra containers. */
    fprintf(stderr, "Warning: pause should be the first process\n");
// 接下来注册三个信号处理函数，分别处理 SIGINT、SIGTERM、SIGCHLD
  if (sigaction(SIGINT, &(struct sigaction){.sa_handler = sigdown}, NULL) < 0)
    return 1;
  if (sigaction(SIGTERM, &(struct sigaction){.sa_handler = sigdown}, NULL) < 0)
    return 2;
  if (sigaction(SIGCHLD, &(struct sigaction){.sa_handler = sigreap,
                                             .sa_flags = SA_NOCLDSTOP},
                NULL) < 0)
    return 3;
// 进入无限循环，调用 pause 使进程进入暂停状态，直到收到信号
  for (;;)
    pause();
  fprintf(stderr, "Error: infinite loop terminated\n");
  return 42;
}
```


这里我们重点关注 sigreap 函数，它使用 waitpid 来 reap（回收）等待子进程退出。`waitpid` 的函数签名如下：

```c
pid_t waitpid(pid_t pid, int *status, int options);
```

其中：

* pid：用于指定要等待的目标子进程的进程 ID，大于 0 表示等待指定的子进程 ID，-1 表示等待任意子进程。
* status：用于保存子进程的终止状态。
* options：用于控制 `waitpid()` 的行为。

可以看到 sigreap 指定的参数是 `waitpid(-1, NULL, WNOHANG)`，这里的 pid 为 `-1` 表示等待任何子进程，status 为 NULL 表示不需要获取等待子进程的退出状态。`WNOHANG` 参数表示如果没有已退出的子进程，waitpid 立刻返回而不是阻塞等待。

因此 `sigreap` 的作用就是当 pause 进程收到 `SIGCHLD` 信号（子进程退出）时，通过死循环来调用 waitpid 回收当前所有的僵尸进程，如果没有待回收的僵尸进程，则循环退出。


## 实验复现

为了更好地理解 pause 进程是如何工作的，我们来手动编译 pause，运行 pause 容器，模拟 k8s 中的 pod 的概念，复现僵尸进程的回收。


首先修改一下 pause.c 增加日志：

```c
static void sigreap(int signo) {
    while (1) {
		pid_t pid = waitpid(-1, NULL, WNOHANG);
		if (pid <= 0) {
			break;
		}
		fprintf(stderr, "waitpid return, pid is: %d\n", pid);
    }
}
```

然后编译为二进制文件：

```
gcc -Os -Wall -Werror -static pause.c -o pause
```

接下来写一个 Dockerfile：

```
FROM scratch
ARG ARCH
ADD ./pause /pause
ENTRYPOINT ["/pause"]
```

使用 docker 构建名为 pause-me 的镜像：

```
$ docker build . -t pause-me

$ docker images
REPOSITORY            TAG       IMAGE ID       CREATED         SIZE
pause-me              latest    86088a28cca0   5 seconds ago   851kB
```

然后运行这个镜像：

```
$ docker run --name pause-me pause-me:latest
```

接下来我们运行两个新的容器，openresty 和 redis，并加入到 pause 的 PID namespace 中。

```
docker run -d --pid=container:pause-me openresty/openresty:jammy

docker run -d --pid=container:pause-me redis
```


进入到 openresty 的容器中，使用 ps 查看：

```shell
# ps -ef
UID        PID  PPID  C STIME TTY          TIME CMD
root         1     0  0 09:00 ?        00:00:00 /pause
999         58     0  0 09:16 ?        00:00:02 redis-server *:6379
root       109     0  0 09:27 ?        00:00:00 nginx: master process /usr/local/openresty/bin/openresty -g daemon off;
nobody     115   109  0 09:27 ?        00:00:00 nginx: worker process
root       126     0  0 09:32 pts/0    00:00:00 /bin/sh
root       136   126  0 09:33 pts/0    00:00:00 ps -ef
```

在 openresty 的容器中可以看到 pause 和 redis 的容器，而且 pause 的 pid 为 1。我们就模拟了 k8s 中 pod 的概念，由一组容器组成。

这时候 kill openresty 和 redis 的进程，pause 容器的日志输出里都不会有 waitpid 返回的输出。这是因为这些进程都「没有」变为僵尸进程。


接下来我们来写一个小 demo 来测试一下父进程先退出，子进程睡眠 5s 后退出，这样子进程就会成为一个僵尸进程。

```c
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/wait.h>

int main() {

    // Fork a child process
    pid_t child_pid = fork();

    if (child_pid < 0) {
        perror("fork");
        exit(EXIT_FAILURE);
    } else if (child_pid == 0) {
        // Child process
        sleep(5);
        printf("Child process (PID=%d) exit\n", getpid());
        exit(0); // Exit immediately to create a zombie
    } else {
        // Parent process
        printf("Parent process (PID=%d), child PID=%d\n", getpid(), child_pid);
    }

    return 0;
}
```

把这个程序进行编译：

```
$ gcc -Os -Wall -static zombie_demo.c  -o zombie_demo
```


同样把这个程序打包为 Docker 镜像，Dockerfile 如下：

```
FROM busybox:latest
ADD ./zombie_demo /zombie_demo
ENTRYPOINT ["/zombie_demo"]
```

使用 docker build 构建这个镜像：

```
docker build . -t zombie_demo
```


然后加入到 pause 容器的 pid 命名空间：

```
$ docker run --pid=container:pause-me  zombie_demo

Parent process (PID=32), child PID=38
Parent not reaping child, so it becomes a zombie
```

可以看到，这个时候，父进程 pid 为 32，子进程的 pid 为 38，子进程因为父进程退出，没有调用 waitpid 等待自己退出会变为孤儿进程，随后 5s 退出后，孤儿进程就变为了僵尸进程。


这个时候来看 pause 容器的输出：

```
$ docker run --name pause-me pause-me:latest

waitpid return, pid is: 38
```

可以看到此时 pause 进程收割了 38 号僵尸进程。



## 小结

本文深入探讨了 Kubernetes 中 Pause 容器的源码，通过实验验证了 Pause 容器是如何优雅地收割僵尸进程的。希望通过本文，你能够对 Pause 容器有更深入的理解，并能够动手实践，加深印象。