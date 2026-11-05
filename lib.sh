# 各案例共用：钉死的镜像、redis-cli 包装、断言、log 第一行的出处。
# 案例脚本在自己的目录里 `. ../../lib.sh`。

# tag 只是给人看的，docker 按 digest 拉。
IMG_742=redis:7.4.2-alpine@sha256:02419de7eddf55aa5bcf49efb74e88fa8d931b4d77c07eff8a6b2144472b6952
IMG_7412=redis:7.4.12-alpine@sha256:8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f

export REDISCLI_AUTH=lab-pass
FAIL=0

# cli <容器> <redis-cli 参数…>：在那个容器里跑 redis-cli
cli() { local c=$1; shift; docker exec -i -e REDISCLI_AUTH "$c" redis-cli --no-auth-warning "$@"; }

wait_ping() {
  local _
  for _ in $(seq 50); do [ "$(cli "$1" PING 2>/dev/null | tr -d '\r')" = PONG ] && return; sleep 0.2; done
  echo "${1} 没起来"; exit 1
}

section() { printf '\n== %s\n' "$1"; }

# check <说明> <期望> <实际>
check() {
  if [ "$2" = "$3" ]; then
    echo "[符合] ${1}：${3}"
  else
    printf '[不符] %s\n  期望：%s\n  实际：%s\n' "$1" "$2" "$3"
    FAIL=1
  fi
}

# provenance <服务端容器> <服务端镜像>
provenance() {
  local ver rev dirty='' host
  ver=$(cli "$1" INFO server | tr -d '\r' | sed -n 's/^redis_version://p')
  rev=$(git rev-parse --short HEAD 2>/dev/null || echo 无提交)
  [ -z "$(git status --porcelain --untracked-files=all 2>/dev/null | grep -v '/results/')" ] || dirty=+改动
  if [ "$(uname)" = Darwin ]; then
    host="$(sysctl -n machdep.cpu.brand_string)（$(sysctl -n hw.ncpu) 核 / $(( $(sysctl -n hw.memsize) / 1073741824 )) GiB）"
  else
    host="$(uname -m)（$(nproc) 核）"
  fi
  host="${host}，Docker $(docker info --format '{{.NCPU}} CPU / {{.MemTotal}}' | awk '{printf "%s %s / %.1f GiB", $1, $2, $4 / 1073741824}')"
  echo "# 跑于 $(date '+%F %T %z') | 服务端 ${ver} | 镜像 ${2} | lab ${rev}${dirty} | 机器 ${host}"
}
