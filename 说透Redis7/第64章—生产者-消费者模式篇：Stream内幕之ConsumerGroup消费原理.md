在前面两节中，我们介绍了 Stream `读`、`写`、`删`三种基本命令的实现原理。而在实际应用 Stream 的时候，一般会`让一个或多个 Consumer 客户端组成一个 Consumer Group`，然后按照 Consumer Group 的维度去进行消费。

因此，这一节，我们就来介绍一下 Stream 中的 Consumer Group 是如何进行消费的。


## XGROUP 命令详解

在使用 Consumer Group 消费之前，我们要先通过 XGROUP CREATE 命令创建一个 Consumer Group，XGROUP CREATE 命令的完整格式如下：

```
XGROUP CREATE key groupname id | $ [MKSTREAM] [ENTRIESREAD entries_read]
```

在执行 XGROUP CREATE 命令时，xgroupCommand() 函数会先对命令参数进行解析和检查。

1.  这里 key 是 Stream 的名称，这里要保证 key 对应的目标 Stream 存在。
1.  XGROUP CREATE 命令的第四个参数指定的是这个 Consumer Group 从哪个 streamID 开始消费，如果它的值是 “$”，这里会将该参数替换成 Stream 中最后一条消息的 ID，也就是 stream->last_id 字段的值。
1.  如果包含 MKSTREAM 参数，则会在目标 Stream 不存在的时候，自动创建目标 Stream 实例。

完成上述检查之后，xgroupCommand() 就会调用 streamCreateCG() 函数创建 streamCG 实例，其中 streamCG->last_id 字段会指向 XGROUP 命令指定的 streamID，pel、consumer 等字段初始化为空 rax 树。新建的 streamCG 实例会被存储到到 stream->cgroups 这个 rax 树中，Key 是 XGROUP 命令指定的 groupname，Value 就是这个 streamCG，这样，就将 sreamCG 与 Stream 关联起来了。

这里简单介绍一下 streamCG 结构体定义。如下所示，其中有三个关键的字段，一个是 last_id 字段，记录了当前 Consumer Group 的消费位置，这个 Consumer Group 中的 Consumer 后续读取请求的时候，会在 last_id 指定的 streamID 之后开始读取；另一个是 pel 字段，它用暂存已经发送给 Consumer，但 Consumer 还未确认的消息，当然，如果 Consumer 在读取消息的时候，明确指定了 NOACK 参数，那消息就不会被记录到 pel 中；最后是 consumers 字段，它记录了这个 Consumer Group 中的所有 Consumer，其中的 Key 是 Consumer 的名称，Value 是用于表示 Consumer 的 streamConsumer 结构体实例。

```c++
typedef struct streamCG {

    streamID last_id;   // Consumer Group会从这个streamID开始消费

    long long entries_read; // 用于记录读取次数的统计字段

    rax *pel;       // 用暂存发送给Consumer，但Consumer还还未确认的消息

    rax *consumers; // 记录了该Consumer Group中的Consumer

} streamCG;
```


XGROUP 命令除了可以接 CREATE 子命令，来创建 Consumer Group ，还支持非常多其他的操作，比如：

```c
// 设置指定Consumer Group的消费位置，即修改其last_id字段值

XGROUP SETID key groupname id | $ [ENTRIESREAD entries_read]



// 销毁指定的Consumer Group

XGROUP DESTROY key groupname



// 在指定的Consumer Group中创建Consumer，实际上就是创建对应的streamConsumer实例

// 并插入到streamCG->consumers这棵rax树中

XGROUP CREATECONSUMER key groupname consumername



// 销毁指定Consumer Group中的Consumer

XGROUP DELCONSUMER key groupname consumername
```

这里 `XGROUP CREATECONSUMER` 命令创建的 Consumer，实际上只是一个 streamConsumer 结构体，streamConsumer 结构体的具体定义如下。我们会发现，这个 streamConsumer 并没有与某个 client 进行绑定，只是维护了一个名字和 pel 列表，后续我们可以将 Consumer 的名称分配给任意的 Redis 客户端，而不是与某个客户端进行绑定。

```c++
typedef struct streamConsumer {

    mstime_t seen_time;  // Consumer最后一次活跃时间

    sds name;   // Consumer的名称，也是唯一标识

    rax *pel; // 用于暂存已发送给这个Consumer，但是没有得到确认的消息

} streamConsumer;
```


## XREADGROUP 命令解析

创建 Consumer Group 和 Consumer 之后，Consumer 客户端就可以使用 XREADGROUP 命令，以 Consumer Group 内的一个 Consumer 的身份，从 Stream 中读取消息了。这里简单说明一下 Consumer Group 消费 Stream 中消息的基本原理，如果有的同学了解 Kafka 中 Consumer Group 可以直接跳过下面对 Consumer Group 的说明。

首先，Consumer Group 中的 Consumer 读取数据的时候，需要使用 XREADGROUP 命令，而不是 XREAD 命令。在 XREADGROUP 命令参数中，除了指定目标 Stream 和读取的起始位置，还会指定自己所属的 Consumer Group 以及自身 Consumer 的名称。XREADGROUP 命令的完整格式如下：

```c
XREADGROUP GROUP group consumer [COUNT count] [BLOCK milliseconds] [NOACK] STREAMS key [key ...] id [id ...]
```


在同一个 Consumer Group 中的多个 Consumer，消费同一个 Stream 的时候，只能获取到该 Stream 中的一部分消息。

假设一个 Stream 中有 A、B、C 三条消息，在一个 Consumer Group 中有 1、2 两个 Consumer 客户端在消费该 Stream，那么可能会出现： A、C 两条消息分配给了 Consumer 1，B 消息分配给了 Consumer 2，如下图所示。

另外，每条消息在一个 Consumer Group 中只有一个明确的 Consumer。上述示例中，消息 A 在分配给 Consumer 1 之后，即使 Consumer 1 宕机，Consumer 2 也无法读取到消息 A，当然，这只是在正常场景下的结果。在 Consumer 1 发生不可恢复的故障且消息 A 分配给了 Consumer 1 但未被正常消费的时候，我们需要让 Consumer2 重新消费 A 消息，此时就可以通过强制手段，将消息 A 重新分配给 Consumer 2。

最后，在 Consumer Group 中的一个 Consumer 进行消费的时候，消息会暂时写入其对应的一个 Pending Entries List （PEL）队列中，需要 Consumer 在消费完消息之后，使用 XACK 命令对消息进行确认才会将其从 PEL 队列中清理掉，并记录消息已经被该 Consumer 消费掉了。如果使用 XREADGROUP 命令时携带 NOACK 子命令，就会认为该消息无需 Consumer 进行确认，消息也不会进入 PEL 队列。


<p align=center><img src="https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/33fefd452ed14f1db08025e52a59198a~tplv-k3u1fbpfcp-watermark.image?" alt="image.png"  /></p>

下面我们来看 XREADGROUOP 命令的执行逻辑，XREAD 和 XREADGRUOP 对应的执行函数都是 xreadCommand() 函数。下面是处理 XREADGROUP 命令的逻辑。

1.  首先，xreadCommand() 命令会对 XREADGROUP 命令的参数进行解析和检查。

    -  在使用 XREADGROUP 命令时，需要同时使用 GROUP 子命令指定当前客户端所属的 Consumer Group 名称，以及对应的 Consumer 名称。
    -  只有 XREADGROUP 命令中可以携带 NOACK 子命令。如果是 XREAD 命令中携带了 NOACK，直接返回错误和提示信息。如果是 XREADGROUP 命令携带了 NOACK 子命令，会在 flags 中设置 NOACK 标记位，这里的 flags 是一个本地临时变量，决定了后续 Stream 的行为。
    -  根据 XREADGROUP 命令指定的 Consumer Group 名称，查找每个 Stream 的 cgroup 树，确保其中都存在对应的 streamCG实例，否则返回错误和提示信息。
    -  XREADGROUP 命令中指定的 streamID 不能使用 “$” 符号。
    -  XREADGROUP 命令中指定的 streamID 可以使用 “>” 符号，表示从 Consumer Group 的 last_id 处开始读取消息。这里会将 ms 和 seq 字段设置为 UINT64_MAX，作为 streamID 标识，后续处理过程还会调整该值。

2.  接下来，xreadCommand() 函数根据 XREADGROUP 命令指定的 Stream 列表，并结合 streamCG 的 last_id 确认此次是否有数据需要返回给该 Consumer。

    -  如果指定的 streamID 为 “>” 符号，表示 Consumer Group 想消费之前未消费到的新消息，此时会比较 Stream 中最后一条消息 ID 与 Consumer Group 之前消费到的最后一条消息的 ID（即 streamCG->last_id）大小，从而确定是否有新消息存在。如果有新消息的话，会执行后续读取 stream 的逻辑。
    
    -  如果明确指定了 streamID 值，表示是 Consumer 想消费已分配给自己、但是自己还没有确认的历史消息。这种命令一般是在 Consumer 宕机重启之后，处理已分配但未响应的消息，这样就可以保证 At Least Once 的语义。回到 xreadCommand() 函数，此时它会在临时变量 flags 中设置 HISTORY 标记位，然后执行后续读取 stream 的逻辑。

3.  完成上述检查之后，开始执行 streamReplyWithRange() 函数读取 stream 中的数据，其中根据 HISTORY 标记位和 NOACK 标记位区分了不同的处理分支，如下图所示：


<p align=center><img src="https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/4be06d53a698461b96f7cb416ce83a5f~tplv-k3u1fbpfcp-watermark.image?" alt="image.png"  /></p>

-  先来看读取新消息的逻辑，这里会创建 streamIterator 迭代器并从 streamCG->last_id 位置开始读取新消息，直至 Stream 结尾。读取过程中会做两件事情，一个是后移 stream->last_id 值，表示当前 Consumer Group 已经消费了该消息；二是将读取到的消息返回给该 Consumer 客户端。

    如果消息需要 ACK 确认，在读取上述读取消息的过程中，就需要为每条新消息创建对应的 streamNACK 实例，并分别记录到 Consumer Group 和 Consumer 的 PEL 队列中。

    正常情况下，我们从 Consumer Group 的 last_id 开始一个个读取到的消息，都是未分配给其他 Consumer 的消息，但如下图所示，如果我们用 XGROUP SETID 命令重置过 Consumer Group 的 last_id 值，就可能出现读取到一个已分配的消息。


<p align=center><img src="https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/96561f9fdc2b4b908569caaa550820b4~tplv-k3u1fbpfcp-watermark.image?" alt="image.png"  /></p>

- 如果读取到已经被分配给了其他 Consumer，但是还未收到 ACK 确认的消息，则会在 Consumer Group 的 PEL 队列中有对应的 streamNACK 记录，此时会更新该 streamNACK 记录指向当前 Consumer，同时还会将 streamNACK 记录从上次分配的 Consumer 关联的 PEL 队列中删除，然后插入到当前 Consumer 关联的 PEL 队列中，后续将由当前 Consumer 对这条消息进行 ACK 确认。

- 接下来看读取已分配但未响应的历史消息的逻辑，如前面的流程图所示，读取历史消息会进入 streamReplyWithRangeFromConsumerPEL() 函数，其中实际上迭代的是当前 Consumer 的 PEL 队列中的消息。该函数会先从 Consumer 关联的 PEL 队列中，拿到未确认的历史消息 ID，然后再去 Stream 中查找完整的消息内容，并返回给客户端。最后，更新该消息对应的 streamNACK 中的 delivery_count 和 delivery_time，delivery_count 用来记录这条消息发送的总次数，delivery_time 字段用来记录这条消息最后一次发送时间戳。另外，如果 pel 队列中的消息已经被删除，则返回给客户端空数据。

<!---->

4.  最后，XREADGROUP 命令的核心虽然是读取消息，但是可能还是会产生一些 redisDb 的变更。例如，创建 streamNACK 实例、修改 streamCG->last_id 等，所以也要将这些变更传递到从库，还要在 AOF 文件中进行相应的记录。xreadCommand() 函数不会直接将 XREADGROUP 命令发送到 Slave 节点或是写入到 AOF 文件，而是将这些修改操作转换成 XCLAIM 命令、XGROUP SETID 命令，再发送给 Slave 节点或写入到 AOF 文件。XCLAIM 命令的功能和实现，我们会在下一节展开介绍。

分析完 XREADGROUP 命令读取消息的核心逻辑之后，我们最后来看使用 XREADGROUP 命令的最佳模板代码，也就是下面这段伪代码。简单说明一下这段伪代码的逻辑：第一个 while 循环是在 Consumer 客户端启动时执行的，用来处理已分配当前 Consumer 客户端，但当前 Consumer 因为宕机等原因未及时确认的消息。处理完未确认消息之后，进入第二个 while 循环是 Consumer 客户端，它也是当前 Consumer 客户端正常消费 Stream 消息的地方，这里会从 Consumer Group 的 last_id 处读取消息，每次只读取 100 条消息，最多阻塞 1 秒钟，读取到的消息会被 process_message() 这个业务函数处理。在 Consumer 客户端处理完一条消息之后，会立刻发送 XACK 命令对消息进行确认。

```c
WHILE true # 使用XREADGROUP GROUP命令读取PEL中未确认的消息

    stream_entries = 'XREADGROUP GROUP $GroupName $ConsumerName 

                      BLOCK 1000 COUNT 100 STREAMS mystream 0'

    IF entries == nil

        puts "PEL EMPTY"

        BREAK

    end

    process_messages(stream_entries) # 重新消息未确认的消息

END



WHILE true # 使用XREADGROUP GROUP命令读取的新消息

    stream_entries = 'XREADGROUP GROUP $GroupName $ConsumerName 

                      BLOCK 1000 COUNT 100 STREAMS mystream >'

    if entries == nil

        puts "Timeout... try again"

        CONTINUE

    end

    process_messages(entries)

END



FUNCTION process_messages(stream_entries){

    FOREACH entries AS stream_entries

        FOREACH stream_entries as message

            process_message(message.id,message.fields)

            # ACK the message as processed

            XACK mystream $GroupName message.id # 发送XACK进行确认

        END

    END

}
```

这里简单说一下 Redis 处理 XACK 命令的逻辑，Redis 会根据消息 ID 将对应的 streamNACK 记录从 Consumer Group 以及当前 Consumer 关联的 PEL 队列中删除，表示消息已成功消费。在实际场景中，我们也可以在 XACK 命令后面携带多个消息 ID，实现批量确认的效果，这样可以减少网络资源的消耗。


## XCLAIM 命令解析

前文提到，Consumer 使用 XREADGROUP 命令读取消息之后，消息会被写入 Consumer Group 以及 Consumer 对应的 PEL 队列进行保存。如果 Redis 在之后很长一段时间内，都没有收到该 Consumer 发送的 XACK 确认，则消息对应的 streamNACK 实例会一直存在于 PEL 队列中。如果是这个 Consumer 已经宕机下线了，就会造成 streamNACK 堆积的问题，为了解决这个问题，其他 Consumer 可以调用 XCLAIM 命令，将这些未确认的消息分配给自己。

下面是 XCLAIM 命令的格式，其中 key、group、consumer 参数指明了目标 Stream、Consumer Group 以及当前 Consumer 的名称，min-idle-time 参数指定了一个时长，当前 Consumer 只会处理 now（当前时间）- minidle 之后没有再发送过的消息。其他子命令这里不再一一介绍，在下面分析 XCLAIM 命令执行逻辑的时候，会逐个说明。

```c
XCLAIM key group consumer min-idle-time id [id ...] [IDLE ms] [TIME unix-time-milliseconds] [RETRYCOUNT count] [FORCE] [JUSTID]
```

处理 XCLAIM 命令的核心逻辑位于 xclaimCommand() 函数中，其核心逻辑如下。

1.  首先，xclaimCommand() 函数会解析并检查 XCLAIM 命令的全部参数，例如，检查命令中的目标 Stream、Consumer Group 以及 Consumer 是否存在等等。

2.  接下来，遍历 XCLAIM 命令中携带的全部消息 ID，进行如下处理。

    - 从 Consumer Group 的 PEL 队列中查找对应的 streamNACK 实例。如果查到了对应的 streamNACK 实例，就正常执行后面重新分配的逻辑。如果查找不到，可能是消息已经被确认了，也就没有必要将消息重新分配给当前 Consumer 了，整个 xlcaimCommand() 函数直接结束。

        但是，有一种特殊情况，就是 XCLAIM 命令中添加了 FORCE 子命令，它会强制将消息分配给当前 Consumer，此时 xclaimCommand() 会去确认该消息依旧存在于 Stream 中，如果确认成功，则为该消息创建一个对应的 streamNACK 实例写入到 Consumer Group 的 PEL 队列中。

    - 接下来，检查 streamNACK 中记录了 delivery_time 时间戳距今的时长，如果未超过 min-idle-time 参数指定的时长，说明该消息近期发送给过其他 Consumer，此次 XCLAIM 命令不会进行处理。

    - 通过 min-idle-time 的检查之后，就可以将该消息与旧 Consumer 解绑，并分配给当前 Consumer。也就是将该 streamNACK 实例从旧 Consumer 的 PEL 队列中删除，然后写入到当前 Consumer 的 PEL 中。
    - 在重新分配消息的时候，还会修改 streamNACK 中的 delivery_time 和 delivery_count 字段。先来看 delivery_time 字段的更新：如果使用 IDLE 子命令指定了一个空闲时长（idletime），delivery_time 字段会更新为 `当前时间戳 - idletime`；如果使用 TIME 子命令指定了一个具体的时间戳，则 delivery_time 字段更新为该指定的时间戳；如果未指定 IDLE 或 TIME 子命令，则 delivery_time 字段更新为当前时间。

        再来看 delivery_count 字段的更新：如果未使用 RETRYCOUNT 和 JUSTID 子命令，则 delivery_count 字段值增加 1，因为下面就会将消息返回给当前 Consumer；如果使用了 JUSTID 子命令，则 delivery_count 字段值不变，因为后续返回不会返回消息的具体内容，而是只返回一个消息 ID；如果使用了 RETRYCOUNT 子命令指定了一个明确的重试次数，这里会将 delivery_count 字段更新该值。

    - 正如前面所示，如果使用了 JUSTID 子命令，这里只会将消息 ID 返回给当前 Consumer。否则就通过 streamReplyWithRange() 函数从 stream 中读取消息内容并返回给当前 Consumer。

<!---->

3.  最后，xclaimCommand() 函数将 XCLAIM 命令传播给 Slave 节点并写入 AOF 文件中。

在 Consumer 通过 XCLAIM 命令不仅变更了消息的分配关系之后，还可以拿到消息的内容，对消息进行消费之后，这个 Consumer 就可以会用 XACK 命令确认消息了。

XAUTOCLAIM 命令是 XCLAIM 命令的升级版本，可以把它看作是 XPENDING 和 XCLAIM 命令的组合，其中，XPENDING 命令可以查看现在有多少消息还处于未确认的状态。在分析完前面的这些 Stream 核心命令之后，小伙伴们再来看 XAUTOXCLAIM、XPENDING 命令就会非常简单。


## 总结

在这一节中，我们重点介绍了 Stream 消费侧的关键命令实现。首先，我们介绍了 `XGROUP` 命令的使用以及相关的底层结构；然后讲解了 `XREADGROUP` 命令的使用，以及一个 Consumer 是如何在一个 Consumer Group 中消费消息的；最后介绍了 `XCLAIM` 命令解决的问题以及其底层实现。

从下一节开始，我们将介绍 Redis 的一些扩展内容，例如，Redis 与 Lua 脚本交互的原理、GEO 命令的实现等等。