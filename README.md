# redis-lab

给博客上的 Redis 文章做的可复现实验。每个案例一个目录，放在 `cases/` 下；脚本用 Docker 起自己需要的 Redis，跑完删掉，可以反复跑。

| 案例 | 对应的文章 | 内容 |
|---|---|---|
| [legacy-cache-key-cleanup](cases/legacy-cache-key-cleanup/) | [清理共享 Redis 里的旧缓存 key](https://meirong.dev/posts/redis-legacy-cache-key-cleanup/) | 用 Lua 分批 `SCAN` + `UNLINK` 删没有 TTL 的旧 key，单机 7.4.2 和三主节点 7.4.12 cluster 各跑一遍 |

## 约定

- 只需要 Docker。镜像在 [lib.sh](lib.sh) 里按 tag + digest 钉死。
- 脚本自带断言，`[符合]` / `[不符]` 打在输出里，有 `[不符]` 时退出码非 0。`[符合]` 的意思是观测和脚本里写的期望一致。
- 输出同时写进案例目录下的 `results/`。log 第一行是出处：跑的时间、服务端版本、镜像、lab 的 git rev（带「+改动」表示跑的时候有没提交的修改）、宿主机和 Docker 分到的 CPU / 内存。
- 容器和网络名以 `rlab-` 开头，脚本开头和退出时都会删掉同名的容器和网络。
- 脚本用 bash，macOS 自带的 bash 3.2 也能跑。
