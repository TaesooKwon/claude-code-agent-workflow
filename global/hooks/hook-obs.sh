#!/bin/bash
# hook-obs.sh — 훅 공통 관측 래퍼. 원 훅을 그대로 실행해 rc·stdout·stderr 바이트를 보존하고,
# ~/.claude/hook-events/YYYY-MM.jsonl 에 판정 1줄을 남긴다. 계약 = hook-obs 명세 v2(2026-10-07).
# 등록 형태(래퍼가 없거나 문법 오류면 원 훅이 그대로 돈다 — fail-open 방지):
#   W=$HOME/.claude/hooks/hook-obs.sh; bash -n "$W" 2>/dev/null && exec bash "$W" <원 명령> || exec <원 명령>
# bash 3.2 호환(wait -n·EPOCHREALTIME·mapfile 금지). set -e/pipefail 는 쓰지 않는다 — rc 를 직접 다룬다.
# 기록 금지: stderr 내용·명령 원문·tool_input. reason 은 판정 텍스트 선두 [태그] 만(허용 목록).
# session = 입력 .session_id(문자열일 때만, 아니면 null) — 세션별 집계용. 그 밖의 식별자는 기록하지 않는다.

[ "$#" -gt 0 ] || exit 0

umask 077
d=$(mktemp -d "${TMPDIR:-/tmp}/hookobs.XXXXXX" 2>/dev/null) || d=
[ -n "$d" ] && [ -d "$d" ] || exec "$@"
trap 'rm -rf "$d"' EXIT

hook=${!#}; hook=${hook##*/}
pid=; rc=0

# 로깅 — 서브셸 격리: 실패해도 rc·출력에 영향 0. $1 = 강제 action(killed) 또는 빈 값.
log_event() {
  (
    now=$(date '+%s%N|%Y-%m|%Y-%m-%dT%H:%M:%S%z')
    t1=${now%%|*}; rest=${now#*|}; mon=${rest%%|*}; ts=${rest#*|}
    dur=null
    case "$t0$t1" in *[!0-9]*|'') ;; *) [ "${#t0}" -gt 10 ] && [ "${#t1}" -gt 10 ] && dur=$(( (t1 - t0) / 1000000 ));; esac
    ob=0; eb=0
    [ -s "$d/out" ] && ob=$(wc -c <"$d/out")
    [ -s "$d/err" ] && eb=$(wc -c <"$d/err")
    ob=${ob// /}; eb=${eb// /}
    case "$ob" in ''|*[!0-9]*) ob=0;; esac
    case "$eb" in ''|*[!0-9]*) eb=0;; esac
    cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}; cfg=${cfg%/}; seat=${cfg##*/}
    : >>"$d/in"; : >>"$d/out"
    line=$(jq -cn --rawfile inp "$d/in" --rawfile out "$d/out" \
      --arg ts "$ts" --arg hook "$hook" --arg pdir "${CLAUDE_PROJECT_DIR:-}" --arg seat "$seat" \
      --arg force "$1" --argjson rc "$rc" --argjson dur "$dur" --argjson ob "$ob" --argjson eb "$eb" '
      def str: if type == "string" then . else null end;
      def obj: if type == "object" then . else {} end;
      def bn: if type == "string" and . != "" then (sub("/+$"; "") | split("/") | last) else null end;
      def tag: if type == "string" then ((try capture("^\\s*(?<t>\\[[^\\]]{1,40}\\])").t catch null) // null) else null end;
      (try ($inp | fromjson | obj) catch {}) as $i
      | (try ($out | fromjson) catch null) as $o
      | ($o | type == "object") as $isj
      | ($o | obj) as $j
      | ($j.hookSpecificOutput | obj) as $h
      | (if $force != "" then $force
         elif $h.permissionDecision == "deny" or $j.decision == "block" then "block"
         elif $rc == 2 then "block"
         elif $h.permissionDecision == "ask" then "ask"
         elif $rc != 0 then "error"
         elif $ob > 0 or $eb > 0 then "warn"
         else "allow" end) as $act
      | ((if $isj then ($h.permissionDecisionReason // $j.reason // $h.additionalContext // $j.systemMessage) else $out end) | tag) as $r
      | {ts: $ts, hook: $hook, event: ($i.hook_event_name | str), tool: ($i.tool_name | str),
         project: ((if $pdir != "" then $pdir else $i.cwd end) | bn), seat: $seat,
         action: $act, exit_code: $rc, duration_ms: $dur, out_bytes: $ob, err_bytes: $eb, reason: $r,
         session: ($i.session_id | str)}')
    if [ -z "$line" ]; then
      # 입력이 jq 를 통째로 깨뜨리면(예: 비 UTF-8 경계 오류) 쉘 판정으로 폴백 — 파싱 필드는 null.
      # ponytail: 폴백은 JSON 판정(deny/block/ask)을 못 본다 / jq 오류 유형이 관측되면 --rawfile 대신 바이트 정제 후 재시도
      act=$1
      [ -n "$act" ] || { if [ "$rc" = 2 ]; then act=block; elif [ "$rc" != 0 ]; then act=error; elif [ "$ob" != 0 ] || [ "$eb" != 0 ]; then act=warn; else act=allow; fi; }
      line=$(jq -cn --arg ts "$ts" --arg hook "$hook" --arg seat "$seat" --arg act "$act" \
        --argjson rc "$rc" --argjson dur "$dur" --argjson ob "$ob" --argjson eb "$eb" \
        '{ts: $ts, hook: $hook, event: null, tool: null, project: null, seat: $seat, action: $act,
          exit_code: $rc, duration_ms: $dur, out_bytes: $ob, err_bytes: $eb, reason: null, session: null}')
    fi
    [ -n "$line" ] || exit 0
    ld="$HOME/.claude/hook-events"
    [ -d "$ld" ] || mkdir -p "$ld" || exit 0
    # 단일 write 로 append — 동시 훅 여러 개가 같은 파일에 써도 줄이 섞이지 않게(O_APPEND).
    printf '%s\n' "$line" >>"$ld/$mon.jsonl"
  ) >/dev/null 2>&1 || true
}

on_sig() {
  trap '' TERM INT HUP
  if [ -n "$pid" ]; then
    # 손주(훅 안의 sleep 등)가 고아로 남지 않게 직계 자식부터 정리.
    # ponytail: 직계 자식 1단계만 정리(손주의 자식은 남을 수 있다) / 필요 시 setsid·프로세스 그룹 단위 kill
    pkill "-$1" -P "$pid" 2>/dev/null
    kill -s "$1" "$pid" 2>/dev/null
    # 비대화형 셸의 & 자식은 INT 를 무시한다(POSIX) — INT 는 TERM 으로 한 번 더.
    [ "$1" = INT ] && { pkill -TERM -P "$pid" 2>/dev/null; kill -s TERM "$pid" 2>/dev/null; }
  fi
  rc=$2
  log_event killed
  exit "$2"
}
trap 'on_sig TERM 143' TERM
trap 'on_sig INT 130' INT
trap 'on_sig HUP 129' HUP

# ponytail: stdin 저장(cat) 실패 시에도 남은 만큼으로 원 훅을 돌린다 — 디스크 부족이면 가드가 빈 입력을 볼 수 있다 / 관측되면 실패 시 exec "$@" 로 직결
cat >"$d/in"
t0=$(date +%s%N 2>/dev/null)
"$@" <"$d/in" >"$d/out" 2>"$d/err" &
pid=$!
wait "$pid"; rc=$?

# 빈 스트림은 cat 을 건너뛴다(fork 1회 ≈ 2ms — 대부분의 훅은 무출력).
[ -s "$d/out" ] && cat "$d/out"
[ -s "$d/err" ] && cat "$d/err" >&2
log_event ""
exit "$rc"
