在上一节中，我们已经详细介绍了 Redis Pub/Sub 以及 Shard Pub/Sub 的功能，也说明了 Pub/Sub 的优缺点。Redis 在 `5.0 版本`中**借鉴了 Kafka 的设计思路，引入了 Stream 数据类型来支持消息队列的功能**。下面是 Stream 的几个核心特性。

-   为了解决 Pub/Sub 不存储消息的问题，Stream 会在内存中使用 rax 树和 listpack 结构来存储消息。
-   Stream 借鉴 Kafka 引入了 Consumer Group 的概念，不同的消费者可以划分到不同的 Consumer Group 中，消费同一个 Stream。后面分析底层实现时，还会展开介绍 Consumer Group 的概念。
-   Stream 借鉴了 Kafka 中 offset 的思想，引入了 position 的概念。Consumer 可以通过移动 position 重新消费历史消息，为故障恢复带来更多便利。
-   引入了 ACK 确认机制，保证消息 “at least once” 消费（也就是一条消息至少被消费一次）。
-   Stream 可以设置其中消息保存的上限阈值，在超过该阈值的时候，Redis 会将历史消息抛弃掉，避免内存被打爆。

## Stream 结构体分析

在使用 Stream 的时候，最常用的命令就是 `XADD 命令`，它可以向 Stream 中追加消息，例如：

```
127.0.0.1:6379> XADD mystream * name kouzhaoxuejie age 25

"1659530063532-0"
```

这里简单说明一下这条命令的含义：mystream 是 Stream 的名称，星号表示自动生成消息 ID，后面的部分就是一条消息（Redis 代码中的注释称其为 entry），一个消息可以包含多个 field value 部分。写入成功之后，Redis 会返回这条消息的 ID。

Stream 中每条消息都有唯一 ID，这个 ID 在 Redis 内部是使用 streamID 结构体进行抽象。如下所示，streamID 中维护了一个毫秒级时间戳（ms 字段）以及一个毫秒内的自增序号（seq 字段），之所以有这个自增序号的存在，是为了区分在同一毫秒内写入的两条 entry。

```c
typedef struct streamID {

    uint64_t ms;  // 毫秒级时间戳

    uint64_t seq; // 毫秒内的自增序列号

} streamID;
```

接下来看 stream 结构体，它是对 Stream 数据结构的抽象。Redis 始终是一个 KV 存储，一个 stream 实例会作为 Value 值，封装成 redisObject 存储到 redisDb 中，该 redisObject 实例的 type 值为 OBJ_STREAM，其对应的 Key 值就是 Stream 的名称。

Stream 底层依赖了前文介绍的 Rax、listpack 等数据结构来存储 entry，同时还维护了消费当前 stream 的 Consumer Group 信息。stream 结构体的结构如下图所示：


<p align=center><img src="https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/7881cfccffaa4bcea3b9ce64f9cff786~tplv-k3u1fbpfcp-watermark.image?" alt="image.png"  /></p>

下面是上图中 stream 结构体中关键字段的功能说明。

-   rax 字段是一个 rax 指针，该 rax 树用来存储该 Stream 中的全部消息。其中，entry ID 为 Key，entry 的内容为 Value。
-   length：当前 Stream 中的消息条数。
-   last_id：记录了当前 Stream 中最后一条消息的 ID。
-   first_id：记录了当前 Stream 中第一条消息的 ID。
-   max_deleted_entry_id：记录了当前 Stream 中被删除的最大的消息 ID。
-   entries_added：记录了总共有多少消息添加到当前 Stream 中，该值是已经被删除的消息条数以及未删除的消息条数的总和。
-   cgroups：rax 指针，该 rax 树用于记录当前消费该 Stream 的所有 Consumer Group。其中，Consumer Group 的名称是它的唯一标识，也是它在这个 rax 树的 Key，Consumer Group 实例本身是对应的 Value。

我们将在后面介绍 XADD 命令执行逻辑及具体 Stream 是如何使用 Rax 树和 listpack 来存储数据的时候展开分析。这里我们先来关注 stream->cgroups 这棵 rax 树中存储的 Consumer Group。Redis 定义了一个 streamCG 结构体来抽象 Consumer Group，其核心字段如下。

-   last_id：streamID 实例，当前 Consumer Group 消费的位置，即已经确认的最后一条消息的 ID。该 Consumer Group 中的全部 Consumer 会共用一个 last_id 值，这与 Kafka 中 Consumer Group 中的 offset 值功能类似。

-   pel：rax 指针，该字段的全称是 “pending entries list”，其中记录了已经发送给当前 Consumer Group 中 Consumer，但还没有收到确认消息的消息 ID。其中 Key 是消息 ID，Value 为对应的 streamNACK 实例。在 streamNACK 结构体中，记录了该消息最后一次推送给 Consumer 的时间戳（delivery_time 字段）、被推送的次数（delivery_count 字段）以及推送给了哪个 Consumer 客户端（consumer 字段）。
-   consumers：rax 指针，记录了当前 Consumer Group 中有哪些 Consumer 客户端，其中 Key 为 Consumer 的名称，Value 为对应的 streamConsumer 实例。在 streamConsumer 结构体中主要记录了当前 Consumer 的相关信息，例如，最近一次被激活的时间戳（seen_time 字段）、名称（name 字段）以及对应的 pending entries list（pel 字段）。注意，对于一个消息 ID 来说，在 streamCG->pel 和 streamConsumer->pel 中的 streamNACK 实例是同一个。


## 消息存储格式

在开始分析 Stream 读写消息的核心实现之前，需要先了解一下 Stream 存储消息的格式。前面提到，Stream 在使用 Rax 树和 listpack 两种结构来存储消息，其中的 Key 是消息 ID，Value 是一个 listpack，这个 listpack 里面存储了多个消息，其中的消息 ID 都会大于等于 Key 中的消息 ID。

下面我们展开介绍一下 listpack 是如何存储多条消息的。

在新建 listpack 的时候，插入到新 listpack 的第一个消息并不是真实的消息数据，而是一个叫做 “master entry” 的消息（entry），然后才会插入真正的消息数据。master entry 中记录了一些元数据，格式如下图所示，其中每一部分都是一个 listpack 元素。

![](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/262f08c9727149a8b779fa408593420b~tplv-k3u1fbpfcp-zoom-1.image)

其中，count 记录了当前 listpack 中有效的消息个数，deleted 记录了当前 listpack 中无效的、已被标记删除的消息个数，count + deleted 即为 listpack 中消息的总和。num-fields 记录了 master entry 中 field 个数（也就是第一条消息有多少个 field/value 对）。剩下的 field_1 一直到 field_N 就是该 listpack 实例第一次插入消息时携带的 field 集合。最后一个 “0” 表示 master entry 这条消息的结束。

**在 master entry 消息之后，Stream 才开始真正存储有效的消息**。下面的介绍同时适用于新 listpack 插入第一条消息以及向老 listpack 追加消息的场景。消息的具体格式如下图所示：

<p align=center><img src="https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/d6546a1b28a74235bde2b1be0206179f~tplv-k3u1fbpfcp-zoom-1.image" alt=""  /></p>

有效消息中的第一部分是 flags，它是一个 int 类型的值，其中可以设置下面`三个标识位`。

-   SAMEFIELDS：它表示当前消息中的 field 与 master entry 完全一致，可以进行优化存储，如上图中（a）结构所示，此时无需再存储 field 信息了，直接存储 value 值即可。listpack 中的第一条有效消息，必然是符合该优化条件的。
-   NONE：它与上面的 SAMEFIELDS 标记位互斥，它表示当前消息无法进行优化，需要同时存储 field 和 value 的信息，消息格式如上图（b）所示。
-   DELETED：它表示当前消息已经被删除了。

之所以会有 master entry 消息，是因为实际情况中，写入同一个 Stream 的消息格式，几乎是完全一模一样的；**通过 master entry 消息的优化，可以不用在每条消息中存储 field，进而节省内存空间**。

接下来看 entry-id 部分，其中并不会直接存储完整的 streamID 值，而是存储当前插入消息与 master entry id（即该 raxNode 节点的 key 值）的差值，其中包括时间戳和序列号两部分的差值（ ms-diff、seq-diff），之所以用差值的方式进行存储，是为了减小存储的值，这也是存储有序数据时，常见的一种优化策略。

然后是 num-fields 部分，记录了该条消息中的 field 个数。因为在 flags 为 NONE 场景中，消息与master entry 的 field 不一致，所以才需要 num_field 部分。在 flags 为 SAMEFIELDS 场景中，不需要存储 num-field 部分。

之后，就是 field 以及 value 部分了，其中存储了消息的有效负载数据，无需过多介绍了。

最后是 lp_count 部分，它用于记录当前这条消息涉及到多少个 listpack 元素。例如，在 flags 为 NONE 的存储场景中，lp_count 为 `num_fields*2(field和value的总个数) + 3 + 1`。其中，3 是指 flags、ms-diff、seq-diff 三部分，1 是指 num-fields 这部分。SAMEFIELDS 场景中，lp_count 为`master_entry_num_fields (只有value个数) + 3 (指flags、ms-diff、seq-diff 这三部分)`。


## XADD 命令核心实现

介绍完 Stream 相关的结构体之后，我们来看 XADD 命令执行的逻辑。XADD 命令的处理逻辑位于 xaddCommand() 函数中，其核心逻辑分为下面四个步骤。

**第一步，解析参数与 Stream 查询**

xaddCommand() 函数在执行 XADD 命令的第一步就是解析、检查 XADD 命令携带的相关参数，得到一个 streamAddTrimArgs 实例。

下面是 streamAddTrimArgs 中各个字段的含义。

-   id、id_given 字段、seq_given：如果 id_given 为 1 表示用户在 XADD 命令中明确指定了 streamID，此时 id 字段存的是 XADD 命令中指定 streamID 实例；如果 id_given 为 0 表示自动生成 streamID，此时 id 字段为空。seq_given 字段也是同理，用于表示自增序号部分是否由用户明确指定。
-   no_mkstream：如果 no_mkstream 为 1，表示在目标 stream 不存在的时候，会自动创建一个空 Stream，并完成后续插入；如果 no_mkstream 为 0，则不会自动创建 Stream。
-   trim_strategy：控制 stream 的截断策略，其中有 MAXLEN、MINID 两种策略，后面会详细分析两种策略。
-   下面的 trim_strategy_arg_idx、approx_trim、limit、maxlen、minid 都与上述两种 stream 截断策略相关，后面分析时详细说明这些字段的功能。

解析完 XADD 命令的参数之后，xaddCommand() 函数会调用 streamTypeLookupWriteOrCreate() 函数从 DB 中查找目标 Stream，如果目标 Stream 不存在，则根据 no_mkstream 参数决定是否创建相应的新 stream 实例并存储到 redisDb 中。创建 Stream 底层调用的是 streamNew() 函数，其中，rax 字段指向了一个新建的空 rax 实例，last_id、first_id 等字段中的时间戳和自增序号都初始化为 0，cgroup 指针指向 NULL。

**第二步，写入消息**

查找到目标 Stream 之后，我们就可以通过 streamAppendItem() 函数向 Stream 中写入消息了。这里先来看一下 streamAppendItem() 函数中各个参数含义：

```c++
int streamAppendItem(

    stream *s,       // 写入的目标stream实例

    robj **argv,    // 记录了此次要写入的field和value集合，其中field的下标索引为偶数，

                    // 例如argv[0]、argv[2]，value的下标索引为奇数，

                    // 例如argv[1]、argv[3]

    int64_t numfields, // argv中field/value对的个数

    streamID *added_id, // added_id如果不为空，则在插入成功时会将新插入的消息ID记录

                        // 到added_id，从而让streamAppendItem()函数的调用者感知到

    streamID *use_id,    // 用户为该消息指定的消息ID

    int seq_given        // 用户为该消息指定的自增序号

)
```

明确了 streamAppendItem() 函数的参数含义之后，下面来看 streamAppendItem() 函数写入新消息的核心逻辑。

1. 首先，需要明确新消息的 ID。如果未明确指定 use_id 参数，则通过 streamNextID() 函数生成消息 ID，其中会将当前时间戳与 stream.last_id 字段中的 ms 时间戳进行比较，如果相等，则将 last_id 的 seq 序号递增，生成新 streamID；如果不相等，则新 streamID 的 seq 部分为 0，ms 部分为当前时间戳即可。如果明确指定了 use_id，这里也需要保证新消息的 ID 要大于 last_id，进而保证 Stream 的消息 ID 是自增的。

1.  接下来，创建 raxIterator 迭代器，定位到 stream->rax 树中的最后一个 Key，并获取其对应的 listpack 实例。

1.  然后，检查该 listpack 是否能继续插入新消息。这里会校验 listpack 所占字节数以及元素个数是否达到上限（字节数上限由 stream-node-max-bytes 配置项指定，默认值是 4096；元素个数上限由 stream_node_max_entries 配置项指定，默认值是 100），进入下面两个处理分支。

    -  如果该 listpack 无法继续插入数据，则创建一个新的 raxNode 节点，节点 Key 为步骤 1 中确定的消息 ID，Value 是全新的 listpack 实例，然后将消息插入到该新建的 listpack 实例中。
    -  如果该 listpack 可以继续插入数据，则将新消息插入到该 listpack 中。

1.  如果是写入一个全新的 listpack，streamAppendItem() 会先插入一条 master entry 消息，其中的 field 由当前新写入的这条消息确定；如果就是写入一个已有 listpack 实例，这里会先比较 master entry 与新消息 id field 集合，从而决定是按照 SAMEFIELDS 格式还是 NONE 格式写入新消息。

完成消息写入之后，streamAppendItem() 还会同步增加 stream 的 length、entries_added 、last_id 等字段，如果是 stream 的第一条消息，这里还会更新 first_id 字段。最后，Redis 会将上述生成的消息 ID 返回给客户端。然后进行一系列通知操作，例如，调用 touchWatchedKey() 通知关注当前 Stream 的客户端，这样就可以让客户端感知到该 Stream 发生了变化。

**第三步，截断操作**

随着消息的不断写入，Stream 所占用的内存会越来越大，为了避免 Redis 内存被打爆，在 XADD 命令执行完上述写入流程之后，还需要进行截断操作删除无用的历史消息，以实现释放 stream 所占空间。要进行截断操作，需要在 XADD 命令指定截断策略，下面是两个带截断策略的 XADD 命令：

```
# MAXLEN截断策略，~表示近似，1000是截断后的消息个数，也就是截断后的消息个数大概在1000左右即可，不要求精确

XADD mystream MAXLEN ~ 1000 * field1 value1 field2 value2

# MINID截断策略，=表示精确，1608540753-0是截断streamID，也就是截断之后，Stream中最大的消息ID是1608540753-0

XADD mystream MINID = 1608540753-0 * field1 value1 field2 value2

# 当然，MAXLEN策略也可以与=一起使用，MINID也可以与~一起使用
```

截断操作的核心实现位于 streamTrim() 函数中，除了 XADD 命令的截断功能会调用它，XTRIM 这个专门进行 Stream 截断的命令，也是调用它实现的。

<p align=center><img src="https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/c059e4b112e34a729c65a2f9b0cd6ee1~tplv-k3u1fbpfcp-zoom-1.image" alt=""  /></p>

下面来看 streamTrim() 的核心逻辑，具体实现和解析如下：

```c
int64_t streamTrim(stream *s, streamAddTrimArgs *args) {

    size_t maxlen = args->maxlen;

    streamID *id = &args->minid;

    int approx = args->approx_trim;

    int64_t limit = args->limit;

    int trim_strategy = args->trim_strategy;



    if (trim_strategy == TRIM_STRATEGY_NONE)

        return 0;



    raxIterator ri; // 1.streamTrim() 会创建一个 raxIterator 迭代器，并将它定位到 stream->rax 中的第一个 raxNode 节点上。

    raxStart(&ri,s->rax);

    raxSeek(&ri,"^",NULL,0);



    int64_t deleted = 0;

    while (raxNext(&ri)) { // 2.检查截断逻辑的条件是否成立

        if (trim_strategy == TRIM_STRATEGY_MAXLEN && s->length <= maxlen)

            break;



        unsigned char *lp = ri.data, *p = lpFirst(lp);

        int64_t entries = lpGetInteger(p);

        if (limit && (deleted + entries) > limit)

            break;

        int remove_node;

        streamID master_id = {0}; /* For MINID */

        if (trim_strategy == TRIM_STRATEGY_MAXLEN) {

            // 2.a.在 streamAddTrimArgs->trim_strategy 字段指定截断策略为 MAXLEN 时，会检查当前 stream 的消息个数减去当前 raxNode 节点中的消息，是否已经小于等于 XADD 命令中指定目标个数（对应 streamAddTrimArgs->maxlen 字段）

            remove_node = s->length - entries >= maxlen;

        } else {

            //  2.b.在 trim_strategy 字段指定截断策略为 MINID 时，会检查当前 raxNode 中最后一条消息的 ID 是否小于 XADD 命令中指定的 MINID 值

            streamDecodeID(ri.key, &master_id);

            streamID last_id;

            lpGetEdgeStreamID(lp, 0, &master_id, &last_id);

            remove_node = streamCompareID(&last_id, id) < 0;

        }



        if (remove_node) { // 3.a.如果删除当前 raxNode 节点中的全部消息之后，仍然未达到目标条件，则可以直接删除该节点。

            lpFree(lp);

            raxRemove(s->rax,ri.key,ri.key_len,NULL);

            raxSeek(&ri,">=",ri.key,ri.key_len);

            s->length -= entries;

            deleted += entries;

            continue;

        }

        // 3.b.如果需要删除当前 raxNode 节点内的部分消息，才能满足我们的目标条件时，

        // 就需要看 XADD 命令是使用了 = 还是 ~ 了，对应到 streamAddTrimArgs 中，就是 approx 字段

        // 当 approx 为 1 时，对应的是 ~，也就是近似截断方式，近似截断方式只会完整地删除

        // 一个 raxNode 节点，会不删除其中部分消息，此时是不能删除当前整个 raxNode 节点，所以不再进行后续的截断处理。

        if (approx) break;



        // 3.b.当 approx 字段为 0，对应的就是 =，也就是精确截断方式，

        // 此时就需要遍历当前 raxNode 节点存储的消息，并将其中需要删除消息设置为已删除状态，

        // 注意，这里仅仅是将消息的 flags 设置为 DELETED 状态，并不会真正进行删除。

        // 很明显，由于需要遍历 listpack 的具体内容，这种精确截断方式的性能就没有近似截断方式高

        

        ... // 省略具体删除精确阶段的具体代码

    }

    raxStop(&ri);



    // 4.在完成消息的截断操作之后，streamTrim() 会同步更新 stream->first_id，用其记录截断后 stream 中的最小 streamID 值

    if (s->length == 0) {

        s->first_id.ms = 0;

        s->first_id.seq = 0;

    } else if (deleted) {

        streamGetEdgeID(s,1,1,&s->first_id);

    }



    return deleted;

}
```

1.  首先，streamTrim() 会创建一个 raxIterator 迭代器，并将它定位到 stream->rax 中的第一个 raxNode 节点上。

1.  然后，检查截断逻辑的条件是否成立，主要是下面三项检查。

    -  在 streamAddTrimArgs->trim_strategy 字段指定截断策略为 MAXLEN 时，会检查当前 stream 的消息个数减去当前 raxNode 节点中的消息，是否已经小于等于 XADD 命令中指定目标个数（对应 streamAddTrimArgs->maxlen 字段）。如果是的话，当前 raxNode 以及之后的数据，也就都不用删除了，此次截断操作也就结束了；如果不是的话，就执行步骤 3 中的截断操作，并后移 raxIterator 迭代器，继续检查下一个节点。
    
    -  在 trim_strategy 字段指定截断策略为 MINID 时，会检查当前 raxNode 中最后一条消息的 ID 是否小于 XADD 命令中指定的 MINID 值。如果是的话，执行步骤 3 中的截断操作，并后移 raxIterator 迭代器，继续检查下一个节点；如果不是的话，此次截断操作立即结束。
    -  另外，这里还会检查此次截断操作中，已截掉的消息个数，是否超过了 streamAddTrimArgs->limit 字段指定的上限个数（也就是 XADD 命令中 LIMIT 参数指定的值）。如果超过了，则此次截断操作也会立即结束。

1.  接下来看 streamTrim() 在上述截断条件成立的时候是如何操作的。

    -  如果删除当前 raxNode 节点中的全部消息之后，仍然未达到目标条件，则可以直接删除该节点。比如，在处理 ` XADD mystream MAXLEN ~ 1000 * field1 value1  `这条命令的时候，我们删除当前 raxNode 中的全部消息之后，还剩 1005 条消息，显然还没有达到 1000 这个目标条件，当前节点可以删除。再比如，处理 `XADD mystream MINID = 1608540753-0 * field1 value1` 这条命令的时候，当前最后一条消息的 ID 是 `1608540752-0`，显然是小于 `1608540753-0` 的，所以当前节点可以删除。
    
    -  如果需要删除当前 raxNode 节点内的部分消息，才能满足我们的目标条件时，就需要看 XADD 命令是使用了 `=` 还是 `~` 了，对应到 streamAddTrimArgs 中，就是 approx 字段。当 approx 为 1 时，对应的是 `~`，也就是近似截断方式，近似截断方式只会完整地删除一个 raxNode 节点，会不删除其中部分消息，此时是不能删除当前整个 raxNode 节点，所以不再进行后续的截断处理。当 approx 字段为 0，对应的就是 `=`，也就是精确截断方式，此时就需要遍历当前 raxNode 节点存储的消息，并将其中需要删除消息设置为已删除状态，注意，这里仅仅是将消息的 flags 设置为 DELETED 状态，并不会真正进行删除。很明显，由于需要遍历 listpack 的具体内容，这种精确截断方式的性能就没有近似截断方式高。

1.  在完成消息的截断操作之后，streamTrim() 会同步更新 stream->first_id，用其记录截断后 stream 中的最小 streamID 值。

**第四步，修改命令参数**

通过前面的介绍我们知道，自动生成 streamID 与 Redis 的本地时间强相关的。如果是将 XADD 命令原封不动地同步到 Slave 节点或是写入 AOF 文件，就会出现主从数据不一致或是 AOF 恢复出来数据不正确的情况。

为了避免上述问题，xaddCommand() 在执行完 XADD 命令之后，会对其参数值进行如下三处修改。

1.  更新 XADD 命令中的 streamID。如果是用户指定 streamID 的话，则 streamID 不变；如果是自动生成 streamID 的话，这里会将 XADD 命令中的 “*” 替换成自动生成的 streamID 值。
1.  如果使用了 “~” 参数，也就是近似截断的方式，需要替换成 “=”，也就是精确截断的方式。
1.  根据 Stream 截断之后的状态，替换原 XADD 命令中的截断目标参数值。如果使用的是 MAXLEN 策略，会将它替换成截断后 Stream 的消息个数；如果是 MINID 截断策略，会将它修改成截断后的 Stream 中的第一条消息 ID。这样，就可以保证在从库（或者 AOF 回放）执行 XADD 命令的时候，截断逻辑的部分与主库一致。


## 总结

在这一节中，我们介绍了 Redis 中 Stream 的核心内容。我们首先分析了 Stream 结构体的核心实现，了解了 Stream 底层的数据结构；然后介绍了 Stream 存储消息的格式；最后讲解了向 Stream 写入消息的 `XADD` 命令的核心实现，其中涉及到查询 Stream 确认写入位置、写入消息、截断 Stream、修改参数用来传播到从库和 AOF 日志四个关键步骤。

下一节，我们将继续介绍 Stream 中的 `XREAD` 命令和 `XDEL` 命令的实现。