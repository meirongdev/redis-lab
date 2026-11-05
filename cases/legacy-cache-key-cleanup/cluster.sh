#!/usr/bin/env bash
# 三主节点 Redis 7.4.12 cluster：写进 3000 个 Users: 旧 key 和六个干扰 key，
# 看库号、逐个主节点执行、slot 处于 MIGRATING 时 cleanup.sh 各是什么表现。
set -euo pipefail
cd "$(dirname "$0")"
. ../../lib.sh

NET=rlab-legacy-cluster
NODES="rlab-legacy-c1 rlab-legacy-c2 rlab-legacy-c3"
C1=rlab-legacy-c1

# job <host> <模式…>：直连一个节点跑 cleanup.sh，库号默认 0，DB=… 可以改
job() { local h=$1; shift; docker run --rm -i --network "$NET" -e REDISCLI_AUTH -e REDIS_HOST="$h" -e REDIS_DB="${DB:-0}" "$IMG_7412" sh -s "$@" < cleanup.sh; }
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
# 文章里取主节点的那一行 awk：输出「ip port」
masters() { cli "$C1" CLUSTER NODES | tr -d '\r' | awk '$3 ~ /master/ && $3 !~ /fail/ {split($2, a, "@"); split(a[1], b, ":"); print b[1], b[2]}'; }
container_of() { local n; for n in $NODES; do [ "$(ip "$n")" = "$1" ] && echo "$n"; done; }
all_keys() { local n; for n in $NODES; do cli "$n" --scan | tr -d '\r'; done | LC_ALL=C sort | paste -sd' ' -; }

main() {
  docker network create "$NET" >/dev/null
  for n in $NODES; do
    docker run -d --name "$n" --network "$NET" "$IMG_7412" \
      redis-server --cluster-enabled yes --requirepass "$REDISCLI_AUTH" --save '' --appendonly no >/dev/null
  done
  for n in $NODES; do wait_ping "$n"; done
  # shellcheck disable=SC2046
  cli "$C1" --cluster create $(for n in $NODES; do echo "$(ip "$n"):6379"; done) --cluster-replicas 0 --cluster-yes >/dev/null
  # 三个节点都要等到 ok：只等 c1 的话，写到别的节点会收到 CLUSTERDOWN
  for n in $NODES; do
    for _ in $(seq 100); do cli "$n" CLUSTER INFO | grep -q 'cluster_state:ok' && break; sleep 0.2; done
  done
  provenance "$C1" "$IMG_7412"

  # 用 cluster 客户端（redis-cli -c）写，跟着 MOVED 落到各自的节点
  seq 1 3000 | sed 's/.*/SET Users:& v/' | cli "$C1" -c >/dev/null
  cli "$C1" -c SET Users:ttl v EX 3600 >/dev/null              # 旧名字但有 TTL
  cli "$C1" -c SET my-service:Users:1 v EX 3600 >/dev/null     # 过渡版本的旧名字，有 TTL
  cli "$C1" -c SET my-service:users:v1:1 v EX 3600 >/dev/null  # 新缓存
  cli "$C1" -c SET my-service:users:v1:2 v EX 3600 >/dev/null
  cli "$C1" -c SET other-app:lock v >/dev/null                 # 别的应用
  cli "$C1" -c SET other-app:counter v >/dev/null
  keep="Users:ttl my-service:Users:1 my-service:users:v1:1 my-service:users:v1:2 other-app:counter other-app:lock"
  total=0; for n in $NODES; do total=$((total + $(cli "$n" DBSIZE | tr -d '\r'))); done
  [ "$total" = 3006 ] || { echo "只写进去 ${total} 个 key，应该是 3006"; return 1; }

  section "cluster 里 -n 3：打一行错误，命令照常执行"
  err=$(cli "$C1" -n 3 PING 2>&1 >/dev/null | tr -d '\r')
  res=$(cli "$C1" -n 3 PING 2>/dev/null | tr -d '\r')
  echo "redis-cli -n 3 PING → stderr: ${err} / stdout: ${res}"
  check "stderr" "SELECT 3 failed: ERR SELECT is not allowed in cluster mode" "$err"
  check "stdout" PONG "$res"

  section "cleanup.sh 带单机时的库号 3 跑 cluster 节点：开头的检查拦下"
  rc=0; out=$(DB=3 job "$(ip "$C1")" run confirm) || rc=$?
  echo "$out"
  check "什么都没做就退出" "1 连接或选库失败，未做任何操作：SELECT 3 failed: ERR SELECT is not allowed in cluster mode" "$rc $out"

  section "逐个主节点 inventory（SCAN 只遍历本节点）"
  counts=""
  while read -r host port; do
    echo "--- ${host}:${port}"
    out=$(job "$host" inventory); echo "$out"
    counts="$counts $(printf '%s\n' "$out" | awk '$2 == "Users" && $3 == "no-ttl" {print $1}')"
  done < <(masters)
  check "各节点的 Users: 旧 key" "993 1001 1006" "$(echo $counts | tr ' ' '\n' | sort -n | paste -sd' ' -)"
  sum=0; for c in $counts; do sum=$((sum + c)); done
  check "加起来" 3000 "$sum"

  section "--cluster call：每个主节点的 INFO keyspace"
  out=$(cli "$C1" --cluster call "$(ip "$C1"):6379" INFO keyspace --cluster-only-masters | tr -d '\r' | grep -E 'db0|^[0-9]')
  echo "$out"
  check "keys / expires" "db0:keys=1006,expires=0|db0:keys=1006,expires=3|db0:keys=994,expires=1" \
    "$(printf '%s\n' "$out" | grep -o 'db0:keys=[0-9]*,expires=[0-9]*' | LC_ALL=C sort -t= -k2,2nr -k3,3n | paste -sd'|' -)"

  section "Users:1 所在的 slot 设成 MIGRATING，在源节点上跑 run"
  slot=$(cli "$C1" CLUSTER KEYSLOT Users:1 | tr -d '\r')
  src="" dst=""
  for n in $NODES; do
    if [ "$(cli "$n" CLUSTER COUNTKEYSINSLOT "$slot" | tr -d '\r')" -gt 0 ]; then src=$n; elif [ -z "$dst" ]; then dst=$n; fi
  done
  echo "slot ${slot}：${src} → ${dst}"
  cli "$dst" CLUSTER SETSLOT "$slot" IMPORTING "$(cli "$src" CLUSTER MYID | tr -d '\r')" >/dev/null
  cli "$src" CLUSTER SETSLOT "$slot" MIGRATING "$(cli "$dst" CLUSTER MYID | tr -d '\r')" >/dev/null
  before=$(cli "$src" DBSIZE | tr -d '\r')
  rc=0; out=$(job "$(ip "$src")" run confirm) || rc=$?
  echo "$out"
  after=$(cli "$src" DBSIZE | tr -d '\r')
  echo "源节点 DBSIZE：${before} → ${after}"
  check "Users:* 那一轮 EVAL 报错退出" "1 EVAL failed on Users:*: ERR Script attempted to access a non local key in a cluster node script" \
    "$rc $(printf '%s\n' "$out" | tail -1 | cut -d: -f1-3)"
  check "报错前已经 UNLINK 的不回滚（源节点上只有 Users: 旧 key）" "1006 → 973" "${before} → ${after}"
  check "触发报错的 Users:1 还在源节点上" 1 "$(cli "$src" EXISTS Users:1 | tr -d '\r')"

  section "slot 恢复 STABLE 后逐个主节点重跑"
  cli "$src" CLUSTER SETSLOT "$slot" STABLE >/dev/null
  cli "$dst" CLUSTER SETSLOT "$slot" STABLE >/dev/null
  while read -r host port; do
    echo "--- ${host}:${port} ($(container_of "$host"))"
    job "$host" run confirm | grep -E '^(before|after)|^Users:\*'
  done < <(masters)
  check "三个节点上剩下的 key" "$keep" "$(all_keys)"

  return "$FAIL"
}

down() { docker rm -f $NODES >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
down; trap down EXIT
mkdir -p results
main 2>&1 | tee results/cluster.log
