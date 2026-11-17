#!/usr/bin/env bash
# Stop 훅: Claude가 턴을 마치면 맥 알림 배너+소리(+ 켜 두면 폰 ntfy 푸시)로 "무슨 작업/어느 단계"를 알린다.
# 폰 푸시는 기본 꺼짐(2026-10-14 사용자 — Paseo 모바일 앱 푸시로 대체). 다시 켜려면 훅 환경에 NOTIFY_NTFY=1.
# 본문 결정: (1) 마지막 메시지에 '🔔 ...' 상태줄이 있으면 그걸, (2) 없으면 마지막 메시지 첫 줄을 자동 요약.
#   폰(ntfy.sh = 공개 서비스, 신뢰 경계 밖)엔 (1) 상태줄만 보낸다 — 없으면 고정 문구. (2) 자동 요약은 맥 로컬 배너에만.
# 토픽은 키체인(서비스 ntfy-topic)에서 읽는다 — 항목이 없으면 폰 푸시만 건너뛴다.
#   등록: security add-generic-password -a "$USER" -s ntfy-topic -w <토픽>
# NOTIFY_DRYRUN=1 이면 발송 대신 LOCAL:/PHONE: 본문(턴 재개로 건너뛰면 SKIP:resumed)을 stdout 에 찍는다(테스트용 — 재개 판정도 동기로 돈다).
# NOTIFY_SETTLE_MAX(초, 기본 25)·NOTIFY_SETTLE_GRACE(초, 기본 2) = 아래 재개 판정의 대기 상한·유예(숫자가 아니면 기본값).
# 실패는 전부 무시(폐쇄루프 등 다른 Stop 훅 방해 금지).
set -u

payload="$(cat 2>/dev/null || true)"

# 같은 stop 사이클의 다른 Stop 훅이 block 을 걸면 턴이 이어진다 — 이 훅은 그 훅들과 같은 사이클에 돌아 호출 시점엔
# 결과를 모른다. 그래서 발송을 미루고(_turn_resumed), 이 호출 뒤 트랜스크립트에 턴 재개 흔적이 붙으면 보내지 않는다.
# 알림은 재개 흔적이 없는 stop 에서 나간다. stop_hook_active 는 판정에 쓰지 않는다(block 뒤의 재-stop 이 실제 턴 끝일 수 있다).
# ponytail: 재개 판정이 트랜스크립트 항목 type(assistant·user·api-request)과 stop_hook_summary 표지에 기댄다 — 형식이 바뀌면 대기 상한 뒤 발송(조기 발송 가능) / 업그레이드 = Stop 사이클 결과를 받는 공식 경로가 생기면 교체
_num_or() { printf '%s' "$1" | grep -Eqx '[0-9]{1,2}(\.[0-9]{1,2})?' && printf '%s' "$1" || printf '%s' "$2"; }
settle_max="$(_num_or "${NOTIFY_SETTLE_MAX:-}" 25)"
settle_grace="$(_num_or "${NOTIFY_SETTLE_GRACE:-}" 2)"
# $1 = 트랜스크립트, $2 = 이 훅 호출 시점의 바이트 크기. 그 뒤에 붙은 항목에 재개 흔적이 있으면 0(= 보내지 않는다).
_new_types() { tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | jq -R -r 'fromjson? | select(type == "object") | "\(.type // ""):\(.subtype // "")"' 2>/dev/null; }
_turn_resumed() {
  local t0 now
  t0=$(date +%s)
  # ① 이 사이클의 stop_hook_summary(다른 Stop 훅이 다 끝났다는 표지)가 붙을 때까지 기다린다(상한 settle_max 초).
  while ! _new_types "$1" "$2" | grep -q ':stop_hook_summary$'; do
    now=$(date +%s)
    [ $(( now - t0 )) -ge "${settle_max%.*}" ] && break
    sleep 0.25
  done
  # ② 유예 뒤 재개 흔적(모델 재호출·응답·새 입력)을 본다.
  sleep "$settle_grace"
  _new_types "$1" "$2" | cut -d: -f1 | grep -Eqx 'assistant|user|api-request'
}

tp="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
proj="$(basename "$cwd" 2>/dev/null)"
[ -z "$proj" ] && proj="Claude Code"

bell=""
body=""
tp_size=""
if [ -n "$tp" ] && [ -f "$tp" ]; then
  tp_size="$(wc -c < "$tp" 2>/dev/null | tr -d ' ')"
  case "$tp_size" in ''|*[!0-9]*) tp_size="" ;; esac
  # 이번 턴 마지막 assistant 텍스트 블록 전체
  last_text="$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' "$tp" 2>/dev/null)"
  # 1순위: '🔔'로 시작하는 상태줄(가장 마지막 것) — 앞의 🔔/공백 제거
  bell="$(printf '%s\n' "$last_text" | grep -E '^[[:space:]]*🔔' | tail -1 | sed -E 's/^[[:space:]]*🔔[[:space:]]*//')"
  body="$bell"
  # 2순위: 없으면 첫 비어있지 않은 줄에서 마크다운 기호 제거(로컬 배너 전용)
  if [ -z "$body" ]; then
    body="$(printf '%s\n' "$last_text" | grep -m1 -E '\S' | sed -E 's/^#+ *//; s/\*\*//g; s/`//g; s/^[-*] +//')"
  fi
fi
[ -z "$body" ] && body="작업 완료. 확인 필요."
[ -z "$bell" ] && bell="작업 완료. 확인 필요."
# 문장 140자 컷 후 [프로젝트명] 접두
body="[${proj}] $(printf '%s' "$body" | cut -c1-140)"
phone="[${proj}] $(printf '%s' "$bell" | cut -c1-140)"

if [ "${NOTIFY_DRYRUN:-}" = "1" ]; then
  if [ -n "$tp_size" ] && _turn_resumed "$tp" "$tp_size"; then echo "SKIP:resumed"; exit 0; fi
  printf 'LOCAL:%s\nPHONE:%s\n' "$body" "$phone"
  exit 0
fi

# 발송(소리 1.65s·ntfy 왕복·배너)은 백그라운드로 떼어 턴 종료를 붙잡지 않는다 — 순차 실행 시 Stop 훅이 턴마다 ~3s(hook-obs 2026-10-07 실측).
# fd 를 전부 닫아야 훅 러너(와 hook-obs 래퍼)가 자식 종료를 기다리지 않는다.
(
  # 0) 턴이 재개됐으면(다른 Stop 훅의 block) 보내지 않는다.
  [ -n "$tp_size" ] && _turn_resumed "$tp" "$tp_size" && exit 0
  # 1) 맥 로컬 알림 배너 + 소리 (osascript 문자열 이스케이프)
  esc_body="$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  /usr/bin/osascript -e "display notification \"${esc_body}\" with title \"Claude Code\"" >/dev/null 2>&1 || true
  /usr/bin/afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 || true

  # 2) 폰 푸시(ntfy) — NOTIFY_NTFY=1 일 때만. 본문 [프로젝트명] <🔔 상태줄>, 이모지는 Tags, --data-binary로 UTF-8 그대로
  topic=""
  [ "${NOTIFY_NTFY:-0}" = "1" ] && topic="$(/usr/bin/security find-generic-password -s ntfy-topic -w 2>/dev/null)"
  [ -n "$topic" ] && /usr/bin/curl -fsS -m 5 \
    -H "Title: Claude Code" \
    -H "Tags: white_check_mark" \
    -H "Priority: default" \
    --data-binary "$phone" \
    "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
) </dev/null >/dev/null 2>&1 &

exit 0
