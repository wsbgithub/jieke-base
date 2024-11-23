epoll 是 Linux 下的最成熟高效 I/O 多路复用机制,在需要同时处理大量文件描述符的场景下,epoll 相比传统的 select 和 poll 方式,有着显著的性能优势。epoll 自 Linux 2.6 内核版本引入以来,已经成为高性能网络服务器的必备利器。

epoll 为何如此高效?它在内核中是如何实现的?这篇文章将通过深入研究 epoll 在 Linux 内核中的源码实现,揭开 epoll 的神秘面纱。希望通过阅读本文,你可以对 epoll 的底层运作机制有一个清晰而全面的认识，有助于更好地使用 epoll 进行高性能网络编程,也能加深对 Linux 内核等待队列、事件通知等知识点的理解。

## file\_operations

Linux 对文件的操作做了很高层的抽象，它并不知道每种具体的文件应该怎样打开、读写，Linux 让每种设备类型自己实现 struct file\_operations 结构体中定义的各种函数。

```c
struct file_operations {
	loff_t (*llseek) (struct file *, loff_t, int);
	ssize_t (*read) (struct file *, char __user *, size_t, loff_t *);
	ssize_t (*write) (struct file *, const char __user *, size_t, loff_t *);
	unsigned int (*poll) (struct file *, struct poll_table_struct *);
	// ...
} 
```

## file\_operations 与 poll 函数

不是所有的文件类型都支持 select/poll/epoll 函数，比如普通文件类型就不支持。

为了支持 epoll 等函数，文件类型必须实现 file\_operations 函数列表中的 poll 函数。值得注意的是这里的 poll 与 select/poll/epoll 中的 poll 不是一回事，也不是系统调用 poll。

poll 函数的作用是：

*   将**当前线程**加入到设备驱动的**等待队列**，并设置回调函数。这样设备上有事件发生时才知道唤醒通知哪些线程，调用这些线程的什么方法
*   检查此刻已经发生的事件，`POLLIN、POLLOUT、POLLERR` 等，以掩码的形式返回

## 等待队列是什么

等待队列是 Linux 内核中非常核心的数据结构，在异步事件通知、跨进程通信中广泛使用。理解了等待队列就理解了 `epoll` 的一半内容。

等待队列包含等待队列头(`wait_queue_head`)和等待队列项(`wait_queue_t`) 这两个重要的数据结构。两者都包含了一个类型为 `list_head` 的双向链表项。链表头和多个列表项串联成一个双向链表。

```c
struct wait_queue_entry {
	unsigned int     flags;
	void          *private; // 指向等待队列的进程 task_struct
	wait_queue_func_t	func; // 唤醒时执行的函数
	struct list_head	entry;  // 链表元素
};

struct wait_queue_head {
	spinlock_t		lock;
	struct list_head	head;
};
struct list_head {
	struct list_head *next, *prev; // 双向链表
};
```

![wait\_queu](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/ddad59f063e5474584d26f3f72b80670~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=3791\&h=1354\&s=565678\&e=jpg\&b=ffffff)

> 为什么 list\_head 结构体根本就没有数据属性？

list\_head 结构体确实没有除 `next` 和 `prev` 指针以外的数据属性，这是因为它的设计遵循了一种称为「intrusive lists」的设计思想。

什么是「intrusive lists」呢？我用一个最简单的 demo 你应该就能理解了。

```c
#include <stdio.h>

struct list_head {
    struct list_head *next, *prev;
};
struct my_item {
    long data;
    struct list_head list;
};

// 在链表中插入一个新节点
void list_add(struct list_head *new, struct list_head *prev, struct list_head *next) {
    next->prev = new;
    new->next = next;
    new->prev = prev;
    prev->next = new;
}

// 在链表头部添加一个新节点
void list_add_head(struct list_head *new, struct list_head *head) {
    list_add(new, head, head->next);
}

int main() {

    // 初始化链表
    struct list_head list;
    list.next = &list;
    list.prev = &list;

    struct my_item item1, item2, item3;
    item1.data = 100;
    item2.data = 200;
    item3.data = 300;
    // 将 item1 添加到链表头部  head -> item1 -> head
    list_add_head(&item1.list, &list);
    // 将 item2 添加到链表头部, head -> item2 -> item1 -> head
    list_add_head(&item2.list, &list);
    // 将 item3 添加到链表头部, head -> item3 -> item2 -> item1 -> head
    list_add_head(&item3.list, &list);

    struct list_head *iterator;
    // 遍历链表
    for (iterator = list.next; iterator != &list; iterator = iterator->next) {
        // 通过链表节点获取数据, 由于链表节点的前8个字节是 data，类型为 long, 所以需要减去8
        struct my_item *item = (struct my_item *) ((char *) iterator - 8);
        printf("Data: %ld\n", item->data);
    }
}
```

不出意外，运行上面的代码会打印出

    Data: 300
    Data: 200
    Data: 100

双向链表的示例如下图所示：

![intrusive-lists](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/19cbe36599e2438e8e1c558a665c4a69~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=2949\&h=741\&s=287774\&e=jpg\&b=fdfdfd)

简单而言，`intrusive lists` 就是利用链表节点 `list_head` 和数据存储位置上是紧挨着的，通过链表节点的地址，可以推断出链表数据节点各个字段的地址。比如这个例子中，list\_head 组成循环链表，通过 list\_head 指针地址减去 8 就可以得到 my\_item 结构体的起始地址，进而可以获取到 data 字段的值。

这样做的好处非常明显，不需要额外的结构来维护链表节点和数据之间的关系，更重要的是带来了编程上的灵活性，可以轻松地将任何结构体放入一个或多个链表中，只需在这些结构体中嵌入 struct list\_head 成员即可。

## epoll 三板斧

epoll 最重要的是下面这三个函数

*   int epfd = epoll\_create(0);
*   epoll\_ctl(epfd, EPOLL\_CTL\_ADD, fd, \&ev)
*   int nfds = epoll\_wait(epfd, events, 5, -1);

通过 `epoll_create` 系统调用创建 epfd， 然后通过 `epoll_ctl` 将感兴趣的文件描述符进行注册，再通过 `epoll_wait` 等待感兴趣的事件发生。

一个典型的用法如下：

```c
#include <unistd.h>

#ifdef linux
#include <sys/epoll.h>
#endif

#define MAX_EVENTS 10

int main() {
    int epfd;
    // 1、创建 epoll 实例，返回 epfd 句柄
    if ((epfd = epoll_create(0)) < 0) {
        exit(1);
    }
    int sock_fd = create_sock_fd();//
    // 2、初始化 epoll_event 结构体
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = EPOLLIN; // 设置感兴趣的事件（读事件）
    event.data.fd = sock_fd; // 设置感兴趣的 fd（这里为 sock_fd）
    
    // 3. 将 socket 添加到 epoll 实例的红黑树中
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, sock_fd, &event) < 0) {
        exit(1);
    }

    struct epoll_event events[MAX_EVENTS];
    int n;
    while (1) {
        // 4. 调用 epoll_wait
        // 第一个参数表示 epoll 实例的句柄
        // 第二个参数表示 epoll_event 的结构体数组，用入参接收返回值
        // 第三个参数表示 epoll_event 的结构体数组的大小
        // 最后一个参数表示超时时间，负数表示永不超时
        // 返回值表示有多少个就绪事件
        n = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (n < 0) {
            exit(1);
        }
        // 5. 遍历返回的就绪事件列表
        for (int i = 0; i < n; i++) {
            // 处理事件
            handle_event(events[i]);
        }
    }
    close(epfd);
}
```

简单起见，下面的内容都以 socket 为例来讲解 epoll 的源码。

## epoll\_create 源码分析

`epoll_create` 的参数 size 从 Linux 2.6.8 版本以后被忽略不再使用。`epoll_create` 的返回值是一个 epoll 实例的 fd。

```c
#include <sys/epoll.h>

int epoll_create(int size);
```

epoll\_create 简化过的内核代码如下。

```c
SYSCALL_DEFINE1(epoll_create1, int, flags)
{
	int error, fd;
	struct eventpoll *ep = NULL;
	struct file *file;
	// 给 struct eventpoll 分配内存并初始化
	ep_alloc(&ep); 

	// 获取一个可用的 fd 值，此时 fd 值还没对应到具体的 file
	fd = get_unused_fd_flags(O_RDWR | (flags & O_CLOEXEC));

	// 用来创建一个名为 "[eventpoll]" 的匿名文件
	file = anon_inode_getfile("[eventpoll]", &eventpoll_fops, ep,
				 O_RDWR | (flags & O_CLOEXEC));

	ep->file = file;
	
	// 将 fd 和匿名文件 file 绑定在一起。
	fd_install(fd, file);
	return fd;
}
```

epoll\_create 用户态返回的是一个 fd，实际上 epoll 在内核中的内部结构是 `struct eventpoll`，定义在内核源码 `fs/eventpoll.c`文件中

```c
struct eventpoll {
    // omit...
	wait_queue_head_t wq; // 等待队列头
	struct list_head rdllist; // 就绪事件双向链表
	struct rb_root_cached rbr; // 红黑树根节点
	struct epitem *ovflist; // 溢出列表（单向链表）
	struct file *file; // epoll 对应的匿名文件
}
```

`struct eventpoll` 是 epoll 最重要的三个结构体之一，它的核心字段的作用如下

*   wait\_queue\_head\_t wq：等待队列头，用来存储因为 epoll\_wait 进入等待的进程。当事件发生时，等待队列中的对应的进程会被唤醒。
*   list\_head rdllist：一个双向链表头，用于存储就绪事件。当一个文件描述符变为就绪状态（例如，数据可读），相应的事件会被添加到这个链表中。
*   rb\_root\_cached rbr：红黑树的根节点，用于高效地管理和查找 epoll 项（epoll 监视的文件描述符）
*   epitem \*ovflist：溢出列表，当内核正在拷贝 ready 的 fd 到 rdllist 时，此时如果有新的 ready 的 fd，则会临时加入这个单向链表

![epoll\_socket\_1](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/2e2133cb633141b1925d760037e0bf0b~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=3695\&h=1666\&s=656528\&e=jpg\&b=fdfdfd)

epoll 中涉及两种等待队列，一个是 epoll 本身的等待队列，一个是 socket 设备的等待队列，这两个等待队列一定要区分清楚，不然后面的内容很容易搞混。

eventpoll 结构体的的 `wait_queue_head_t wq` 表示的是 epoll 本身的等待队列，当我们调用 epoll\_wait 没有事件时，会将当前的线程加入到 eventpoll 的等待队列，同时让出 CPU。

## epoll\_ctl 源码分析

`epoll_ctl` 用来新增、修改、删除 epoll 实例中的感兴趣 fd 和事件。

```c
#include <sys/epoll.h>

int epoll_ctl(int epfd, int op, int fd,
             struct epoll_event *_Nullable event);
```

其中 op 表示要执行的操作，可以是下面这几种 `EPOLL_CTL_ADD、EPOLL_CTL_MOD、EPOLL_CTL_DEL`

以 `EPOLL_CTL_ADD` 为例，`epoll_ctl` 简化后的代码如下：

```c
SYSCALL_DEFINE4(epoll_ctl, int, epfd, int, op, int, fd,
	struct epoll_event __user *, event)
{
    struct fd f, tf;
    struct eventpoll *ep;
    struct epitem *epi;
    
    // 获取 epoll 实例对应的匿名文件
    f = fdget(epfd);
    // tf 表示 target file，也就是 epoll 要操作的目标文件 fd
    tf = fdget(fd);
    ep = f.file->private_data;
    // 从红黑树中查找该目标 fd
    epi = ep_find(ep, tf.file, fd);
    // 如果不存在则插入
    if (!epi) {
    		epds.events |= POLLERR | POLLHUP;
    		ep_insert(ep, &epds, tf.file, fd, full_check);
    }
}
```

epoll 底层使用**红黑树**来跟踪所有感兴趣的 fd，比如 100 万个 socket 句柄，这棵红黑树的顶点是结构体 `struct eventpoll` 的字段 rbr。当调用 `epoll_ctl(EPOLL_CTL_ADD)` 时，就会创建一个 epitem 实例，并插入到红黑树中。

![epoll\_rbtree](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/82b6a9b8660d4043b05495f3254881d0~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=1862\&h=1466\&s=270818\&e=jpg\&b=ffffff)

红黑树存储的节点类型是 `struct epitem`，它的定义如下

```c
struct epitem {
    // 红黑树节点
    struct rb_node rbn;
    	
    // 用于构造双向链表，这里是将 epitem 结构体链接到链表中（eventpoll 结构体中的双向链表 rdllist）
    struct list_head rdllink;
        
    // file 指针和 fd 的 wrap 类，用于红黑树比较和排序
    struct epoll_filefd ffd;
    

    // 等待队列
    struct list_head pwqlist;

    // 属于哪个 eventpoll 
    struct eventpoll *ep;
};
```

`rdllink` 的类型为 list\_head，前面介绍过是用于构造双向链表，这里是将 epitem 结构体链接到双向链表中（eventpoll 结构体中的双向链表 rdllist）

![epitem](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/7aa21813a04b40f782c9131e6132538d~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=2991\&h=1074\&s=515005\&e=jpg\&b=fdfdfd)

红黑树是一颗自平衡的二叉查找树，这样就需要节点之间能够比较大小进行排序。epitem 之间比较大小是通过比较 epitem 结构体中的 `epoll_filefd` 字段来实现的，调用的比较函数是 `ep_cmp_ffd`

```c
struct epoll_filefd {
	struct file *file;
	int fd;
}

static inline int ep_cmp_ffd(struct epoll_filefd *p1,
			     struct epoll_filefd *p2)
{
	return (p1->file > p2->file ? +1:
	        (p1->file < p2->file ? -1 : p1->fd - p2->fd));
}
```

`ep_cmp_ffd` 比较粗暴的先比较 file 指针内存地址，如果指针地址相等的情况下再来比较 fd。file 指针相同，fd 也相同，则可以认为这两个 epollitem 相等，`ep_cmp_ffd` 返回值为 0。

当红黑树中不存在对应的 fd 时，则会调用 `ep_insert` 进入插入流程。

```c
static int ep_insert(struct eventpoll *ep, struct epoll_event *event,
		     struct file *tfile, int fd, int full_check)
{
    struct epitem *epi;
    
    // 从 kernel slab 分配内存 epitem
    epi = kmem_cache_alloc(epi_cache, GFP_KERNEL);
    
    // 定义 ep_pqueue 对象
    struct ep_pqueue epq;
    epq.epi = epi;
    
    // 调用 ep_ptable_queue_proc 注册回调函数，设置回调函数 ep_poll_callback
    init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
    
    // 调用设备 poll 方法查看是否有 ready 事件
    revents = ep_item_poll(epi, &epq.pt, 1);

    // 将 epi 插入到红黑树中
    ep_rbtree_insert(ep, epi);
}
```

`ep_insert` 主要做三件事情：

*   新建一个 epitem 实例（从 kernel slab 分配内存 epitem）
*   为对应 fd 设置回调函数 ep\_poll\_callback，当有事情发生时，则会回调该函数
*   将 epitem 插入到红黑树中，便于快速查找

`init_poll_funcptr` 代码如下

```c
static inline void init_poll_funcptr(poll_table *pt, poll_queue_proc qproc)
{
	pt->_qproc = qproc;
	pt->_key   = ~0UL; /* all events enabled */
}
```

`init_poll_funcptr` 的作用是：

*   设置感兴趣的事件为 `~0UL`，也就是全 1 的值，表示关心所有的事件
*   将 `poll_table` 的函数设置为 `ep_ptable_queue_proc`

`ep_ptable_queue_proc` **只在** `ep_insert` 阶段使用，主要逻辑是生成新的 `eppoll_entry` 对象并添加到被 socket 设备等待队列中，ep\_ptable\_queue\_proc 的入参是 whead 是 socket 设备的等待队列头

```c
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead, poll_table *pt)
{
    // 从 poll_table 中恢复 epitem
    struct epitem *epi = ep_item_from_epqueue(pt);

    // 新建一个 eppoll_entry 结构体
    struct eppoll_entry *pwq;
    pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL);
    
    // 初始化回调方法 ep_poll_callback
    init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
       
    // whead ---> socket->wq.wait
    // 将 eppoll_entry 的 whead 指向 socket 的等待队列 whead
    pwq->whead = whead;
    pwq->base = epi;
    
    // 将 eppoll_entry 添加到 socket 设备的等待队列
    add_wait_queue(whead, &pwq->wait);
}
```

ep\_ptable\_queue\_proc 函数首先从 poll\_table 结构体中恢复出 epitem，这一步也是 C 指针的把戏。poll\_table 被包裹在 ep\_pqueue 结构体中，知道 poll\_table 的指针地址，只需要偏移 sizeof(poll\_table) 就可以获取到 epitem 指针。

```c
/* Wrapper struct used by poll queueing */
struct ep_pqueue {
    poll_table pt;
    struct epitem *epi;
};
```

接下来是分配一个新的 `eppoll_entry` 结构体

```c
struct eppoll_entry *pwq;
// 新建一个 eppoll_entry，这个结构体
pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL);
```

eppoll\_entry 这个结构体的作用是做为一个「胶水」，来关联 epitem 项和 epitem 事件发生时的回调函数（ep\_poll\_callback），它的的定义如下

```c
struct eppoll_entry {
	struct list_head llink;
	struct epitem *base; // 指向 epitem
	wait_queue_entry_t wait; // 一个等待队列项
	wait_queue_head_t *whead; // socket 等待队列头
};
```

这里的 `wait_queue_t wait` 是一个等待队列项，用来将 eppoll\_entry 注册到 socket 设备的等待队列中，当 socket 有事件发生（可读、可写等），这个等待队列项便可以唤醒等待这个队列的进程。

它的 `wait_queue_head_t *whead` 是一个指向等待队列头的指针，

总结来看，`ep_ptable_queue_proc` 内部逻辑是

*   调用 `ep_item_from_epqueue` 从 poll\_table 变量中恢复结构体 struct epitem
*   调用 `init_waitqueue_func_entry` 初始化 `eppoll_entry`，设置文件发生事件时的回调函数为 `ep_poll_callback`
*   将 `eppoll_entry` 挂在当前 socket 文件的等待队列中，当对应的 fd 有事件发生时，就会调用 `ep_poll_callback`

![inline](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/60d0d91187fd465184e104b479c3801b~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=843\&h=461\&s=98996\&e=jpg\&b=f9f9f9)

`ep_poll_callback` 是一个 epoll 框架中非常重要的函数，它做为 epoll 的回调函数，当 socket 上有事件发生被调用。

```c
static ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
	// 从 wait_queue_entry_t 中恢复 epitem
	struct epitem *epi = ep_item_from_wait(wait);
	struct eventpoll *ep = epi->ep;

	// 判断是否是用户感兴趣的事件
	if (key && !((unsigned long) key & epi->event.events))
		goto out_unlock;
    

	// 检查当前 epitem 是否在 ready list 中
	if (!ep_is_linked(&epi->rdllink)) {
		list_add_tail(&epi->rdllink, &ep->rdllist);
	}

	// 唤醒等待 ep->wq，也就是因为 epoll_wait 而陷入休眠的进程
	if (waitqueue_active(&ep->wq)) {
		wake_up_locked(&ep->wq);
	}

out_unlock:
   // ...
	return ewake;
}
```

## epoll\_wait 源码分析

相比如 epoll\_ctl，epoll\_wait 的代码要简单很多，只是简单检查一下 eventpoll 中的 rdllist 是否有就绪事件，如果有则返回就绪事件列表，如果没有就绪事件，则把当前进程添加到 eventpoll 的等待队列，然后让出 CPU。

```c
SYSCALL_DEFINE4(epoll_wait, int, epfd, struct epoll_event *, events,
		int, maxevents, int, timeout)
{
	int error;
	struct fd f;
	struct eventpoll *ep;
	
	// 从 epfd 获取对应底层结构 struct file*
	f = fdget(epfd);
    // 从 struct file* 结构体中获取 struct eventpoll
	ep = f.file->private_data;

	error = ep_poll(ep, events, maxevents, timeout);

	fdput(f);
	return error;
}

static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,
		   int maxevents, long timeout)
{
	int res = 0, eavail, timed_out = 0;
	wait_queue_entry_t wait;
	
fetch_events:
	if (!ep_events_available(ep)) { 
	    // 将当前进程/线程 task_struct 加入到 ep->wq
		init_waitqueue_entry(&wait, current);
		__add_wait_queue_exclusive(&ep->wq, &wait);

		for (;;) {
			set_current_state(TASK_INTERRUPTIBLE); // // 设置可中断运行状态
			if (ep_events_available(ep) || timed_out)
				break;
			// 让出 CPU
			if (!schedule_hrtimeout_range(to, slack, HRTIMER_MODE_ABS)) 				
			timed_out = 1;
		}
		
		// 进程被唤醒，将自己移除出 ep->wq，同时将进程状态设置为 TASK_RUNNING
		__remove_wait_queue(&ep->wq, &wait);
		__set_current_state(TASK_RUNNING);
	}

	eavail = ep_events_available(ep);

	if (!res && eavail &&
	    !(res = ep_send_events(ep, events, maxevents)) && !timed_out)
		goto fetch_events;

	return res;
}

```

## ep\_poll\_callback 是被谁调用的

可以用 qemu 调试 linux 内核代码来做实验，在 ep\_poll\_callback 上打一个断点，可以看到当有事件发生时（比如建立等）会触发网卡软中断，然后调用 `sock_def_readable`，然后最后调用到 ep\_poll\_callback，在 ep\_poll\_callback 函数中唤醒等待在 `ep->wq` 进程，让 epoll\_wait 而陷入休眠的进程唤醒，然后从内核拷贝就绪事件。

![inline](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/4090ee5cfe9a49fcb526b4936be2f1a5~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=922\&h=1360\&s=256533\&e=jpg\&b=3b3f42)

这个过程如下图所示：

![epoll\_socket\_wakeup](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/4c304698c13f4f11b09ffb070732c4f6~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=5133\&h=1874\&s=1007409\&e=jpg\&b=fefefe)

## 小结

epoll 内部错综复杂的内部关系，我用一个大图呈现了出现，希望可以帮助你理解。

![epoll\_all](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/6b76bc1a993040ee8dbce12496c3e064~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=10608\&h=5837\&s=4133643\&e=jpg\&b=fefefe)
