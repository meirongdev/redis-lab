#!/bin/sh
# 清理 Redis 里没有 TTL 的旧缓存 key。只输出前缀和计数，不输出 key 名。
# 密码放在 REDISCLI_AUTH 里，节点和库由 REDIS_HOST、REDIS_PORT（默认 6379）、REDIS_DB 指定，
# 开了 TLS 的设 REDIS_TLS=1。cluster 模式下 REDIS_DB 只能是 0，对每个主节点各跑一次：
#   docker run --rm -i -e REDISCLI_AUTH -e REDIS_HOST -e REDIS_DB redis:7.4-alpine sh -s inventory   < cleanup.sh
#   docker run --rm -i -e REDISCLI_AUTH -e REDIS_HOST -e REDIS_DB redis:7.4-alpine sh -s dry         < cleanup.sh
#   docker run --rm -i -e REDISCLI_AUTH -e REDIS_HOST -e REDIS_DB redis:7.4-alpine sh -s run confirm < cleanup.sh
set -eu
MODE=${1:-inventory}
: "${REDIS_HOST:?}" "${REDIS_DB:?}" "${REDISCLI_AUTH:?}"
COUNT=500
PAUSE=0.05
OLD_NAMES="ApiKeys Credentials Users Tokens Currencies Products CurrencyMappings"
SVC=my-service

r() { redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" ${REDIS_TLS:+--tls} -n "$REDIS_DB" --no-auth-warning "$@"; }
numeric() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

# redis-cli 选库失败（cluster 模式只有 db 0，或者库号超出范围）时只在 stderr 打一行，
# 然后在 db 0 上继续执行。出现任何 stderr 输出都先停下。
sel=$(r PING 2>&1 >/dev/null || true)
[ -z "$sel" ] || { echo "连接或选库失败，未做任何操作：$sel"; exit 1; }

INVENTORY_LUA='
local res = redis.call("SCAN", ARGV[1], "COUNT", ARGV[2])
local out = {res[1]}
for _, k in ipairs(res[2]) do
  local p = "(no-colon)"
  local a, b = string.match(k, "^([^:]*):([^:]*)")
  if a then
    p = a
    if a == ARGV[3] then p = a .. ":" .. b end
  end
  out[#out + 1] = p .. (redis.call("TTL", k) == -1 and " no-ttl" or " ttl")
end
return out'

CLEAN_LUA='
local res = redis.call("SCAN", ARGV[1], "MATCH", ARGV[2], "COUNT", ARGV[3])
local seen, nottl, removed = 0, 0, 0
for _, k in ipairs(res[2]) do
  seen = seen + 1
  if redis.call("TTL", k) == -1 then
    nottl = nottl + 1
    if ARGV[4] == "run" then removed = removed + redis.call("UNLINK", k) end
  end
end
return {res[1], seen, nottl, removed}'

inventory() {
  : > /tmp/inv.txt
  cursor=0
  while :; do
    out=$(r EVAL "$INVENTORY_LUA" 0 "$cursor" "$COUNT" "$SVC")
    cursor=$(printf '%s\n' "$out" | head -1)
    numeric "$cursor" || { echo "EVAL failed: $(printf '%s' "$out" | head -1 | cut -c1-160)"; exit 1; }
    printf '%s\n' "$out" | tail -n +2 >> /tmp/inv.txt
    [ "$cursor" = 0 ] && break
    sleep "$PAUSE"
  done
  echo "prefix / ttl / count:"
  sort /tmp/inv.txt | uniq -c | sort -rn
}

clean() {
  for n in $OLD_NAMES; do
    for pat in "$n:*" "$SVC:$n:*"; do
      cursor=0 seen=0 nottl=0 removed=0
      while :; do
        out=$(r EVAL "$CLEAN_LUA" 0 "$cursor" "$pat" "$COUNT" "$1")
        set -- "$1" $out
        numeric "${2:-}" || { echo "EVAL failed on $pat: $(printf '%s' "$out" | head -1 | cut -c1-160)"; exit 1; }
        cursor=$2 seen=$((seen + $3)) nottl=$((nottl + $4)) removed=$((removed + $5))
        [ "$cursor" = 0 ] && break
        sleep "$PAUSE"
      done
      printf '%-40s matched=%-6s no-ttl=%-6s unlinked=%s\n' "$pat" "$seen" "$nottl" "$removed"
    done
  done
}

keyspace() { r INFO keyspace | tr -d '\r' | grep "^db$REDIS_DB:" || echo "db$REDIS_DB: (empty)"; }

echo "redis: $(r INFO server | tr -d '\r' | grep '^redis_version:')  db=$REDIS_DB  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$MODE" in
  inventory)
    echo "before: $(keyspace)"
    echo "clients on db$REDIS_DB: $(r CLIENT LIST | grep -c " db=$REDIS_DB ")"
    inventory
    ;;
  dry) clean dry ;;
  run)
    [ "${2:-}" = confirm ] || { echo "run 需要第二个参数 confirm"; exit 1; }
    echo "before: $(keyspace)"
    clean run
    echo "after:  $(keyspace)"
    inventory
    ;;
  *) echo "mode: inventory | dry | run confirm"; exit 1 ;;
esac
