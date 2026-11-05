# 清理没有 TTL 的旧缓存 key

对应文章：[清理共享 Redis 里的旧缓存 key：Lua 分批 UNLINK、SLOWLOG 验证，以及 ElastiCache 和 cluster 模式下的差异](https://meirong.dev/posts/redis-legacy-cache-key-cleanup/)

[cleanup.sh](cleanup.sh) 和文章附带的那份逐字节相同。它在服务端用 Lua 每次只处理一步 `SCAN` 拿到的 key，只 `UNLINK` 没有 TTL 的旧名字，key 名不离开服务端。这里的两个脚本分别在单机和 cluster 上跑它，核对文章里写「本地测过」的那几处。

```bash
./standalone.sh   # 单机 Redis 7.4.2
./cluster.sh      # 三主节点 Redis 7.4.12 cluster
```

镜像拉好之后，两个脚本在 M2 Pro + OrbStack 上各跑 7 秒左右。cleanup.sh 在 `redis:7.4.12-alpine` 容器里执行，用法和文章里的 `docker run … sh -s <模式> < cleanup.sh` 一样。输出在 [results/](results/)。

## standalone.sh

db 3 里写 1200 个 `Users:<n>`，再放四个干扰 key：名字带空格的旧 key `Users:with space`（应该删掉）、带 TTL 的旧名字 `Users:ttl`、新缓存 `my-service:users:v1:1`、别的应用的 `other-app:lock`。db 0 放一个同前缀的 `Users:1`。

| 核对什么 | 结果 |
|---|---|
| `redis-cli -n 20` 选库失败 | stderr 一行 `SELECT 20 failed: ERR DB index is out of range`，命令照常在 db 0 上执行 |
| cleanup.sh 用库号 20 跑 | 开头的检查拦下，退出码 1，db 0 的 key 还在 |
| `inventory` | 1201 个 `Users no-ttl`，另外三类各 1 个 |
| `dry` | `Users:*` matched=1202 no-ttl=1201 unlinked=0；14 个模式一共 42 次 `EVAL`，每个模式的 `SCAN` 都要分几步走完 |
| `run confirm` | unlinked=1201；db 3 只剩 `Users:ttl`、`my-service:users:v1:1`、`other-app:lock`，db 0 的 `Users:1` 还在 |
| 有没有阻塞 | `slowlog-log-slower-than` 是 10000，删完 `SLOWLOG LEN` 为 0，没有一次 `EVAL` 超过 10 ms |

## cluster.sh

起三个 `redis-server --cluster-enabled yes`，`redis-cli --cluster create` 按默认把 slot 分成 0–5460、5461–10922、10923–16383。用 `redis-cli -c` 写 3000 个 `Users:<n>`，再加六个应该留下的 key：带 TTL 的旧名字 `Users:ttl` 和 `my-service:Users:1`，新缓存 `my-service:users:v1:1` 和 `my-service:users:v1:2`，别的应用的 `other-app:lock` 和 `other-app:counter`。

| 核对什么 | 结果 |
|---|---|
| cluster 上用 `-n 3` | stderr 一行 `SELECT 3 failed: ERR SELECT is not allowed in cluster mode`，stdout 照样是 `PONG` |
| cleanup.sh 带单机时的库号 3 跑 | 开头的检查拦下 |
| 按 `CLUSTER NODES` 逐个主节点 `inventory` | 三个节点各 993、1001、1006 个 `Users:` 旧 key，合计 3000 |
| `--cluster call … INFO keyspace --cluster-only-masters` | keys / expires 分别是 1006 / 0、1006 / 3、994 / 1 |
| `Users:1` 所在的 slot 174 设成 MIGRATING，在源节点跑 `run confirm` | `Users:*` 那一轮报 `Script attempted to access a non local key in a cluster node script` 后退出；源节点 1006 → 973，已经删掉的不回滚；`Users:1` 自己还在源节点上 |
| slot 恢复 STABLE 后逐个主节点重跑 | 三个节点上只剩那六个 key |

写数据之前要等三个节点都报 `cluster_state:ok`。只等第一个节点的话，另外两个还没就绪，写过去的命令会收到 `CLUSTERDOWN The cluster is down`，`redis-cli -c` 不会因此退出，只是那些 key 没写进去。脚本写完会核对一次总数，不是 3006 就停下。
