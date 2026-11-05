#!/usr/bin/env bash
# 单机 Redis 7.4.2：db 3 里放 1200 个 Users: 旧 key 和四个干扰 key，db 0 放一个同前缀的 key，
# 依次跑 cleanup.sh 的 inventory、dry、run confirm，核对删掉的和留下的。
set -euo pipefail
cd "$(dirname "$0")"
. ../../lib.sh

NET=rlab-legacy-standalone
SRV=rlab-legacy-standalone

# job <模式…>：和文章里的用法一样，在 redis:7.4 的容器里跑 cleanup.sh。库号默认 3，DB=… 可以改
job() { docker run --rm -i --network "$NET" -e REDISCLI_AUTH -e REDIS_HOST="$SRV" -e REDIS_DB="${DB:-3}" "$IMG_7412" sh -s "$@" < cleanup.sh; }
line() { printf '%s\n' "$1" | awk -v p="$2" '$1 == p' | tr -s ' '; }
# inventory 输出里「prefix / ttl / count」下面那张表，压成一行，行序固定
table() { printf '%s\n' "$1" | sed -n '/^prefix/,$p' | sed 1d | tr -s ' ' | sed 's/^ //' | LC_ALL=C sort | paste -sd'|' -; }
evals() { cli "$SRV" INFO commandstats | tr -d '\r' | sed -n 's/^cmdstat_eval:calls=\([0-9]*\),.*/\1/p'; }

main() {
  docker network create "$NET" >/dev/null
  docker run -d --name "$SRV" --network "$NET" "$IMG_742" \
    redis-server --requirepass "$REDISCLI_AUTH" --save '' --appendonly no >/dev/null
  wait_ping "$SRV"
  provenance "$SRV" "$IMG_742"

  seq 1 1200 | sed 's/.*/SET Users:& v/' | cli "$SRV" -n 3 >/dev/null
  cli "$SRV" -n 3 SET 'Users:with space' v >/dev/null           # 旧 key，名字带空格，该删
  cli "$SRV" -n 3 SET Users:ttl v EX 3600 >/dev/null             # 旧名字但有 TTL，留着
  cli "$SRV" -n 3 SET my-service:users:v1:1 v EX 3600 >/dev/null # 新缓存
  cli "$SRV" -n 3 SET other-app:lock v >/dev/null                # 别的应用
  cli "$SRV" -n 0 SET Users:1 v >/dev/null                       # 另一个库里的同前缀 key

  section "库号写错时，redis-cli 打一行错误，然后在 db 0 上执行"
  err=$(cli "$SRV" -n 20 EXISTS Users:1 2>&1 >/dev/null | tr -d '\r')
  res=$(cli "$SRV" -n 20 EXISTS Users:1 2>/dev/null | tr -d '\r')
  echo "redis-cli -n 20 EXISTS Users:1 → stderr: ${err} / stdout: ${res}"
  check "stderr 只有一行错误" "SELECT 20 failed: ERR DB index is out of range" "$err"
  check "命令照常执行，查到的是 db 0 的 Users:1" 1 "$res"

  section "cleanup.sh 用库号 20 跑：开头的检查拦下"
  rc=0; out=$(DB=20 job run confirm) || rc=$?
  echo "$out"
  check "什么都没做就退出" "1 连接或选库失败，未做任何操作：SELECT 20 failed: ERR DB index is out of range" "$rc $out"
  check "db 0 的 Users:1 还在" 1 "$(cli "$SRV" -n 0 EXISTS Users:1 | tr -d '\r')"

  section "inventory"
  out=$(job inventory); echo "$out"
  check "前缀统计" "1 Users ttl|1 my-service:users ttl|1 other-app no-ttl|1201 Users no-ttl" "$(table "$out")"

  section "dry"
  cli "$SRV" CONFIG RESETSTAT >/dev/null
  out=$(job dry); echo "$out"
  check "Users:* 只统计不删" "Users:* matched=1202 no-ttl=1201 unlinked=0" "$(line "$out" 'Users:*')"
  n=$(evals)
  echo "14 个模式一共 ${n} 次 EVAL"
  check "SCAN 要分几步才走完一遍（EVAL 次数多于模式数）" yes "$([ "$n" -gt 14 ] && echo yes || echo "no（${n}）")"

  section "run confirm"
  cli "$SRV" SLOWLOG RESET >/dev/null
  cli "$SRV" CONFIG RESETSTAT >/dev/null
  out=$(job run confirm); echo "$out"
  check "Users:* 删掉没有 TTL 的" "Users:* matched=1202 no-ttl=1201 unlinked=1201" "$(line "$out" 'Users:*')"
  check "db 3 剩下的 key" "Users:ttl my-service:users:v1:1 other-app:lock" \
    "$(cli "$SRV" -n 3 --scan | tr -d '\r' | LC_ALL=C sort | paste -sd' ' -)"
  check "db 0 的 Users:1 还在" 1 "$(cli "$SRV" -n 0 EXISTS Users:1 | tr -d '\r')"
  echo "slowlog-log-slower-than: $(cli "$SRV" CONFIG GET slowlog-log-slower-than | tr -d '\r' | tail -1)"
  echo "$(cli "$SRV" INFO commandstats | tr -d '\r' | grep '^cmdstat_eval:')"
  check "没有一次 EVAL 超过 10 ms（SLOWLOG LEN）" 0 "$(cli "$SRV" SLOWLOG LEN | tr -d '\r')"

  return "$FAIL"
}

down() { docker rm -f "$SRV" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
down; trap down EXIT
mkdir -p results
main 2>&1 | tee results/standalone.log
