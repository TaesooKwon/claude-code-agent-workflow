#!/usr/bin/env bash
# notify-done.sh 드라이런 테스트 — 폰 본문은 🔔 상태줄만, 없으면 고정 문구(응답 원문 유출 금지)
H="${1:-$(dirname "$0")/notify-done.sh}"; D="$(mktemp -d)" || { echo '임시 디렉터리 생성 실패 — 실행하지 않았다'; exit 2; }; trap 'case "$D" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$D" ;; esac' EXIT; pass=0; fail=0
mk(){ printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' "$1" > "$2"; }
mk '"비밀 경로 /Users/x/secret 요약\n\n🔔 대상 완료. 다음."' "$D/t1.jsonl"
mk '"비밀 경로 /Users/x/secret 요약 첫 줄\n둘째"' "$D/t2.jsonl"
run(){ printf '{"transcript_path":"%s","cwd":"/x/proj"}' "$1" | NOTIFY_DRYRUN=1 NOTIFY_SETTLE_MAX=1 NOTIFY_SETTLE_GRACE=0 bash "$H"; }
# 턴 재개 판정 — 훅을 띄운 뒤 트랜스크립트에 $2(JSON 줄들)를 덧붙이고 출력을 받는다. $3 = 훅 입력의 stop_hook_active.
SUM='{"type":"system","subtype":"stop_hook_summary"}'
cyc(){ cp "$D/t1.jsonl" "$D/c.jsonl"
  printf '{"transcript_path":"%s","cwd":"/x/proj","stop_hook_active":%s}' "$D/c.jsonl" "$3" \
    | NOTIFY_DRYRUN=1 NOTIFY_SETTLE_MAX=4 NOTIFY_SETTLE_GRACE=0.5 bash "$H" > "$D/c.out" & local pid=$!
  sleep 0.5; [ -z "$2" ] || printf '%s\n' "$2" >> "$D/c.jsonl"; wait "$pid"; cat "$D/c.out"; }
chk(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3"; fi; }
nchk(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then fail=$((fail+1)); echo "FAIL: $3"; else pass=$((pass+1)); fi; }
o=$(run "$D/t1.jsonl"); chk "$o" "PHONE:[proj] 대상 완료. 다음." "t1 폰=상태줄"; nchk "$(printf '%s' "$o"|grep ^PHONE)" "secret" "t1 폰에 본문 유출"
o=$(run "$D/t2.jsonl"); chk "$o" "PHONE:[proj] 작업 완료. 확인 필요." "t2 폰=고정문구"; nchk "$(printf '%s' "$o"|grep ^PHONE)" "secret" "t2 폰에 본문 유출"; chk "$o" "LOCAL:[proj] 비밀 경로" "t2 로컬=자동요약 유지"
o=$(cyc x "$SUM"$'\n''{"type":"api-request"}' false); chk "$o" "SKIP:resumed" "다른 Stop 훅 block(재개 흔적 api-request) → 미발송"; nchk "$o" "PHONE:" "block 사이클 조기 발송"
o=$(cyc x "$SUM"$'\n''{"type":"assistant","message":{"content":[]}}' false); chk "$o" "SKIP:resumed" "재개 흔적 assistant → 미발송"
o=$(cyc x "$SUM"$'\n''{"type":"last-prompt"}'$'\n''{"type":"cost-state"}' false); chk "$o" "PHONE:[proj] 대상 완료. 다음." "block 없는 사이클(메타 항목만) → 발송"
o=$(cyc x "$SUM" true); chk "$o" "PHONE:[proj] 대상 완료. 다음." "block 뒤 재-stop(stop_hook_active) 이 끝이면 발송"
o=$(cyc x "" false); chk "$o" "PHONE:[proj]" "요약 표지가 안 붙어도 대기 상한 뒤 발송"
o=$(printf '{"stop_hook_active":true}' | NOTIFY_DRYRUN=1 bash "$H"); chk "$o" "PHONE:[Claude Code] 작업 완료. 확인 필요." "트랜스크립트 없음 → 고정 문구 즉시"
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
