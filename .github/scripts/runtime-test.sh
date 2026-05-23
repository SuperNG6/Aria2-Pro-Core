#!/usr/bin/env bash
# Runtime test for a freshly built aria2c, executed against a running
# docker-aria2 container that has the new binary bind-mounted at
# /usr/local/bin/aria2c. Verifies the binary boots under s6-overlay,
# answers RPC, runs a real download, and accepts state transitions.
#
# Usage: runtime-test.sh <host> <port> <secret> <expected-version>

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6800}"
SECRET="${3:-smoketoken}"
EXPECTED_VER="${4:-}"
RPC_URL="http://${HOST}:${PORT}/jsonrpc"
TOKEN="token:${SECRET}"

PASS=0
FAIL=0
declare -a FAILED

hdr() { echo; echo "──── $* ────"; }
ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
ng()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); FAILED+=("$*"); }

rpc() {
    local method="$1" params="${2:-[]}"
    printf '%s' "$params" \
        | jq -nc --arg t "$TOKEN" --arg m "$method" \
            'input as $p | {jsonrpc:"2.0",id:"t",method:$m,params:([$t] + $p)}' \
        | curl -fsS --max-time 30 "$RPC_URL" \
            -H 'Content-Type: application/json' \
            --data-binary @-
}

wait_status() {
    local gid="$1" expected="$2" timeout="${3:-30}" elapsed=0 s
    while ((elapsed < timeout)); do
        s=$(rpc aria2.tellStatus "[\"$gid\"]" 2>/dev/null | jq -r '.result.status // ""')
        [[ "$s" == "$expected" ]] && { echo "$s"; return 0; }
        [[ "$s" == "error" ]] && { echo "$s"; return 1; }
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "$s"
    return 1
}

wait_final() {
    local gid="$1" timeout="${2:-60}" elapsed=0 s
    while ((elapsed < timeout)); do
        s=$(rpc aria2.tellStatus "[\"$gid\"]" 2>/dev/null | jq -r '.result.status // ""')
        case "$s" in complete|error|removed) echo "$s"; return 0 ;; esac
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "$s"
    return 1
}

# ─────────────────── tests ───────────────────

t_version() {
    hdr "1. aria2.getVersion 与构建版本一致"
    local v
    v=$(rpc aria2.getVersion '[]' | jq -r '.result.version // ""')
    if [[ -z "$v" ]]; then
        ng "version 字段为空"
        return
    fi
    ok "RPC version=$v"
    if [[ -n "$EXPECTED_VER" && "$v" != "$EXPECTED_VER" ]]; then
        ng "RPC 版本 ($v) ≠ 构建版本 ($EXPECTED_VER)"
    elif [[ -n "$EXPECTED_VER" ]]; then
        ok "与构建版本一致: $EXPECTED_VER"
    fi
}

t_global_stat() {
    hdr "2. aria2.getGlobalStat"
    local r
    r=$(rpc aria2.getGlobalStat '[]')
    if echo "$r" | jq -e '.result.numActive' >/dev/null 2>&1; then
        ok "numActive=$(echo "$r" | jq -r '.result.numActive')"
    else
        ng "响应格式异常: $r"
    fi
}

t_change_global_option() {
    hdr "3. changeGlobalOption / getGlobalOption"
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"512K"}]' >/dev/null
    local v
    v=$(rpc aria2.getGlobalOption '[]' | jq -r '.result["max-overall-download-limit"] // ""')
    [[ "$v" == "524288" ]] && ok "max-overall-download-limit=524288" \
        || ng "期望=524288 实际=$v"
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
}

t_http_download() {
    hdr "4. HTTP addUri → 下载到完成"
    local url='https://raw.githubusercontent.com/aria2/aria2/master/README.rst'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"]]" | jq -r '.result // ""')
    [[ -z "$gid" ]] && { ng "addUri 返回空 GID"; return; }
    ok "addUri → GID=$gid"
    local s
    s=$(wait_final "$gid" 60)
    [[ "$s" == "complete" ]] && ok "下载完成" || ng "未完成: status=$s"
    rpc aria2.removeDownloadResult "[\"$gid\"]" >/dev/null 2>&1 || true
}

t_pause_unpause() {
    hdr "5. pause / unpause"
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"50K"}]' >/dev/null
    local url='https://speed.cloudflare.com/__down?bytes=2097152'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"]]" | jq -r '.result // ""')
    if [[ -z "$gid" ]]; then
        ng "addUri (pause-test) 返空"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    fi
    ok "addUri (2MB@50K) → GID=$gid"
    sleep 3
    rpc aria2.pause "[\"$gid\"]" >/dev/null
    local s
    s=$(wait_status "$gid" paused 10) || true
    [[ "$s" == "paused" ]] && ok "pause → paused" || ng "pause 期望=paused 实际=$s"
    rpc aria2.unpause "[\"$gid\"]" >/dev/null
    sleep 1
    s=$(rpc aria2.tellStatus "[\"$gid\"]" | jq -r '.result.status // ""')
    [[ "$s" == "active" || "$s" == "waiting" ]] && ok "unpause → $s" \
        || ng "unpause 期望=active/waiting 实际=$s"
    rpc aria2.remove "[\"$gid\"]" >/dev/null 2>&1 || true
    rpc aria2.removeDownloadResult "[\"$gid\"]" >/dev/null 2>&1 || true
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
}

t_query_lists() {
    hdr "6. tellActive / tellWaiting / tellStopped"
    rpc aria2.tellActive '[]' | jq -e '.result|type=="array"' >/dev/null \
        && ok "tellActive 数组" || ng "tellActive 非数组"
    rpc aria2.tellWaiting '[0,100]' | jq -e '.result|type=="array"' >/dev/null \
        && ok "tellWaiting 数组" || ng "tellWaiting 非数组"
    rpc aria2.tellStopped '[0,100]' | jq -e '.result|type=="array"' >/dev/null \
        && ok "tellStopped 数组" || ng "tellStopped 非数组"
}

# ─────────────────── main ───────────────────

echo "RPC: $RPC_URL  expected-version: ${EXPECTED_VER:-<none>}"
if ! rpc aria2.getVersion '[]' | jq -e '.result.version' >/dev/null 2>&1; then
    echo "✗ 无法连接 RPC: $RPC_URL"
    exit 1
fi

t_version
t_global_stat
t_change_global_option
t_http_download
t_pause_unpause
t_query_lists

echo
echo "═════════════════════════════════"
echo "  PASS=$PASS  FAIL=$FAIL"
if ((FAIL > 0)); then
    echo "  失败用例:"
    printf '    - %s\n' "${FAILED[@]}"
    exit $((FAIL > 255 ? 255 : FAIL))
fi
echo "  ✓ 全部通过"
exit 0
