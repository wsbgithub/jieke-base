在上一节中，我们详细介绍了 Stream 存储消息的格式，以及 XADD 命令执行的核心逻辑。这一节我们就紧接上一节，继续介绍 Stream 中的 XDEL 命令以及 XREAD 命令。

## streamIterator 迭代器实现

无论是要读取消息还是要删除消息，我们都要先查找到这条消息才行。Stream 查询消息的逻辑，重度依赖了 `streamIterator` 这个迭代器，它**不仅屏蔽了迭代过程中 rax 和 listpack 两种数据结构的切换，还提供了范围迭代、正向/反向迭代、精确查找等高级功能**。

streamIterator 其具体定义如下：

```c++
typedef struct streamIterator {

    stream *stream;         // 当前迭代的stream实例

    uint64_t start_key[2];  // 该迭代器的迭代起始消息ID和终止消息ID，也就是说，只会在

                            // 这个范围内迭代。数组中的第一个元素是streamID->ms字段

                            // 值，第二个元素是streamID->seq字段值

    uint64_t end_key[2];

    raxIterator ri;         // 当前streamIterator底层依赖的rax树迭代器

    int rev;                // 当前迭代器是否为逆序迭代



    // 下面是在迭代过程中使用到的变量，首先是用来记录当前迭代的listpack中

    // master entry信息的几个字段：

    streamID master_id;           // master entry的消息ID

    uint64_t master_fields_count; // master entry中的field个数

    unsigned char *master_fields_start; // master entry在listpack中的

                                        // 起始位置

    unsigned char *master_fields_ptr;   // 用于迭代master entry的field

    // 下面是用来记录当前迭代到的消息内容的一些字段：

    int entry_flags;             // 用于记录当前迭代消息的flags值

    unsigned char *lp;           // 当前迭代到的listpack实例    

    unsigned char *lp_ele;       // 用于迭代的listpack的指针

    unsigned char *lp_flags;     // 用于记录消息flags位置的指针

    unsigned char field_buf[LP_INTBUF_SIZE];     // 用来存储field、value的buffer

    unsigned char value_buf[LP_INTBUF_SIZE];

} streamIterator;
```

了解了 streamIterator 的核心结构之后，我们再来介绍一下如何使用 streamIterator 迭代器。

下面是 streamIterator 的基本代码模板，后面介绍的 XREAD、XDEL 等命令，也是套用了这个代码模板：

```c
streamIterator myiterator;  // 创建streamIterator迭代器

streamIteratorStart(&myiterator,...);  // 初始化streamIterator迭代器能够迭代的范围

int64_t numfields;

while(streamIteratorGetID(&myiterator,&ID,&numfields)) { // 推进streamIterator迭代器

    while(numfields--) {

        unsigned char *key, *value;

        size_t key_len, value_len;

        // 读取消息中的field和value值

        streamIteratorGetField(&myiterator,&key,&value,&key_len,&value_len);

        ... do what you want with key and value ...

    }

}
```

下面我们来分析一下模板代码中的关键函数。

首先是 **streamIteratorStart() 函数**，它主要是完成下面三个操作。

-   一个是确认迭代的范围，也就是初始化 streamIterator 的 start_key 和 end_key 字段。如果未指定迭代的起止 streamID 范围，那迭代范围就是从 Stream 的第一条消息开始，到 Stream 的最后一条消息。
-   二是确定迭代的方向，也就是初始化 rev 字段。如果 rev 字段为 0，表示 streamIterator 是按照 streamID 从小到大的正向迭代，反之则为反向迭代。
-   三是初始化 rax 迭代器。初始化用于迭代 stream->rax 的 ri 字段，这里会根据 rev 指定的迭代方向，确定 ri 迭代器的方向。

完成初始化之后就要进入迭代循环，其中是否能进行迭代的条件由 streamIteratorGetID() 函数进行判断。注意 streamIteratorGetID() 函数的两个点：一个是其返回值，返回 1 表示还有可迭代的消息，返回 0 表示没有可以迭代的消息了；另一个是存在可迭代消息的时候，streamIteratorGetID() 函数会将下一条要迭代的消息 ID 以及消息 field 的个数，通过第二个参数（上述模板代码中的 ID 参数）和第三个参数（上述模板代码中的 numfields 参数）返回给调用方。

**streamIteratorGetID() 函数**本身的逻辑并不复杂，下面以正序迭代的执行逻辑为例，描述一下 streamIteratorGetID() 函数的核心流程。

1.  在第一次迭代的时候，streamIterator 迭代器的 lp 字段为空，此时会尝试后移 ri 迭代器，查到下一个可迭代的 raxNode 节点。
1.  查找到此次要迭代的 raxNode 节点之后，开始从对应 listpack 实例中解析 master entry 来填充迭代器中与 master entry 相关的元数据，例如，master_id、master_fields_count 以及 master_fields_start 等字段。
1.  继续遍历 listpack 处理下一条消息。这里先会将 streamIterator 迭代器中的 lp_ele 指针不断后移，读取消息的 flags、ms-diff、seq-diff 三部分，其中 flags 部分的值会被记录到 streamIterator 迭代器的 entry_flags 字段中。

    如果 flags 部分包含了 SAMEFIELDS 标识，就可以确定当前消息的 field 是与 master entry 一致的，返回当前消息 field 个数，就可以复用 master_fields_count 字段值。如果 flags 部分不包含 SAMEFIELDS 标识，说明当前这条消息的 field 与 master entry 不一致，这里就要继续读取下一个 listpack 元素，其中记录的才是当前消息真正的 field 个数。

    另外，如果 flags 包含 DELETED 标识，则表示这条消息已经被标记删除了，这里会直接跳过当前消息所占的全部 listpack 元素，并重新执行步骤 3 迭代下一条消息。

4.  通过当前消息的 ms-diff 和 seq-diff 两部分以及 master_id，计算出当前消息的真实 streamID，并与迭代器的 start_key 和 end_key 比较，确定迭代是否已经超出了范围。如果超出了迭代范围，直接返回 0，表示没有无可迭代的消息；反之，返回 1，表示有可迭代的消息。
5.  如果当前 listpack 中的消息都迭代完毕了，就会重新执行步骤 1，查找下一个可以迭代的 raxNode 节点。如果查找不到下一个可迭代节点，也会返回 0。

通过上述分析，我们可以用下面一张图来表示，调用一次 streamIteratorGetID() 函数之后，streamIterator 迭代器的状态。在调用完一次 streamIteratorGetID() 函数之后，streamIterator 迭代器已经处理完了消息头的部分，用于迭代 listpack 的 lp_ele 指针，已经指向消息的有效负载，也就是下图所示的位置。


<p align=center><img src="https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/5bc0a00e31cb4263b4915ffc0b2337cc~tplv-k3u1fbpfcp-watermark.image?" alt="image.png"  /></p>

在 streamIteratorGetID() 函数查找到要迭代的消息之后，我们继续来看 streamIterator 的模板代码。在第一层 while 循环中，我们就可以根据当前消息的 field 个数（numfields 遍历），不断调用 streamIteratorGetField() 函数，读取消息的 field 和 value 值了。

**streamIteratorGetField() 函数**的实现逻辑就是通过 lpNext() 函数，推进读 streamIterator->lp_ele 指针的位置，通过 lpGet() 函数读取具体的数据，读取到的 field 和 value 值会分别记录到 streamIterator 迭代器的 field_buf 和 value_buf 缓冲区中。下面是 streamIteratorGetField() 函数的核心代码：

```c
void streamIteratorGetField(streamIterator *si, unsigned char **fieldptr, unsigned char **valueptr, int64_t *fieldlen, int64_t *valuelen) {

    if (si->entry_flags & STREAM_ITEM_FLAG_SAMEFIELDS) { // SAMEFIELDS消息，复用了master entry的field值，写入field_buf

        *fieldptr = lpGet(si->master_fields_ptr,fieldlen,si->field_buf);

        si->master_fields_ptr = lpNext(si->lp,si->master_fields_ptr);

    } else { // NONE消息，直接中消息中获取field值，写入field_buf

        *fieldptr = lpGet(si->lp_ele,fieldlen,si->field_buf);

        si->lp_ele = lpNext(si->lp,si->lp_ele);

    }

    // 从消息中读取value值，写到value_buf缓冲区

    *valueptr = lpGet(si->lp_ele,valuelen,si->value_buf);

    si->lp_ele = lpNext(si->lp,si->lp_ele);

}
```

从上面的代码我们可以看出，对于 SAMEFIELDS 消息，这里是复用 master entry 的 field，在读取 field 的时候，是推进 master_fields_ptr 指针读取 master entry 中的 field 值。在下次 streamIteratorGetID() 函数的时候，master_fields_ptr 指针会重新指向 master entry 的第一个 field，为迭代下一条 SAMEFIELDS 消息做准备。


## XREAD 命令

分析完 streamIterator 迭代消息的模板代码之后，我们接下来看 XREAD 命令是如何从 stream 读取消息。

XREAD 命令的完整格式如下，XREAD 命令支持一次从多个 Stream 读取数据，这里指定的 Stream Key 与后面的 streamID 参数需要一一对应，具体含义是从该 streamID 开始往后读取；具体返回多少消息，由 COUNT 参数指定，如果不指定 COUNT，会把 Stream 中全部的消息都返回；如果此次 XREAD 命令从指定的 Stream 中，都读不到数据，就会根据 BLOCK 指定的时间进行阻塞等待。

```
XREAD [COUNT count] [BLOCK milliseconds] STREAMS key [key ...] id [id ...]
```

处理 XREAD 命令的入口是 **xreadCommand() 函数**，它首先会解析并检查 XREAD 命令的各个参数是否合法，然后对参数中的特殊值进行替换。例如，指定的 streamID 列表中如果出现了 `“$”` 符号，表示当前 Consumer 此次读取对应 stream 的最新消息，这里就会将 `“$”` 符号替换成对应 stream->last_id 字段值，即对应 stream 中最后一条消息的 ID。

接下来，xreadCommand() 函数会扫描 Stream 列表，逐个检查目标 Stream 中是否还有能够读取的消息。如果有消息能读取的话，就会调用 streamReplyWithRange() 函数从 Stream 读取消息。

streamReplyWithRange() 函数是通用的、从 Stream 中范围读取消息的方法，如下图所示，在 XREAD、XRANGE、XCLAIM、XINFO 命令中都会调用到该方法。

<p align=center><img src="https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/157c43eb5cbf4818a7f8c74c402884b7~tplv-k3u1fbpfcp-zoom-1.image" alt=""  /></p>

下面来看看 streamReplyWithRange() 函数中各个参数的含义：

```c++
size_t streamReplyWithRange(client *c, // 读取的消息会返回给该客户端

    stream *s,  // 读取的目标Stream实例

    streamID *start, streamID *end,  // 读取的起止streamID值，end为NULL时，

                                     // 表示读取从start开始到stream结尾的全部消息

    size_t count, // 返回消息条数的上限值，count为0的时候，表示不限制消息条数

    int rev, // rev为0时表示从start到end正向读取，rev为1时表示从end向start反向读取

    streamCG *group, streamConsumer *consumer,  // XREADGROUP命令使用的参数

    int flags, // 一些标志位信息，XREADGROUP命令中会用到该参数

    streamPropInfo *spi // 用于传播命令的额外信息，后面会详细说明

)    
```

streamReplyWithRange() 函数处理 XREAD 命令读取的逻辑比较简单，其中会先根据 start、end、rev 等参数初始化一个 streamIterator 迭代器，然后按照前文介绍的 streamIterator 模板代码，去读取Stream 中的消息，并返回给客户端。在迭代过程中，会同时判断是否达到了 COUNT 参数指定的上限值，达到上限值时，会立刻结束此次读取。

## XDEL 命令核心实现

XDEL 命令的功能是按照消息 ID 删除消息，对应的处理函数是 **xdelCommand() 函数**，其核心逻辑是先根据命令参数中指定的 Key 从 DB 中查询目标 Stream，然后解析 XDEL 命令中指定的 streamID，最后调用 streamDeleteItem() 函数，根据 streamID 删除消息。

streamDeleteItem() 函数删除消息的时候，并不是真正从 listpack 中删除消息，而是在消息的 flags 字段中设置 DELETED 标记，同时，还会更新对应 master entry 中 count 值以及 deleted 值。在 Redis 发现一个 raxNode 节点内的全部消息都被添加了 DELETED 标记时，才会将整个 raxNode 节点以及其中的 listpack 释放掉，从而实现真正的物理删除。

streamDeleteItem() 函数也是套用了上述 streamIterator 迭代器的模板代码，先定位到要删除的目标消息，然后调用 streamIteratorRemoveEntry() 函数进行删除。streamIteratorRemoveEntry() 首先修改目标消息的 flags，在其中添加 DELETED 标记，表示该条消息已被删除，这里通过 streamIterator->lp_flags 指针以及 lpReplaceInteger() 函数更新 listpack 中消息的 flags 值。然后，streamIteratorRemoveEntry() 函数会检查并更新当前 listpack 的 count、deleted 值。

-   如果当前 count 值为 1，说明此次删除的就是最后一条有效消息，将其 flags 设置成 DELETED 之后，整个 listpack 内的全部都是已删除消息，那我们就可以直接将当前 raxNode 删除掉。
-   如果当前 count 值大于 1，说明此次删除之后，整个 listpack 还有其他有效消息，那我们依旧保留 raxNode 节点，但需要将 count 减 1，将 deleted 值加 1。



## 总结

在这一节中，我们重点介绍了 Redis Stream 中的 XREAD 命令和 XDEL 命令。首先，我们讲解了这两种命令底层都使用到的 **Stream 迭代器**的原理；然后介绍了 XREAD 命令读取消息的核心实现；最后分析了 XDEL 命令的删除消息的核心流程。

下一节，我们将介绍 Stream 消费侧相关的命令。