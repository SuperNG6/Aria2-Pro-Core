#!/usr/bin/env bash
# Runtime test for a freshly built aria2c, executed against a running
# docker-aria2 container that has the new binary bind-mounted at
# /usr/local/bin/aria2c. Verifies the binary boots under s6-overlay,
# answers RPC, runs a real download, and accepts state transitions.
#
# Usage: runtime-test.sh <host> <port> <secret> <expected-version> [container]

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6800}"
SECRET="${3:-smoketoken}"
EXPECTED_VER="${4:-}"
CONTAINER="${5:-}"
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

# ─── removeFiles RPC 扩展（patch 0006）──────────────────────────────

# 在容器内检查文件是否存在；返回 0 = 存在，1 = 不存在
file_exists_in_container() {
    local path="$1"
    docker exec "$CONTAINER" test -e "$path"
}

# 轮询等待容器内文件被删除；超时返回 1
wait_file_gone() {
    local path="$1" timeout="${2:-15}" elapsed=0
    while ((elapsed < timeout)); do
        if ! file_exists_in_container "$path"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

t_remove_files_completed_result() {
    hdr "7. removeDownloadResult removeFiles=true（已完成任务）"
    if [[ -z "$CONTAINER" ]]; then echo "  ⚠ 跳过：未提供容器名"; return; fi
    local fname="rmfiles-completed-$$-$RANDOM.txt"
    local url='https://raw.githubusercontent.com/aria2/aria2/master/README.rst'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"],{\"out\":\"$fname\"}]" | jq -r '.result // ""')
    [[ -z "$gid" ]] && { ng "addUri 返空"; return; }
    local s
    s=$(wait_final "$gid" 60)
    [[ "$s" != "complete" ]] && { ng "下载未完成: $s"; return; }
    file_exists_in_container "/downloads/$fname" \
        || { ng "下载完成后文件本应存在"; return; }
    ok "下载完成且文件存在"
    rpc aria2.removeDownloadResult "[\"$gid\",true]" | jq -e '.result=="OK"' >/dev/null \
        || { ng "removeDownloadResult 调用失败"; return; }
    if wait_file_gone "/downloads/$fname" 10; then
        ok "removeFiles=true → 文件已删除"
    else
        ng "removeFiles=true 后文件仍存在"
        docker exec "$CONTAINER" ls -la "/downloads/$fname" 2>&1 | head -3 || true
    fi
}

t_remove_files_backward_compat() {
    hdr "8. removeDownloadResult 不带标志（向后兼容回归）"
    if [[ -z "$CONTAINER" ]]; then echo "  ⚠ 跳过：未提供容器名"; return; fi
    local fname="rmfiles-compat-$$-$RANDOM.txt"
    local url='https://raw.githubusercontent.com/aria2/aria2/master/README.rst'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"],{\"out\":\"$fname\"}]" | jq -r '.result // ""')
    [[ -z "$gid" ]] && { ng "addUri 返空"; return; }
    local s
    s=$(wait_final "$gid" 60)
    [[ "$s" != "complete" ]] && { ng "下载未完成: $s"; return; }
    rpc aria2.removeDownloadResult "[\"$gid\"]" | jq -e '.result=="OK"' >/dev/null \
        || { ng "removeDownloadResult 调用失败"; return; }
    sleep 1
    if file_exists_in_container "/downloads/$fname"; then
        ok "未传 removeFiles → 文件保留（与上游一致）"
    else
        ng "未传 removeFiles 时文件意外被删（破坏向后兼容）"
    fi
    docker exec "$CONTAINER" rm -f "/downloads/$fname" || true
}

t_remove_files_paused() {
    hdr "9. remove removeFiles=true（暂停的任务）"
    if [[ -z "$CONTAINER" ]]; then echo "  ⚠ 跳过：未提供容器名"; return; fi
    local fname="rmfiles-paused-$$-$RANDOM.bin"
    # 2MB + 限速 50K → 文件被 falloc 立即创建，pause 时 .aria2 控制文件也存在
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"50K"}]' >/dev/null
    local url='https://speed.cloudflare.com/__down?bytes=2097152'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"],{\"out\":\"$fname\"}]" | jq -r '.result // ""')
    [[ -z "$gid" ]] && {
        ng "addUri 返空"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    }
    sleep 3
    rpc aria2.pause "[\"$gid\"]" >/dev/null
    local s
    s=$(wait_status "$gid" paused 10) || true
    [[ "$s" != "paused" ]] && {
        ng "pause 失败: $s"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    }
    file_exists_in_container "/downloads/$fname" || {
        ng "暂停后数据文件本应存在"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    }
    ok "暂停状态确认，数据文件存在"
    rpc aria2.remove "[\"$gid\",true]" | jq -e '.result' >/dev/null \
        || { ng "remove 调用失败"; }
    # paused → reserved 路径是同步删除，应立即生效
    if wait_file_gone "/downloads/$fname" 5; then
        ok "removeFiles=true → 数据文件已删除"
    else
        ng "数据文件仍存在"
        docker exec "$CONTAINER" ls -la "/downloads/$fname"* 2>&1 | head -3 || true
    fi
    if file_exists_in_container "/downloads/$fname.aria2"; then
        ng "控制文件 .aria2 未被删除"
    else
        ok "控制文件 .aria2 一并删除"
    fi
    rpc aria2.removeDownloadResult "[\"$gid\"]" >/dev/null 2>&1 || true
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
}

t_remove_files_active() {
    hdr "10. remove removeFiles=true（活动中的任务）"
    if [[ -z "$CONTAINER" ]]; then echo "  ⚠ 跳过：未提供容器名"; return; fi
    local fname="rmfiles-active-$$-$RANDOM.bin"
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"50K"}]' >/dev/null
    local url='https://speed.cloudflare.com/__down?bytes=2097152'
    local gid
    gid=$(rpc aria2.addUri "[[\"$url\"],{\"out\":\"$fname\"}]" | jq -r '.result // ""')
    [[ -z "$gid" ]] && {
        ng "addUri 返空"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    }
    # 让 aria2 进入 active 并分配文件
    local s
    s=$(wait_status "$gid" active 10) || true
    if [[ "$s" != "active" ]]; then
        ng "未进入 active: $s"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    fi
    sleep 1
    file_exists_in_container "/downloads/$fname" || {
        ng "active 后数据文件本应存在"
        rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
        return
    }
    ok "active 状态确认，数据文件存在"
    rpc aria2.remove "[\"$gid\",true]" | jq -e '.result' >/dev/null \
        || ng "remove 调用失败"
    # active → 经 ProcessStoppedRequestGroup 异步删除，给充足时间
    if wait_file_gone "/downloads/$fname" 15; then
        ok "removeFiles=true → 数据文件已删除（异步）"
    else
        ng "数据文件仍存在"
        docker exec "$CONTAINER" ls -la "/downloads/$fname"* 2>&1 | head -3 || true
    fi
    # 验证 fix #3：history 里不应该出现这个 GID（addDownloadResult 被跳过）
    # 注意：rpc() 用 curl -fsS，HTTP 400 会让管道整体 exit 22；配合 pipefail
    # 后 if 判定会"非 0"。先把 RPC 结果落地再判，避免假阳性。
    local status_resp
    status_resp=$(rpc aria2.tellStatus "[\"$gid\"]" 2>/dev/null || true)
    if echo "$status_resp" | jq -e '.result' >/dev/null 2>&1; then
        ng "history 仍有该 GID 条目（fix #3 未生效）"
    else
        ok "tellStatus 不返回 result → history 未保留（fix #3：跳过 addDownloadResult）"
    fi
    rpc aria2.changeGlobalOption '[{"max-overall-download-limit":"0"}]' >/dev/null
}

t_option_wiring() {
    hdr "11. --rpc-remove-files-default 选项已编入二进制"
    if [[ -z "$CONTAINER" ]]; then echo "  ⚠ 跳过：未提供容器名"; return; fi
    # 不用 grep -q：管道前段还在写时 grep 早退会触发 SIGPIPE，
    # 配合 pipefail 让整管道返回 141，被 if 误判为失败。
    local help_text
    help_text=$(docker exec "$CONTAINER" aria2c --help=rpc 2>&1 || true)
    if echo "$help_text" | grep -q -- "--rpc-remove-files-default"; then
        ok "aria2c --help=rpc 列出 --rpc-remove-files-default"
    else
        ng "选项未在 help 中出现（OptionHandlerFactory 未注册或 prefs 未导出）"
    fi
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
t_remove_files_completed_result
t_remove_files_backward_compat
t_remove_files_paused
t_remove_files_active
t_option_wiring

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
