通过前面章节的介绍我们知道，Redis 主从复制可以实现读写分离，Redis Sentinel 模式可以实现自动故障转移，解决了 Redis 主从复制模式的高可用问题，看起来是个非常美好的方案。但 Sentinel 还是存在一个问题，那就是`横向扩展`问题。

在面对海量数据的时候，我们无法使用一个 Redis Master 存储全部数据，此时就需要**一套分布式存储方案**将数据进行切分，每个 Redis 主从复制组只存储一部分数据，这样就可以通过增加机器的方式增加 Redis 服务的整体存储能力。

## 常见 Redis 分布式方案

Redis 常见的分布式存储方案有`客户端分片`、`代理层分片`以及 `Redis Cluster` 三种，下面对这三种方案进行简单介绍。

-   **客户端分片**。客户端分片是在客户端预先定义好分片的路由规则（一般使用`一致性 Hash 算法`），将不同 Key 的读写路由到不同的 Redis 主从复制组中，其核心结构如下图所示：


![image.png](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/840efb4ddfa94208bd62a9a3005aa4ac~tplv-k3u1fbpfcp-watermark.image?)

客户端分片方案的缺点还是比较明显的，首先就是需要我们预估好 Redis 服务的容量上限，虽然一致性 Hash 算法已经尽量可能地减少了增减 Redis 主从复制组时的数据迁移量，但数据迁移还是会花费不小的运维成本。在使用客户端分片方案时，我们需要好好设计 Key、Hash 算法以及节点个数，保证数据的分布均匀，防止出现数据倾斜，全部打到一组 Redis 主从复制组。另外，将分片规则放到 Redis 客户端中，需要所有客户端的分片规则保持一致，如果要更新分片规则，需要使用客户端的所有业务方进行升级，这一般是需要跨部门沟通和推进的，也是一件比较耗时的事情。

客户端分片方案的优点是很多语言的 Redis 客户端支持了客户端分片逻辑，例如，Jedis 就支持客户端分片的功能，感兴趣的小伙伴可以参考 Jedis 中的 ShardedJedis 类，这里不展开分析。

-   **代理层分片**。代理层分片的核心原理是在 Redis 客户端和 Redis 服务之间添加一层 `Proxy 代理层`，将分片逻辑放到代理层中，代理层实现了 Redis 的相关协议。在客户端看来，代理层与真正的 Redis 服务无异，而从 Redis 服务的角度看，代理层则是一个客户端。在 Redis 客户端发送命令的时候，请求会先到达代理层，代理层会根据 Key 和相关配置将请求路由到一个或多个目标 Redis 集群；在返回响应的时候，代理层会将多个 Redis 集群的查询结果进行汇总，返回给客户端。

    代理层分片的核心架构如下图所示：


![image.png](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/d51f5a077cd54ab18b561840728cda33~tplv-k3u1fbpfcp-watermark.image?)

常见的代理层有 Twemproxy、Codis 等等，它们各自有各自的优点和缺点，例如，Twemproxy 的平滑迁移做得不太友好，对 Redis 服务的扩容成本很高；Codis 本身对 Redis 的源码进行了更新，但是 Codis 已经没有对 Redis 新版本进行支持了，基本处于停止维护的状态。

-   **Redis Cluster 方案**。Redis Cluster 方案是 Redis 官方在 3.x 版本之后引入的分布式存储，Redis Cluster 区别于前文介绍的两种方案，其分片功能全部是在服务端实现的。Redis Cluster 采用`分区`的方式对数据存储，`每个分区都是独立、平行的 Redis 主从复制组`，架构如下图所示。


![image.png](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/86f1d569d5994eacbd0f28608fd35d88~tplv-k3u1fbpfcp-watermark.image?)

Redis Cluster 采用**去中心化的多主多从方案**，Redis Cluster 内部的 Redis 节点彼此之间互相连接，通过 PING 命令探活，使用 Gossip 协议发现节点变更。

Redis Cluster 内部按照 slot 对数据进行切分的，每个 Master 节点只负责维护一部分 slot 以及落到这些 slot 上的 KV 数据，但是 Redis Cluster 中每个节点都有全量的 slot 信息，这样的话，客户端无论连接到哪个节点，都可以知道自己访问的 Key 落到哪个 slot 里面以及这个 slot 位于哪个节点中。

**Redis Cluster 作为 Redis 官方提供的集群方案，目前基本上已经取代了客户端分片方案和代理层分片方案，成为实际生产中应用最为广泛的 Redis 分布式存储方案了**。在本模块的剩余内容中，我们将展开介绍 Redis Cluster 方案的核心原理和实现。

## 核心结构体解析

了解了 Redis 分布式存储的常见方案以及 Redis Cluster 的大致结构之后，我们下面就来看看 Redis Cluster 的核心实现。

在 Redis Cluster 中，有四个非常核心的数据结构：clusterState 、 clusterNode、clusterSlotToKeyMapping 和 clusterLink。下面我们先来看看这四个结构体的核心字段。

### clusterNode

首先来看 clusterNode 结构体。在每个 Redis Cluster 节点中都维护了多个 clusterNode 实例，**每个 clusterNode 表示一个 Redis Cluster 节点，其中一个 clusterNode 实例是用来记录当前节点自身的一些信息，其他的 clusterNode 实例用来代表 Redis Cluster 中其他的 Redis 节点**。

下面我们详细说明一下 clusterNode 中核心字段的功能。

-   name 字段：长度为 40 的字符串，记录了该 clusterNode 的名称。

-   ctime 字段：记录了该 clusterNode 实例创建的时间戳。
-   ip、port、cport 字段：记录了该 clusterNode 节点的 ip 、端口号（监听客户端建连请求的端口）以及集群端口（监听其他节点建连请求的端口）。
-   hostname 字段：记录了该 clusterNode 节点的 hostname。它是在 Redis 7.0 中新加的一个字段，相关 PR 是 https://github.com/redis/redis/pull/9530 ， 在 7.0 版本之前，Redis Cluster 只能使用 IP 连接一个节点。
-   flags 字段：该 clusterNode 的状态集合，其中每一个比特位都标识了当前 clusterNode 的一个状态，这也是 Redis 里面常见的状态字段设计了。
-   link 字段：该字段是一个 clusterLink 指针，指向的 clusterLink 实例维护了当前 clusterNode 节点与该 clusterNode 实例表示的 Cluster 节点之间的连接信息。
-   configEpoch 字段：记录了该 clusterNode 节点的 epoch 值。epoch 的概念在前面已经详细介绍过了，这里不再重复。
-   slots、numslots 字段：slots 是一个 char 类型数组，记录该 clusterNode 维护的 slot（槽位）集合，按照 bitmap 的方式存储，默认 Redis Cluster 会将全量数据分为 16384 个 slot 存储，所以，slots 这个 char 数组的长度为 16384/8 = 2048；numslots 字段记录了当前 clusterNode 节点维护的 slot 个数。
-   slaves、numslaves 字段：slaves 是一个 clusterNode 二级指针，指向一个 clusterNode 指针数组，其中每个 clusterNode 指针都指向了当前 clusterNode 的一个 Slave 节点；numslaves 字段记录了当前 clusterNode 节点的 Slave 个数，也就是 slaves 数组的长度。
-   slaveof 字段：slaveof 是一个 clusterNode 指针，如果当前 clusterNode 表示是一个 Slave 节点，则 slaveof 字段指向了表示其 Master 的 clusterNode 实例。
-   ping_sent、pong_received 字段：记录了当前 clusterNode 最后一次发送 PING 命令和最后一次收到 PONG 响应的时间戳。
-   repl_offset、repl_offset_time 字段：repl_offset 记录了最后一次与该 clusterNode 节点同步 Replication Offset 时得到的值；repl_offset_time 则是最后一次同步 Replication Offset 的时间戳。

### clusterState

再来看 clusterState 结构体，Redis Cluster 中每个节点都维护了一个 clusterState 实例，它**用来记录当前 Cluster 节点视角下的 Redis Cluster 状态**。在 redisServer 这个核心结构体中，维护了一个 cluster 字段，该字段就是 clusterState 指针。

下面我们展开分析一下 clusterState 结构体的核心字段。

-   myself 字段：一个 clusterNode 指针，指向了代表当前 Redis 节点的 clusterNode 实例。

-   currentEpoch 字段：记录了当前 Redis Cluster 节点看到的最新 Cluster 纪元。下面简单说明一下该字段与 clusterNode.configEpohc 字段的区别：

    **currentEpoch** 是整个 Redis Cluster 使用的统一纪元值，也被认为是统一的逻辑时钟。初始化时各个节点的 currentEpoch 值都为 0，后续在节点之间交互时，如果发现其他 Cluster 节点的 currentEpoch 值比自己的 currentEpoch 值大，则当前节点会更新自身的 currentEpoch 值与对端节点一致，直至整个 Redis Cluster 的 currentEpoch 全部一致。

    在后面我们会看到，currentEpoch 会用于 failover 操作中，举个例子，Slave 节点发现其 Master 节点下线时，就会发起 failover 操作，首先就是增加自身的 currentEpoch 值，使其成为集群中最大的 currentEpoch 值，然后 Slave 向所有节点发起投票请求，请求其他 Master 投票给自己，使自己能成为新一任 Master。其他节点收到包后，发现投票请求里面的 currentEpoch 比自己的 currentEpoch 大，证明自己的信息需要更新了，此时就会更新自己的 currentEpoch 值，并投票给该 Slave 节点。

    **configEpoch** 是一组主从复制关系内的纪元值，而非整个 Redis Cluster 的纪元值。Redis Cluster 中各个 Master 节点的 configEpoch 值不同，但在一组主从复制关系中，Master 节点与其 Slave 节点拥有相同的 configEpoch 值。

    一组主从复制关系中的 Master 和 Slave 节点向其他节点发送消息的时候，都会附带 Master 的 configEpoch 值以及其管理的 slot 信息，其他节点收到消息之后记录这些信息。configEpoch 主要用于解决不同节点的配置冲突问题。举个例子，节点 A 是节点 B 的 Master 节点，节点 A 负责管理 slot 100 ~ 200，节点 C 收到节点 A 发来的心跳消息时就会记录该信息，然后 A 发生了故障，B 成为新一任 Master，此时就会增加 configEpoch。之后，B 也通过消息告诉节点 C 负责自己 slot 100 ~ 200，在节点 C 的视角中，就有 A、B 两个节点同时声称自己负责 slot 100 ~ 200，这就出现了冲突。此时，节点 C 会比较 B 和 A 的 configEpoch 值，以拥有较大 configEpoch 的消息为准，最终，C 会认为节点 B 负责 slot 100 ~ 200。

-   state 字段：记录当前 Redis Cluster 的状态，只有两个可选值，一个是 CLUSTER_OK 表示集群在线，另一个是 CLUSTER_FAIL 表示集群下线。
-   size 字段：记录了当前 Redis Cluster 中有效的 Master 节点个数。Master 只要负责管理至少一个 slot 时，才会有读写请求发送到该 Master 节点，它才是一个有效 Master 节点。
-   nodes、nodes_black_list 字段：nodes 字段是一个 dict 指针，记录了整个 Redis Cluster 中全部节点对应的 clusterNode 实例，其中的 Key 是节点名称（即 clusterNode->name），Value 是代表每个节点的 clusterNode 实例。nodes_black_list 是一个黑名单，用来排除一些指定的节点。
-   slots 字段：该字段是一个 clusterNode 数组，用于记录各个 slot 归属于哪些 Cluster 节点，例如，slots[i] = clusterNodeA 就表示 slot i 由节点 A 负责管理。
-   migrating_slots_to、importing_slots_from 字段：这两个字段都是 clusterNode 指针数组，分别记录了对应 slot 编号的迁移状态。例如，migrating_slots_to[i] = clusterNodeA 表示编号为 i 的 slot 要从当前节点迁移至节点 A，importing_slots_from[i] = clusterNodeA 表示编号为 i 的 slot 要从 A 节点迁移到当前节点。

clusterState 中还有一些与 failover 操作直接相关的字段，这里先按下不表，后面介绍 Redis Cluster Failover 操作的时候，展开详细分析。

### clusterSlotToKeyMapping

在 7.0 版本中，Redis 会在 redisDb 中维护一个 clusterSlotToKeyMapping 指针（slots_to_keys 字段），在 clusterSlotToKeyMapping 中维护了一个长度为 16384 的 slotToKeys 数组，其中的下标是 slot 的编号，对应的 slotToKeys 将这个 slot 中全部的键值对串联成了一个双端链表。注意，并不是单独拷贝一份键值对数据，而是复用了存到 redisDb 中的 dictEntry 实例。

```c
typedef struct slotToKeys {

    uint64_t count;   // 这个slot中键值对的数量

    dictEntry *head;  // 指向dictEntry双端链表头节点

} slotToKeys;
```

在前面介绍 dictEntry 结构体的时候提到，dictEntry 里面除了键值对数据之外，还有一个 metadata 指针数组，在 Cluster 模式下，metadata 中存储的就是 clusterDictEntryMetadata 指针，如下所示，clusterDictEntryMetadata 里面就维护了指向前后两个 dictEntry 的指针：

```c
typedef struct clusterDictEntryMetadata {

    dictEntry *prev;  // 同一个slot中的前一个dictEntry节点

    dictEntry *next;  // 同一个slot中的下一个dictEntry节点

} clusterDictEntryMetadata;
```

创建 slotToKeys->head 这个双端链表的时机，是键值对写入到 redisDb 的时候，前面在介绍 dbAdd() 函数的时候，我们只介绍了键值对写入 dict 结构的逻辑，其中就有一个针对 Cluster 的分支，如下所示，slotToKeyAddEntry() 函数会采用头插法，将 dictEntry 插入到 slotToKeys->head 链表中。

```c
void dbAdd(redisDb *db, robj *key, robj *val) {

    ... // 省略其他逻辑

    // 键值对写入到dict中

    dictEntry *de = dictAddRaw(db->dict, copy, NULL);

    dictSetVal(db->dict, de, val);

    // slotToKeyAddEntry()函数会采用头插法，将dictEntry插入到slotToKeys->head链表

    if (server.cluster_enabled) slotToKeyAddEntry(de, db);

    ...

}
```

### clusterLink

clusterLink 结构体**抽象了 Redis Cluster 中两个节点之间的网络连接**，其核心字段如下。

-   node 字段：它是一个 clusterNode 指针，指向的 clusterNode 实例表示了对端 Redis Cluster 节点。

-   conn 字段：它是一个 connection 指针，指向的 connection 实例抽象了两个节点的网络连接。connection 结构体的核心实现在前文已经详细分析过了，这里不再重复。
-   sndbuf 字段：sds 类型，当前 clusterLink 发送数据的缓冲区。
-   rcvbuf 字段：rcvbuf 是一个 char 类型的数组，它是当前 clusterLink 接收数据的缓冲区，rcvbuf_len 和 rcvbuf_alloc 字段则记录了该缓冲区的使用情况和总长度。
-   ctime 字段：记录了当前 clusterLink 实例创建的时间戳。

下面我们通过一张图简单总结一下 `clusterState、clusterNode 、clusterSlotToKeyMapping 以及 clusterLink 这四个核心结构体之间的关系`：


![image.png](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/02c0d9a5b162491495a74e819b07e88b~tplv-k3u1fbpfcp-watermark.image?)

## 启动流程分析

分析完 Redis Cluster 中四大核心结构体的内容之后，接下来要来分析 Redis Cluster 启动流程的核心步骤，这些核心步骤其实就是初始化上述核心结构体的过程。

通过前面对 Redis 的介绍我们知道，在 Redis 入口函数 main() 中，会调动 initServer() 函数完成 Redis 服务启动的初始化工作，例如，初始化 redisServer 实例、启动定时任务、启动网络监听等等。在 Redis Cluster 模式下，initServer() 函数中还会额外调用 clusterInit() 函数，这个函数就是 Redis Cluster 相关功能初始化的入口，其核心逻辑如下：

```c
void clusterInit(void) {

    int saveconf = 0;

    server.cluster = zmalloc(sizeof(clusterState)); // 1.初始化 clusterState 实例

    ... // 省略初始化clusterState



    if (clusterLoadConfig(server.cluster_configfile) == C_ERR) { // 2.加载 Cluster 配置文件

        ... // 省略加载失败的处理

    }

    if (saveconf) clusterSaveConfigOrDie(1);

    server.cfd.count = 0;

    int port = server.tls_cluster ? server.tls_port : server.port;

    ... // 省略检查逻辑

    int cport = server.cluster_port ? server.cluster_port : port + CLUSTER_PORT_INCR;

    if (listenToPort(cport, &server.cfd) == C_ERR ) { // 3.监听 cluster port 端口，准备与其他 Cluster 节点连接

        serverLog(LL_WARNING, "Failed listening on port %u (cluster), aborting.", cport);

        exit(1);

    }

    // 将 clusterAcceptHandler() 函数注册为建连的回调函数

    if (createSocketAcceptHandler(&server.cfd, clusterAcceptHandler) != C_OK) {

        serverPanic("Unrecoverable error creating Redis Cluster socket accept handler.");

    }



    ... // 4.初始化当前 Cluster 节点自身中 clusterState 的各个字段，初始化表示当前节点的clusterNode 实例的各个字段，代码非常多，省略

}
```

1.  初始化 clusterState 实例，也就是 redisServer.cluster 字段。

2.  加载 Cluster 配置文件，为了防止描述上的混淆，后面将该配置文件称为 nodes.conf 配置文件。在 redis.conf 配置文件中，我们可以通过 cluster-config-file 配置项指定 nodes.conf 配置文件的路径。nodes.conf 文件正常情况下是 Redis Cluster 节点在运行过程中自动生成的，不建议我们手动进行修改。nodes.conf 配置文件中记录了当前节点中各个 clusterNode 实例的关键信息，这里加载 nodes.conf 配置文件就是在当前节点重启的时候恢复之前内存中的 clusterNode 实例。nodes.conf 配合文件的结构以及读写逻辑我们暂时按下不表，在后面详细展开。
3.  监听 cluster port 端口，准备与其他 Cluster 节点连接。此处会调用 listenToPort() 函数监听其他节点发来建连请求，这里的 cluster port 端口默认是 redisServer.port + 10000。通过前面的介绍我们知道，redisServer.port 是 Redis 用来监听客户端建连的端口，默认值为 6379，那 cluster port 端口的默认值就是 16379。当然，我们也可以在 redis.conf 配置文件中，使用 cluster-port 配置项指定这个端口的具体值。

    同时，将 clusterAcceptHandler() 函数注册为建连的回调函数。在当前节点从 cluster port 端口接收到其他 Redis Cluster 节点发来的建连请求时，就会调用回调函数 clusterAcceptHandler()，其中会创建对应的 connection 实例并封装成相应的 clusterLink 实例（其中的 node 字段为 NULL，此时还不知道该连接来自哪个节点），然后将 clusterReadHandler() 函数注册为该新建连接的可读事件回调。

4.  最后，初始化当前 Cluster 节点自身中 clusterState 的各个字段，初始化表示当前节点的clusterNode 实例的各个字段。

## 加载 nodes.conf 文件

上述四个核心步骤中，我们来详细说一下 **nodes.conf 配置文件**的相关内容。

nodes.conf 配置文件中的每一行都表示一个 clusterNode 实例，每行按照空格分隔，至少存储了 8 部分信息，各部分含义如下图所示：


![image.png](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/0dbcdb65eff04bc996c461f992a9835c~tplv-k3u1fbpfcp-watermark.image?)

-   **第一部分**（name）记录了 clusterNode 实例的名称。


-   **第二部分**记录了 clusterNode 实例的 ip、port、cport。

-   **第三个部分**记录了 clusterNode 实例中 flags 信息，flags 字段中的每一位都会被解析为一个字符串，并通过逗号分割方式记录到这里。在 redisNodeFlagsTable 数组中可以看到全部的 flags 枚举值，这些枚举值的具体含义如下。

    -   myself：表示该 clusterNode 实例表示当前 Redis Cluster 节点自身。
    -   master：表示该 clusterNode 实例表示一个 Master 节点。
    -   slave：表示该 clusterNode 实例表示一个 Slave 节点。
    -   fail?：该 clusterNode 实例代表的 Redis Cluster 节点准备发起 Failover 操作。
    -   fail：该 clusterNode 实例代表的 Redis Cluster 节点已经处于 Failover 操作之中。
    -   handshake：表示该 clusterNode 实例表示的 Redis Cluster 节点与当前节点正处于握手阶段。
    -   noaddr：表示当前节点不知道该 clusterNode 实例所代表节点的具体地址。
    -   nofailover：该 clusterNode 实例代表的 Slave 节点不会尝试 Failover 操作。

    小伙伴们现在可能并不是特别清楚每个 flags 取值的更新时机和实际作用，后面在分析 Redis Cluster 的核心运行流程时，还会再次说明。

-   **第四部分**记录了该节点的主从关系。如果当前这行记录的是一个 Master 节点，则该部分为中划线；如果当前这行记录的是一个 Slave 节点，则该部分记录的是其 Master 的 name 值。
-   **第五、六部分**记录了对应 clusterNode 实例中的 ping_sent、pong_received 字段值，也就是当前节点最后一次向该节点发送 PING 命令以及最后一次收到 PONG 命令的时间戳。
-   **第七部分**记录了 clusterNode 实例中的 configEpoch 字段。
-   **第八部分**记录了该节点与当前节点之间的连接状态，主要是根据 clusterNode 的 link 字段判断的。
-   **第九部分**记录了该节点负责的 slot。上图第二行记录中，编号在[0, 5959]、[10922, 11422] 这两个范围中的 slot 由该节点负责维护。
-   **第十部分**记录了该节点相关的 slot 迁移情况，这部分信息只会在当前节点对应记录中存在（即 flags 中包含 myself 标识的记录 ）。上图第二行记录中，编号为 5960 的 slot 从该节点迁移到 5fc4589638723b1707fd65345e763befb36454d 这个节点，编号为 10921 的 slot 从5fc4589638723b1707fd65345e763befb36454d 这个节点迁移到该记录表示的节点。

nodes.conf 配置文件的最后一行以 “vars” 开头，后面紧跟 currentEpoch 和 lastVoteEpoch 两部分内容，分别对应 clusterState 中的同名字段，表示当前节点的 epoch 值以及当前节点最后一次参与投票的 epoch 值。

生成 nodes.conf 文件内容的核心逻辑位于 clusterSaveConfig() 函数中，其中会通过 clusterGenNodesDescription() 函数按照上述格式为每个 clusterNode 实例生成一行记录。解析 nodes.conf 配置文件的核心逻辑位于 clusterLoadConfig() 函数，其中会将解析得到的 clusterNode 实例记录到 redisServer.cluster->nodes 字段中，感兴趣的小伙伴们可以参考源码分析 nodes.conf 的读写逻辑，实现并不复杂，这里就不展开分析了。

## 总结

在本节中，我们重点介绍了 Redis Cluster 的核心结构体设计以及 Redis 服务在集群模式下的启动流程。

-   首先，我们一起分析了 Redis 中常见的三种集群方案，分别是客户端分片、代理层分片以及 Redis Cluster。
-   然后，带领小伙伴们一起分析了 Redis Cluster 中核心结构体的设计。
-   最后，深入解析了 Redis Cluster 节点启动的核心流程。