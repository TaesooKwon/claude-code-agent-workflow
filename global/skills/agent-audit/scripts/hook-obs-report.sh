#!/bin/bash
# hook-obs-report.sh — hook-obs.sh 가 남긴 ~/.claude/hook-events/*.jsonl 집계.
# 사용: hook-obs-report.sh [일수=30]
#   (hook,event) 별 건수·action 분포·평균/최대 ms·seat 분포 / 기간 내 block·warn 0 인 (hook,event) / killed·error 목록
# jq 만 사용. 깨진 줄(부분 쓰기 등)은 건너뛰고 건수를 보고한다.

days=${1:-30}
case "$days" in ''|*[!0-9]*) echo "사용: $0 [일수(양의 정수)]" >&2; exit 2;; esac
LD="${HOOK_EVENTS_DIR:-$HOME/.claude/hook-events}"
command -v jq >/dev/null 2>&1 || { echo "jq 없음" >&2; exit 2; }
ls "$LD"/*.jsonl >/dev/null 2>&1 || { echo "로그 없음: $LD (래퍼 미등록이거나 아직 기록 0건)"; exit 0; }

since=$(( $(date +%s) - days * 86400 ))
echo "=== hook-obs 리포트: 최근 ${days}일 ($LD) ==="
# ① 파일명 = 월(YYYY-MM.jsonl)이라 기간 시작 월보다 이른 월 파일은 아예 읽지 않는다. 그 밖 이름의 .jsonl 은
#    기간을 알 수 없어 읽는다. 그래서 '깨진 줄' 건수는 읽은 파일 안에서만 센다.
# ② 1단계 jq 는 줄 단위 스트리밍으로 ts 를 거르고 집계에 쓰는 필드만 남긴다. 2단계는 그 축소본만 메모리에 올린다.
since_mon=$(date -r "$since" +%Y-%m 2>/dev/null || date -d "@$since" +%Y-%m 2>/dev/null)
files=()
for f in "$LD"/*.jsonl; do
  n=${f##*/}
  if [[ "$n" =~ ^[0-9]{4}-[0-9]{2}\.jsonl$ ]] && [ -n "$since_mon" ] && [[ "${n%.jsonl}" < "$since_mon" ]]; then
    continue
  fi
  files+=("$f")
done
[ "${#files[@]}" -gt 0 ] || files=(/dev/null)   # 인자 없는 cat 이 stdin 을 기다리지 않게

cat "${files[@]}" | jq -Rc --argjson since "$since" '
  # ts = 로컬시각+오프셋(+0900) — strptime 은 UTC 로 읽으므로 오프셋만큼 되돌린다.
  def epoch: try (capture("^(?<t>.{19})(?<s>[+-])(?<h>[0-9]{2})(?<m>[0-9]{2})$")
    | (.t + "Z" | fromdateiso8601) - ((if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60))) catch null;
  (try fromjson catch "BAD")
  | if . == "BAD" then .
    elif type == "object" and ((.ts | epoch) // 0) >= $since
      then {ts, hook, event, action, duration_ms, seat, exit_code, session}
    else empty end
' | jq -nr '
  [inputs] as $all
  | ($all | map(select(. == "BAD")) | length) as $bad
  | ($all | map(select(type == "object"))) as $ev
  | def dist(f): group_by(f) | map("\(.[0] | f // "null")=\(length)") | join(" ");
    "총 \($ev | length)건 (깨진 줄 \($bad)건 제외)",
    "",
    "--- (hook, event) 별: 건수 | action 분포 | 평균/최대 ms | seat ---",
    ($ev | group_by([.hook, .event]) | sort_by(-length)[]
      | (map(.duration_ms | numbers)) as $ms
      | "\(.[0].hook)\t\(.[0].event // "-")\t\(length)\t\(dist(.action))\tavg=\(if ($ms | length) > 0 then ($ms | add / length | round) else "-" end) max=\($ms | max // "-")\t\(dist(.seat))"),
    "",
    "--- block·warn 0 건인 (hook, event) — 발동은 했으나 한 번도 걸지 않음(검토 대상 — 드문 사고를 막는 가드는 0건이 정상, 폐기 근거 아님) ---",
    ($ev | group_by([.hook, .event]) | map(select(all(.[]; .action != "block" and .action != "warn")))
      | if length == 0 then "(없음)" else .[] | "\(.[0].hook)\t\(.[0].event // "-")\t\(length)건" end),
    "",
    "--- killed / error ---",
    ($ev | map(select(.action == "killed" or .action == "error"))
      | if length == 0 then "(없음)" else .[] | "\(.ts)\t\(.hook)\t\(.event // "-")\t\(.action)\trc=\(.exit_code)\t\(.duration_ms // "-")ms" end)
' -n
