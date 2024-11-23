Linux内核自2.4版本开始引入了Netfilter框架,这是一项重要的网络功能增强。Netfilter框架由Linux内核防火墙和网络维护者 Rusty Russell 所提出和实现。这个作者还基于 netfilter 开发了大名鼎鼎的 iptables，用于在用户空间管理这些复杂的 netfilter 规则。

Netfilter的核心理念是在网络协议栈的关键路径上设置了一系列钩子(hook)点。这些钩子点允许开发者注册自定义的回调函数,使得网络数据包在流经这些点时,可以被相应的函数拦截并进行处理。通过这一机制,Netfilter为Linux内核提供了强大的网络包过滤、网络地址转换(NAT)、连接跟踪等功能。

借助Netfilter框架，开发者无需直接修改内核网络协议栈的复杂代码,只需编写相应的钩子函数模块并注册到合适的钩子点上，即可方便地实现所需的网络功能。这种模块化设计大大提高了Linux内核网络子系统的可扩展性和灵活性。

以收到 ip 包为例，内核处理的代码如下

```c
/*
 * IP receive entry point
 */
int ip_rcv(struct sk_buff *skb, struct net_device *dev, struct packet_type *pt,
	   struct net_device *orig_dev)
{
	struct net *net = dev_net(dev);

    // 做一些基本的数据包检查，如版本检查和头部长度检查，如果数据包有问题，返回 NULL
	skb = ip_rcv_core(skb, net);
	if (skb == NULL)
		return NET_RX_DROP;
    // 调用注册的 PRE_ROUTING 阶段钩子函数
	return NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING,
		       net, NULL, skb, dev, NULL,
		       ip_rcv_finish);
}
```

NF\_HOOK 宏会遍历所有注册的Netfilter钩子函数，并根据它们的返回值决定是否继续处理数据包、丢弃数据包、或将数据包传递给用户空间程序。如果数据包通过了所有钩子，最终会调用`ip_rcv_finish`函数来完成数据包的接收处理。

linux 内核中 netfilter.h 定义的阶段了 netfilter 的 5 大阶段

    enum nf_inet_hooks {
    	NF_INET_PRE_ROUTING,
    	NF_INET_LOCAL_IN,
    	NF_INET_FORWARD,
    	NF_INET_LOCAL_OUT,
    	NF_INET_POST_ROUTING,
    	NF_INET_NUMHOOKS // 这个除外
    };

其中 `NF_INET_NUMHOOKS` 并不是一个处理阶段，我们这里可以忽略之。iptables 的 5 条内置链正好对应 netfilter 的 5 大阶段。

1.  **PRE\_ROUTING**

这是数据包进入网络栈的第一个阶段。在这个阶段,数据包还未进行路由判断,可以在此对进入的数据包进行处理,比如目的地址转换(DNAT)，丢弃某些包等。

2.  **LOCAL\_IN**

当数据包通过路由判断后，如果目的地址是本机，则进入该阶段。可以在此对发往本机的数据包进行处理。

3.  **FORWARD**

当数据包通过路由判断后，如果目的地址不是本机（或者是发往其它网络命名空间），则进入该阶段，这个时候本机角色相当于路由器，可以选择转发或者丢弃。

4.  **LOCAL\_OUT**

本机产生的准备发出数据包在进入网络协议栈时会经过该阶段。可以在此对从本机发出的数据包进行处理，比如源地址转换(SNAT)等。

5.  **POST\_ROUTING**

这是数据包最后一个阶段,在该阶段数据包已经做好发送准备。可以在此对发出的数据包进行最后处理。

通过在这 5 个阶段注册钩子函数，Netfilter 可以实现对数据包的各种处理和过滤，从而构建防火墙、NAT、负载均衡等功能。iptables 就是在 Netfilter 上构建的一个用户态工具,用于配置 Netfilter 的规则。

![netfilter-stage](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/42586a59480e4e52b1f3548b3d247362~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=3308\&h=3404\&s=798272\&e=jpg\&b=fef8f7)

## 实战 1 ：netfilter 的 hello world

接下来我们来看如何写一个内核模块，使得在收到 ICMP 包时，打印 "Hello World" 。首先来看下如何向内核注册 netfilter 的钩子函数。在内核的 netfilter.h 中，nf\_register\_net\_hook 和 nf\_unregister\_net\_hook 用来注册和反注册 netfilter 的 hook。

```c
int nf_register_net_hook(
    struct net *net, 
    const struct nf_hook_ops *ops
);
void nf_unregister_net_hook(
    struct net *net, 
    const struct nf_hook_ops *ops
);
```

这两个函数都有两个参数：

*   net：指向网络命名空间的指针，在大多数情况下我们传递 `&init_net` 即可,表示注册到初始网络命名空间中。
*   ops：指向nf\_hook\_ops结构体的指针，该结构体描述了要注册的网络钩子的属性

`nf_hook_ops` 结构体定义如下:

```c
struct nf_hook_ops {
	/* User fills in from here down. */
	nf_hookfn		*hook;
	struct net_device	*dev;
	void			*priv;
	u_int8_t		pf;
	unsigned int		hooknum;
	/* Hooks are ordered in ascending priority. */
	int			priority;
};
```

其中关键的字段如下：

*   hook: 关键的函数指针，指向钩子函数，用于处理网络数据包。
*   pf: 协议族（protocol family），比如如 PF\_INET(IPv4) 或PF\_INET6(IPv6)。也可以使用 netfilter 中定义的协议族 NFPROTO\_IPV4 或者 NFPROTO\_IPV6。
*   hooknum: 钩子编号，指定钩子函数在网络数据包处理流程中的阶段,如NF\_INET\_PRE\_ROUTING、NF\_INET\_POST\_ROUTING 等。
*   priority: 用于确定多个钩子函数的优先级执行顺序。数值越小，优先级越高。

比如下面这个 nf\_hook\_ops 定义了就是在 PRE\_ROUTING 触发用户自定义的 hook\_func，协议族是 Ipv4，优先级为最高 NF\_IP\_PRI\_FIRST（INT\_MIN）

```c
static struct nf_hook_ops nfho = {
        .hook = hook_func, // 定义钩子函数
        .pf = PF_INET, // 表示 IPv4 协议
        .hooknum = NF_INET_PRE_ROUTING, // 在 PRE_ROUTING 阶段处理数据包
        .priority = NF_IP_PRI_FIRST,  // 最高优先级
};
```

有了上面的基础，我们就可以比较方便的写出 hello world 程序了，代码的注释我已经放在源码中。

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/ip.h>
#include <linux/icmp.h>

// 定义钩子函数
static unsigned int hook_func(
        void *priv,
        struct sk_buff *skb, // 指向 sk_buff 的指针
        const struct nf_hook_state *state
) {
    struct iphdr *iph; // 指向 IP 头的指针
    struct icmphdr *icmph; // 指向 ICMP 头的指针

    if (!skb)
        return NF_ACCEPT;

    // 获取 IP 头部,如果获取失败则返回NF_ACCEPT
    iph = ip_hdr(skb);

    if (!iph)
        return NF_ACCEPT;

    // 检查是否为 ICMP 协议，如果是则获取 ICMP 头部并打印 Hello World
    if (iph->protocol == IPPROTO_ICMP) {
        icmph = icmp_hdr(skb);

        printk(KERN_INFO "Hello World, ICMP Packet Received\n");
    }

    // 无论数据包是否为ICMP协议,最后都返回NF_ACCEPT,允许数据包继续传输。
    return NF_ACCEPT;
}

// 定义钩子操作结构
static struct nf_hook_ops nfho = {
        .hook = hook_func, // 定义钩子函数
        .pf = PF_INET, // 表示 IPv4 协议
        .hooknum = NF_INET_PRE_ROUTING, // 在 PRE_ROUTING 阶段处理数据包
        .priority = NF_IP_PRI_FIRST,  // 最高优先级
};

// 模块初始化函数
static int __init hook_init(void) {
    nf_register_net_hook(&init_net, &nfho); // 注册钩子函数
    return 0;
}

// 模块卸载函数
static void __exit hook_exit(void) {
    nf_unregister_net_hook(&init_net, &nfho); // 注销钩子函数
}

module_init(hook_init);
module_exit(hook_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Arthur.Zhang");
MODULE_DESCRIPTION("A simple module to print Hello World for ICMP packets");
```

写一个 Makefile

    KERNEL_SOURCE := /lib/modules/$(shell uname -r)/build

    obj-m += helloworld.o

    all:
    	make -C $(KERNEL_SOURCE) M=$(PWD) modules

    clean:
    	make -C $(KERNEL_SOURCE) M=$(PWD) clean

编译这个内核模块，不出意外会生成一个 helloworld.ko 文件

```
$ make

$ ls -lrth
-rw-rw-r-- 1 care care 5.4K 4月   9 16:48 helloworld.ko

```

把这个 ko 模块挂载到内核中。

    sudo insmod helloworld.ko

然后找另外一台机器 ping 一下当前机器（192.168.31.197）

    $ ping 192.168.31.197

通过 dmesg 就可以看到日志了

    $ dmesg -T

    [二 4月  9 23:54:14 2024] Hello World, ICMP Packet Received
    [二 4月  9 23:54:15 2024] Hello World, ICMP Packet Received
    [二 4月  9 23:54:16 2024] Hello World, ICMP Packet Received
    [二 4月  9 23:54:17 2024] Hello World, ICMP Packet Received
    [二 4月  9 23:54:18 2024] Hello World, ICMP Packet Received

## 实战 2：实现防火墙禁用 ping

有了这个基础，我们来扩展一下，实现一下禁用 ping，修改前面的代码，在收到 ICMP 包时返回 NF\_DROP，代码如下：

```c
static unsigned int hook_func(
        void *priv,
        struct sk_buff *skb, // 指向 sk_buff 的指针
        const struct nf_hook_state *state
) {
    struct iphdr *iph; // 指向 IP 头的指针

    if (!skb)
        return NF_ACCEPT;

    // 获取 IP 头部,如果获取失败则返回NF_ACCEPT
    iph = ip_hdr(skb);

    if (!iph)
        return NF_ACCEPT;

    // 检查是否为 ICMP 协议，如果是则返回 NF_DROP
    if (iph->protocol == IPPROTO_ICMP) {
        printk(KERN_INFO "ICMP Packet Received, drop it\n");
        return NF_DROP;
    }

    // 无论数据包是否为ICMP协议,最后都返回NF_ACCEPT,允许数据包继续传输。
    return NF_ACCEPT;
}
```

在挂载 `pingdrop.ko` 之前，ping 当前机器，可以看到有 req 和对应的 reply。

    $ sudo tcpdump -i any icmp -nn

    23:13:19.009093 IP 192.168.31.33 > 192.168.31.197: ICMP echo request, id 16691, seq 2, length 64
    23:13:19.009140 IP 192.168.31.197 > 192.168.31.33: ICMP echo reply, id 16691, seq 2, length 64
    23:13:20.011848 IP 192.168.31.33 > 192.168.31.197: ICMP echo request, id 16691, seq 3, length 64
    23:13:20.011891 IP 192.168.31.197 > 192.168.31.33: ICMP echo reply, id 16691, seq 3, length 64

这个时候挂载 `pingdrop.ko`

    sudo insmod pingdrop.ko

从 ping 的发起方看请求都是 timeout

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/dbe64c4350784e978c9347c20e832a0e~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=1304\&h=740\&s=217695\&e=jpg\&b=010101)

这样我们就实现了一个简单的防火墙，禁用了 icmp 请求。

通过上面的两个例子，我们可以看到 netfilter 功能的强大，基于 netfilter 的编程接口，我们还可以实现更多的功能，比如连接跟踪和状态检测、端口扫描监控和封禁、流量限制、NAT、负载均衡等。

## 小结

通过本文,我们全面介绍了 Linux 内核中强大的数据包过滤和处理框架 Netfilter。希望通过这篇文章你能够了解 Netfilter 的主要功能和作用,以及它提供的 API 接口,包括注册钩子函数、数据包处理函数、数据包判断函数和数据包修改函数等，同时介绍 Netfilter 的五大工作阶段:

*   PREROUTING: 用于修改数据包在路由决策之前的目标地址。
*   LOCAL\_IN: 用于处理进入本机的数据包。
*   FORWARD: 用于处理需要转发的数据包。
*   LOCAL\_OUT: 用于处理本机产生的数据包。
*   POSTROUTING: 用于在数据包路由决策之后修改源地址。

最后，我们通过两个实例,演示了如何使用 Netfilter API 编写内核模块,实现 ICMP 包的封禁功能。

希望你可以动手试试，实现一个封禁特定来源 IP TCP 流量模块功能。
