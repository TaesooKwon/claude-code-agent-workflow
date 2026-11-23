#!/usr/bin/env bash
# mark-review.sh 계약 테스트 — 양성/음성/우회 + 짝 훅(code-review-marker-reminder.sh) 지문 계약.
# 실행: bash .claude/hooks/mark-review.test.sh
#
# 격리: 임시 git 저장소를 만들고 CLAUDE_PROJECT_DIR 로 그곳을 가리킨다 — 이 레포의 .claude/.last-review 는
#      건드리지 않는다(이 테스트가 실제 마커를 덮으면 진행 중인 커밋 게이트가 오염된다).
# 짝 훅은 PreToolUse 훅이라 **stdin JSON** 으로 먹인다(jq 로 조립 — 셸 인용 사고 방지).
# ⚠️ 커밋 명령 문구는 이 파일 안에만 둔다 — Bash 도구 명령줄에 직접 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
set -u
# 사용자·시스템 git 설정(color.diff·diff.external 등)이 기대 지문 계산을 흔들지 않게 격리한다.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS_DIR/mark-review.sh"
REMINDER="$HOOKS_DIR/code-review-marker-reminder.sh"

run=0
pass=0
ok() { # ok <기대> <실제> <설명>
  run=$((run + 1))
  if [ "$1" = "$2" ]; then
    pass=$((pass + 1))
    echo "  ✅ $3"
  else
    echo "  ❌ $3  (기대=[$1] 실제=[$2])"
  fi
}
contains() { # contains <haystack> <needle> <설명>
  run=$((run + 1))
  case "$1" in
    *"$2"*) pass=$((pass + 1)); echo "  ✅ $3" ;;
    *) pass=$pass; echo "  ❌ $3  (출력에 [$2] 없음: $(printf '%s' "$1" | head -2))" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mark-review-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
export CLAUDE_PROJECT_DIR="$REPO"
MARKER="$REPO/.claude/.last-review"
LOG="$REPO/.claude/.review-marker.log"

git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config user.name "hook test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config core.hooksPath "$TMP/no-such-hooks"
printf 'base\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m "base"

# 커밋 명령 문구(짝 훅에 먹일 stdin JSON 용) — 파일 안에서만 조립한다.
COMMIT_CMD="git commit -m 'x'"

# 리뷰 결과 JSON 픽스처
cat > "$TMP/ok.json" <<'JSON'
{
  "reviewComplete": true,
  "lensStatus": [
    {"lens": "behavior", "status": "ok", "reviewedFiles": ["a.txt"], "findings": 0},
    {"lens": "regression", "status": "ok", "reviewedFiles": ["a.txt"], "findings": 0}
  ],
  "confirmed": [],
  "rejected": [],
  "unverified": [],
  "uncoveredFiles": []
}
JSON
# 새 계약: 관점별 누락(unreviewedFiles)은 정보용 — 다른 관점이 덮으면 통과한다(markup 이 .java 를 안 읽는 혼합 커밋).
cat > "$TMP/ok-lens-gap.json" <<'JSON'
{
  "reviewComplete": true,
  "lensStatus": [
    {"lens": "behavior", "status": "ok", "reviewedFiles": ["A.java", "v.html"], "unreviewedFiles": [], "findings": 0},
    {"lens": "markup", "status": "ok", "reviewedFiles": ["v.html"], "unreviewedFiles": ["A.java"], "findings": 0}
  ],
  "unverified": [],
  "uncoveredFiles": []
}
JSON
# 어느 관점도 안 읽은 스테이징 파일 — reviewComplete 를 true 로 위조해도 거부돼야 한다.
cat > "$TMP/uncovered.json" <<'JSON'
{
  "reviewComplete": true,
  "lensStatus": [{"lens": "markup", "status": "ok", "reviewedFiles": ["v.html"]}],
  "unverified": [],
  "uncoveredFiles": ["A.java"]
}
JSON
# uncoveredFiles 필드 자체가 없음(판정 불가) / 배열이 아님 → 허용 목록 밖이라 거부.
cat > "$TMP/no-uncovered.json" <<'JSON'
{"reviewComplete": true, "lensStatus": [{"lens": "behavior", "status": "ok"}], "unverified": []}
JSON
cat > "$TMP/uncovered-string.json" <<'JSON'
{"reviewComplete": true, "lensStatus": [{"lens": "behavior", "status": "ok"}], "unverified": [], "uncoveredFiles": ""}
JSON
# 옛 엔진의 관점 단위 미완결 상태값 — ok 가 아니므로 여전히 거부(허용 목록).
cat > "$TMP/partial-scan.json" <<'JSON'
{"reviewComplete": false, "lensStatus": [{"lens": "markup", "status": "partial-scan"}], "unverified": [], "uncoveredFiles": []}
JSON
cat > "$TMP/empty-scan.json" <<'JSON'
{
  "reviewComplete": false,
  "lensStatus": [
    {"lens": "behavior", "status": "ok"},
    {"lens": "markup", "status": "empty-scan"}
  ],
  "unverified": []
}
JSON
cat > "$TMP/unknown-lens.json" <<'JSON'
{
  "reviewComplete": false,
  "lensStatus": [{"lens": "behavior", "status": "ok"}, {"lens": "security", "status": "unknown-lens"}],
  "unverified": []
}
JSON
cat > "$TMP/dropped.json" <<'JSON'
{
  "reviewComplete": false,
  "lensStatus": [{"lens": "behavior", "status": "dropped"}],
  "unverified": []
}
JSON
cat > "$TMP/failed.json" <<'JSON'
{
  "reviewComplete": false,
  "lensStatus": [{"lens": "a11y", "status": "failed"}],
  "unverified": []
}
JSON
# reviewComplete 만 true 로 위조하고 lensStatus 는 미완결 — "true 면 통과" 로만 짜면 여기서 샌다.
cat > "$TMP/forged.json" <<'JSON'
{
  "reviewComplete": true,
  "lensStatus": [{"lens": "behavior", "status": "ok"}, {"lens": "markup", "status": "failed"}],
  "unverified": []
}
JSON
cat > "$TMP/unverified.json" <<'JSON'
{
  "reviewComplete": true,
  "lensStatus": [{"lens": "behavior", "status": "ok"}],
  "unverified": [{"id": "f3", "title": "판정 못 받음"}]
}
JSON
cat > "$TMP/string-true.json" <<'JSON'
{
  "reviewComplete": "true",
  "lensStatus": [{"lens": "behavior", "status": "ok"}],
  "unverified": []
}
JSON
cat > "$TMP/no-lens.json" <<'JSON'
{"reviewComplete": true, "unverified": []}
JSON
cat > "$TMP/empty-lens.json" <<'JSON'
{"reviewComplete": true, "lensStatus": [], "unverified": []}
JSON
printf '{ this is not json' > "$TMP/broken.json"

seed_marker() { mkdir -p "$REPO/.claude"; printf '2000-01-01 SENTINEL\n' > "$MARKER"; }
marker_now() { cat "$MARKER" 2>/dev/null; }

stage_change() { # 스테이징된 변경 하나 만들기
  printf 'change %s\n' "$1" >> "$REPO/a.txt"
  git -C "$REPO" add a.txt
}

RD_FLAGS='--no-color --no-ext-diff --no-textconv'   # lib/review-diff.sh 의 _rd_flags 와 같은 값이어야 한다
expect_staged_hash() { # lib/review-diff.sh 와 동일 계산(diff 플래그·명령치환이 후행 개행을 벗기는 것까지 동일)
  d=$(git -C "$REPO" diff $RD_FLAGS --cached 2>/dev/null)
  printf '%s' "$d" | shasum -a 256 | awk '{print $1}'
}
expect_amend_hash() { # v2.1 계약: 현 인덱스 사본 + `git add -u`(= commit -a 가 커밋 직전에 하는 일)의 diff --cached
  local ti; ti=$(mktemp "$TMP/amend-idx.XXXXXX")
  cp "$(git -C "$REPO" rev-parse --path-format=absolute --git-path index)" "$ti"
  GIT_INDEX_FILE="$ti" git -C "$REPO" add -u
  d=$(GIT_INDEX_FILE="$ti" git -C "$REPO" diff $RD_FLAGS --cached 2>/dev/null)
  printf '%s' "$d" | shasum -a 256 | awk '{print $1}'
}

reminder_rc() { # 짝 훅에 stdin JSON 을 먹이고 deny 여부를 돌려준다: "pass" | "deny"
  out=$(jq -n --arg c "$COMMIT_CMD" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}' \
        | bash "$REMINDER" 2>/dev/null)
  case "$out" in
    *'"permissionDecision"'*'"deny"'*) printf 'deny' ;;
    "") printf 'pass' ;;
    *) printf 'other' ;;
  esac
}
reminder_reason() { # 짝 훅의 deny 문구(permissionDecisionReason)
  jq -n --arg c "$COMMIT_CMD" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}' \
    | bash "$REMINDER" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}

echo "== mark-review.sh 계약 테스트 =="

# ── 0. 전제: 스테이징 없음 → 어느 경로로도 마커를 찍지 않는다 ────────────────
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "스테이징 변경 없음 → --result 여도 거부(exit 1)"
ok "2000-01-01 SENTINEL" "$(marker_now)" "거부 시 기존 마커를 덮지 않는다"

stage_change 1
EXPECT_HASH="$(expect_staged_hash)"

# ── 1. 양성: 완결 결과 → 마커 기록 + 지문이 짝 훅 계약과 일치 ────────────────
seed_marker
ok "deny" "$(reminder_rc)" "마커가 SENTINEL 이면 짝 훅은 커밋을 막는다(양성 대조)"
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "0" "$rc" "양성: reviewComplete=true·lensStatus 전부 ok·unverified 0 → exit 0"
ok "$(date +%F) $EXPECT_HASH" "$(marker_now)" "기록 형식 '<YYYY-MM-DD> <staged diff sha256>' 유지"
ok "pass" "$(reminder_rc)" "짝 훅이 이 마커로 통과한다(지문 계약 보존)"

# ── 2. 음성: 미완결 결과는 전부 거부 + 마커 불변 ─────────────────────────────
for f in empty-scan unknown-lens dropped failed forged unverified string-true no-lens empty-lens broken uncovered no-uncovered uncovered-string partial-scan; do
  seed_marker
  out=$(bash "$HOOK" --result "$TMP/$f.json" 2>&1); rc=$?
  ok "1" "$rc" "음성: $f.json → 거부(exit 1)"
  ok "2000-01-01 SENTINEL" "$(marker_now)" "음성: $f.json → 마커 불변"
done

# 거부 안내문: 상태값을 나열하지 않고 정본을 가리키며, uncoveredFiles 재실행 안내와 그 파일 목록을 보여준다.
seed_marker
out=$(bash "$HOOK" --result "$TMP/uncovered.json" 2>&1); rc=$?
contains "$out" "uncoveredFiles=A.java" "거부 안내: 덮이지 않은 파일 목록을 보여준다"
contains "$out" "uncoveredFiles 가 있으면 그 파일을 읽는 관점으로 재실행" "거부 안내: uncoveredFiles 재실행 방법을 안내한다"
contains "$out" "정본 = .claude/workflows/commit-review.js" "거부 안내: 상태값 정본 포인터"
case "$out" in *"failed/empty-scan"*) r=listed ;; *) r=none ;; esac
ok "none" "$r" "거부 안내: 옛 상태값 나열(failed/empty-scan/…)이 남지 않는다"

# 양성: 관점별 누락만 있고 합집합이 덮은 결과 → 통과
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok-lens-gap.json" 2>&1); rc=$?
ok "0" "$rc" "양성: 관점별 누락(unreviewedFiles)만 있고 uncoveredFiles 빈 배열 → exit 0"
ok "$(date +%F) $EXPECT_HASH" "$(marker_now)" "양성(관점별 누락): 마커 기록"

seed_marker
out=$(bash "$HOOK" --result "$TMP/does-not-exist.json" 2>&1); rc=$?
ok "1" "$rc" "음성: 결과 파일 부재 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "음성: 결과 파일 부재 → 마커 불변"

# ── 3. 음성: 인자 없는 호출(옛 계약)은 더 이상 찍지 않는다 ───────────────────
seed_marker
out=$(bash "$HOOK" 2>&1); rc=$?
ok "1" "$rc" "음성: 인자 없이 호출 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "음성: 인자 없이 호출 → 마커 불변"
contains "$out" "--skip-reason" "인자 없는 호출은 두 경로를 안내한다"

# 짝 훅의 deny 문구가 **살아 있는 호출형**을 안내하는가(안내가 죽은 형태를 가리키면 무한 루프가 된다).
seed_marker
REASON="$(reminder_reason)"
contains "$REASON" "--result" "짝 훅 deny 문구가 --result 경로를 안내한다"
contains "$REASON" "--skip-reason" "짝 훅 deny 문구가 --skip-reason 경로를 안내한다"
contains "$REASON" "인자 없는 호출은 마커를 찍지 않습니다" "짝 훅 deny 문구가 인자 없는 호출 금지를 명시한다"
contains "$REASON" "uncoveredFiles" "짝 훅 deny 문구가 uncoveredFiles 미완결을 안내한다"
contains "$REASON" 'bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON>' "짝 훅 deny 문구에 --result 호출형이 그대로 있다"
contains "$REASON" 'bash .claude/hooks/mark-review.sh --skip-reason "<사유>"' "짝 훅 deny 문구에 --skip-reason 호출형이 그대로 있다"

# --help — 종료 0 · 두 형태와 언제 쓰는지 · 마커 불변
seed_marker
out=$(bash "$HOOK" --help 2>/dev/null); rc=$?
ok "0" "$rc" "--help → 종료 0(표준출력)"
contains "$out" "--result      = 리뷰 워크플로" "--help 가 --result 를 언제 쓰는지 안내한다"
contains "$out" "--skip-reason = 결과 JSON 이 없는 리뷰" "--help 가 --skip-reason 을 언제 쓰는지 안내한다"
ok "2000-01-01 SENTINEL" "$(marker_now)" "--help → 마커 불변"
case "$REASON" in *"dropped/failed/empty-scan"*) r=listed ;; *) r=none ;; esac
ok "none" "$r" "짝 훅 deny 문구가 옛 상태값 나열을 남기지 않는다"

seed_marker
out=$(bash "$HOOK" --result "$TMP/ok.json" --skip-reason "둘 다" 2>&1); rc=$?
ok "1" "$rc" "음성: --result 와 --skip-reason 동시 → 거부"
out=$(bash "$HOOK" --unknown-flag 2>&1); rc=$?
ok "1" "$rc" "음성: 알 수 없는 인자 → 거부"
out=$(bash "$HOOK" --skip-reason 2>&1); rc=$?
ok "1" "$rc" "음성: --skip-reason 값 누락 → 거부"

# ── 4. 우회: --skip-reason → 마커 기록 + 로그 누적 + 사용자 통지 문구 ────────
seed_marker
rm -f "$LOG"
out=$(bash "$HOOK" --skip-reason "문서만 변경 — 사용자 지시로 리뷰 생략" 2>&1); rc=$?
ok "0" "$rc" "우회: --skip-reason → exit 0"
ok "$(date +%F) $EXPECT_HASH" "$(marker_now)" "우회: 지문 계약 동일"
ok "pass" "$(reminder_rc)" "우회: 짝 훅 통과"
contains "$out" "사용자에게 알리세요" "우회: 사용자 통지 문구 출력"
contains "$(cat "$LOG" 2>/dev/null)" "문서만 변경" "우회: 사유가 .review-marker.log 에 남는다"
ok "1" "$(wc -l < "$LOG" | tr -d ' ')" "우회: 로그 1줄"

out=$(bash "$HOOK" --skip-reason $'여러 줄\n사유\t탭' 2>&1); rc=$?
ok "0" "$rc" "우회: 두 번째 호출도 성공"
ok "2" "$(wc -l < "$LOG" | tr -d ' ')" "우회: 로그는 append — 앞 기록이 지워지지 않는다"
ok "1" "$(grep -c '여러 줄 사유 탭' "$LOG" | tr -d ' ')" "우회: 줄바꿈·탭은 한 줄로 접어 기록"

# 공백뿐인 사유: 종료코드만 보면 구멍을 못 본다 — **마커가 바뀌지 않았는지**까지 단언한다.
# (2026-09-18 실측 결함: 사유 검증이 마커 기록 **뒤**에 있어 rc=1 인데도 .last-review 가 갱신됐다.
#  파일 존재만으로는 앞 케이스가 남긴 마커와 구분되지 않으므로 SENTINEL 을 심고 불변을 본다.)
seed_marker
LOGLINES_BEFORE=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
out=$(bash "$HOOK" --skip-reason "   " 2>&1); rc=$?
ok "1" "$rc" "음성: 공백뿐인 사유 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "음성: 공백뿐인 사유 → 마커 불변(부수효과 없음)"
ok "deny" "$(reminder_rc)" "음성: 공백뿐인 사유 → 짝 훅이 여전히 커밋을 막는다"
ok "$LOGLINES_BEFORE" "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" "음성: 공백뿐인 사유 → 로그도 늘지 않는다"

# ── 5. --amend/--all/-a 계약(워킹트리까지 커밋하는 경우의 지문) ──────────────
# v2.1 에서 지문 정의가 바뀌었다: 옛 = `diff HEAD` + `diff --cached` 이어붙임 →
#   새 = 임시 인덱스(현 인덱스 + add -u)의 `diff --cached` — commit -a 가 커밋 직전에 만드는 인덱스와 같은 내용.
printf 'worktree only\n' >> "$REPO/a.txt"   # 스테이징하지 않은 변경
EXPECT_AMEND="$(expect_amend_hash)"
IDX_BEFORE="$(expect_staged_hash)"
OLD_FORMULA=$( { git -C "$REPO" diff $RD_FLAGS HEAD; git -C "$REPO" diff $RD_FLAGS --cached; } | shasum -a 256 | awk '{print $1}')
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok.json" --amend 2>&1); rc=$?
ok "0" "$rc" "--amend + --result → exit 0"
ok "$(date +%F) $EXPECT_AMEND" "$(marker_now)" "--amend 지문 = 임시 인덱스(현 인덱스 + add -u) diff --cached"
ok "$IDX_BEFORE" "$(expect_staged_hash)" "--amend 는 실제 인덱스를 바꾸지 않는다(임시 인덱스만 add -u)"
[ "$EXPECT_AMEND" != "$OLD_FORMULA" ]; ok "0" "$?" "새 지문 != 옛 이어붙임 공식(같으면 이 절이 계약 전환을 못 가른다)"
seed_marker
out=$(bash "$HOOK" -a --skip-reason "amend 생략" 2>&1); rc=$?
ok "0" "$rc" "-a + --skip-reason → exit 0"
ok "$(date +%F) $EXPECT_AMEND" "$(marker_now)" "-a 도 같은 지문(별칭 --amend/--all/-a 유지)"
ok "$IDX_BEFORE" "$(expect_staged_hash)" "-a 도 실제 인덱스를 바꾸지 않는다"

# ── 6. 결과 파일 판독 = 값 하나 + jq 종료코드 0(--result) ─────────────────────
git -C "$REPO" checkout -q -- a.txt   # 5절의 미스테이징 변경을 걷어낸다(스테이징은 그대로)
ok "$EXPECT_HASH" "$(expect_staged_hash)" "(전제) 6절 시작 시 스테이징 지문 = 1절 지문"
not_contains() { # not_contains <haystack> <needle> <설명>
  case "$1" in *"$2"*) r=found ;; *) r=none ;; esac
  ok "none" "$r" "$3"
}
{ cat "$TMP/ok.json"; printf 'trailing text\n'; } > "$TMP/ok-trailing.json"
{ cat "$TMP/ok.json"; cat "$TMP/ok.json"; } > "$TMP/ok-twice.json"
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok-trailing.json" 2>&1); rc=$?
ok "1" "$rc" "R1 --result: 정상 JSON 뒤 후행 텍스트 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "R1 --result: 후행 텍스트 → 마커 불변"
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok-twice.json" 2>&1); rc=$?
ok "1" "$rc" "R1 --result: JSON 값 2개 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "R1 --result: JSON 값 2개 → 마커 불변"
contains "$out" "JSON 값 개수=2" "R1 --result: 값 개수를 안내한다"

# ── 7. --begin / --builtin ──────────────────────────────────────────────────
PENDING="$REPO/.claude/.review-pending"
bfile() { # bfile <내용> → 레포 밖 결과 파일 경로
  local f; f=$(mktemp "$TMP/bi.XXXXXX"); printf '%s' "$1" > "$f"; printf '%s' "$f"
}
gone() { [ -e "$1" ] && printf 'exists' || printf 'gone'; }

# --begin: 마커는 안 찍고 지문만 기록
seed_marker; rm -f "$PENDING"
out=$(bash "$HOOK" --begin 2>&1); rc=$?
ok "0" "$rc" "--begin → exit 0"
ok "2000-01-01 SENTINEL" "$(marker_now)" "--begin 은 마커를 찍지 않는다"
ok "$EXPECT_HASH" "$(awk '{print $2}' "$PENDING" 2>/dev/null)" "--begin 은 현재 스테이징 지문을 .review-pending 에 기록"

# 양성: 빈 배열
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "0" "$rc" "builtin 양성: 빈 배열 → exit 0"
ok "$(date +%F) $EXPECT_HASH" "$(marker_now)" "builtin 양성: 빈 배열 → 마커 기록(지문 계약 동일)"
ok "pass" "$(reminder_rc)" "builtin 양성: 짝 훅 통과"
contains "$out" "빌트인 지적 0건 — 리뷰 실패와 구분되지 않으니 사용자에게 보고" "builtin 양성: 빈 배열은 0건/실패 구분 불가 문구"
ok "gone" "$(gone "$F")" "builtin 양성: 결과 파일 삭제"
ok "gone" "$(gone "$PENDING")" "builtin 양성: 통과 후 .review-pending 소거"

# 양성: nit·pre_existing 만 — 건수·스테이징 경로 pre_existing 위치만 출력, 원문은 출력하지 않는다
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[{"file":"a.txt","line":3,"severity":"pre_existing","summary":"SECRET-PW-123","failure_scenario":"FS-TEXT"},
            {"file":"z.txt","line":9,"severity":"pre_existing","summary":"s"},
            {"file":"a.txt","line":1,"severity":"nit","summary":"SECRET-PW-123"}]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "0" "$rc" "builtin 양성: nit·pre_existing 만 → exit 0"
ok "$(date +%F) $EXPECT_HASH" "$(marker_now)" "builtin 양성: nit·pre_existing → 마커 기록"
contains "$out" "nit 1건 · pre_existing 2건" "builtin 양성: nit·pre_existing 건수 출력"
contains "$out" "사용자에게 보고" "builtin 양성: 사용자 보고 문구"
contains "$out" "a.txt:3" "R6: 스테이징 경로에 붙은 pre_existing 은 파일:줄 출력"
not_contains "$out" "z.txt:9" "R6: 스테이징 밖 경로의 pre_existing 은 목록에 없다"
not_contains "$out" "SECRET-PW-123" "builtin 진단은 summary 원문을 출력하지 않는다"
not_contains "$out" "FS-TEXT" "builtin 진단은 failure_scenario 원문을 출력하지 않는다"
ok "gone" "$(gone "$F")" "builtin 양성(nit): 결과 파일 삭제"

# 음성: 형식 위반 — 각각 거부 + 마커 불변 + 결과 파일 삭제
bi_neg() { # bi_neg <이름> <내용>
  seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
  local f; f=$(bfile "$2")
  out=$(bash "$HOOK" --builtin "$f" 2>&1); rc=$?
  ok "1" "$rc" "builtin 음성: $1 → 거부"
  ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: $1 → 마커 불변"
  # 형식 판정 전 거부 = 결과 배열로 판독되지 않은 파일 → 지우지 않는다(경로 오지정 손실 방지).
  ok "exists" "$(gone "$f")" "builtin 음성: $1 → 결과 파일 보존(형식 판정 전 거부)"
  rm -f "$f"
}
bi_neg "알 수 없는 severity" '[{"file":"a.txt","line":1,"severity":"critical"}]'
bi_neg "severity 누락" '[{"file":"a.txt","line":1}]'
bi_neg "원소가 객체 아님" '["a.txt"]'
bi_neg "최상위 객체" '{"findings":[]}'
bi_neg "빈 파일" ''
bi_neg "JSON 아님" '{ not json'
bi_neg "R1 후행 텍스트" '[] trailing'
bi_neg "R1 JSON 값 2개" '[] []'
contains "$(cat "$LOG" 2>/dev/null)" "skip-reason" "(전제) 로그는 4절 기록만 있다"
not_contains "$(cat "$LOG" 2>/dev/null)" "builtin-ng" "형식 위반 거부는 builtin-ng 를 남기지 않는다(폴백 허용)"

# 음성: pending 없음
seed_marker; rm -f "$PENDING"
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: --begin 없이 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: --begin 없이 → 마커 불변"
ok "gone" "$(gone "$F")" "builtin 음성: --begin 없이 → 결과 파일 삭제"

# 음성: 지문 불일치(--begin 뒤 스테이징 변경)
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
stage_change 2
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: --begin 뒤 스테이징 변경(지문 불일치) → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: 지문 불일치 → 마커 불변"
contains "$out" "지문 불일치" "builtin 음성: 지문 불일치 안내"
EXPECT_HASH2="$(expect_staged_hash)"

# 음성: 결과 파일이 --begin 보다 먼저 쓰임
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[]'); touch -t 200001010000 "$F"
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: 결과 mtime 이 --begin 이전 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: mtime 이전 → 마커 불변"

# 음성: 레포 작업 트리 안 경로 — 거부하되 지우지 않는다 / 심볼릭 링크 거부
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
printf '[]' > "$REPO/bi-in-repo.json"
out=$(bash "$HOOK" --builtin "$REPO/bi-in-repo.json" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: 결과 파일이 레포 안 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: 레포 안 → 마커 불변"
ok "exists" "$(gone "$REPO/bi-in-repo.json")" "builtin 음성: 레포 안 경로는 지우지 않는다"
rm -f "$REPO/bi-in-repo.json"
F=$(bfile '[]'); ln -s "$F" "$TMP/bi-link.json"
out=$(bash "$HOOK" --builtin "$TMP/bi-link.json" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: 심볼릭 링크 → 거부"
ok "exists" "$(gone "$F")" "builtin 음성: 심볼릭 링크 대상은 지우지 않는다"

# 음성: 스테이징 경로에 미스테이징 변경 — --begin·--builtin 모두 거부, -a 모드면 그 모드 지문으로 통과
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
printf 'unstaged\n' >> "$REPO/a.txt"
out=$(bash "$HOOK" --begin 2>&1); rc=$?
ok "1" "$rc" "R3: 스테이징 경로에 미스테이징 변경 → --begin 거부"
contains "$out" "- a.txt" "R3: 겹친 경로 목록 출력"
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "R3: 스테이징 경로에 미스테이징 변경 → --builtin 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "R3: --builtin 거부 → 마커 불변"
EXPECT_AMEND2="$(expect_amend_hash)"
out=$(bash "$HOOK" --begin -a 2>&1); rc=$?
ok "0" "$rc" "R3 -a 모드: --begin -a → exit 0"
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" -a 2>&1); rc=$?
ok "0" "$rc" "R3 -a 모드: --builtin -a → exit 0"
ok "$(date +%F) $EXPECT_AMEND2" "$(marker_now)" "R3 -a 모드: 마커 = 임시 인덱스 지문"
git -C "$REPO" checkout -q -- a.txt
# 스테이징되지 않은 추적 파일 b.txt 의 워킹트리 변경 — -a 지문과 스테이징 지문이 갈린다(겹침 검사엔 안 걸린다).
printf 'b\n' > "$REPO/b.txt"; git -C "$REPO" add b.txt; git -C "$REPO" commit -q -m b -- b.txt
printf 'b2\n' >> "$REPO/b.txt"
ok "$EXPECT_HASH2" "$(expect_staged_hash)" "(전제) b.txt 커밋 뒤에도 스테이징 지문 불변"
seed_marker; bash "$HOOK" --begin -a >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "--begin -a 뒤 -a 없는 --builtin → 지문 불일치 거부"
git -C "$REPO" checkout -q -- b.txt

# R7: 판정 근거 플래그는 하나만
seed_marker
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "R7: --builtin + --result → 거부"
out=$(bash "$HOOK" --begin --skip-reason "x" 2>&1); rc=$?
ok "1" "$rc" "R7: --begin + --skip-reason → 거부"
out=$(bash "$HOOK" --builtin "$F" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "R7: --builtin 반복 → 거부"
out=$(bash "$HOOK" --builtin 2>&1); rc=$?
ok "1" "$rc" "R7: --builtin 값 누락 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "R7: 인자 충돌 → 마커 불변"
rm -f "$F"

# 음성: important 1건(스테이징 밖 파일) → 거부 + builtin-ng 기록 → 같은 지문 --result 거부, --skip-reason 만 통과
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[{"file":"other.txt","line":7,"severity":"important","summary":"SECRET-PW-123"},{"file":"a.txt","line":1,"severity":"nit"}]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "builtin 음성: important 1건(스테이징 밖 파일) → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "builtin 음성: important → 마커 불변"
ok "gone" "$(gone "$F")" "builtin 음성: important → 결과 파일 삭제"
contains "$out" "other.txt:7" "builtin 음성: important 위치(파일:줄) 출력"
not_contains "$out" "SECRET-PW-123" "builtin 음성: important 원문은 출력하지 않는다"
ok "1" "$(grep -c "^$(date +%F) $EXPECT_HASH2 builtin-ng important=1 idx=$EXPECT_HASH2 all=$EXPECT_HASH2\$" "$LOG" | tr -d ' ')" "R4: builtin-ng 가 '<날짜> <지문> builtin-ng important=N idx= all=' 으로 기록"
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "R4: builtin-ng 지문에 --result → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "R4: --result 거부 → 마커 불변"
contains "$out" "--skip-reason" "R4: --skip-reason 경로를 안내한다"
out=$(bash "$HOOK" --skip-reason "빌트인 important 오탐 판단" 2>&1); rc=$?
ok "0" "$rc" "R4: builtin-ng 지문이어도 --skip-reason 은 통과"

# ── 8. 수리 1라운드(M0~M8) ──────────────────────────────────────────────────
# M0: 같은 지문 마커가 먼저 있어도 판정 거부 시 마커를 무효화한다(--result·--builtin)
stage_change 4
H3="$(expect_staged_hash)"
bash "$HOOK" --skip-reason "M0 선행 마커" >/dev/null 2>&1
ok "$(date +%F) $H3" "$(marker_now)" "(전제) M0: 같은 지문 마커가 먼저 찍혀 있다"
out=$(bash "$HOOK" --result "$TMP/failed.json" 2>&1); rc=$?
ok "1" "$rc" "M0: --result 미완결 → 거부"
ok "gone" "$(gone "$MARKER")" "M0: --result 미완결 거부 → 같은 지문 마커 삭제"
ok "deny" "$(reminder_rc)" "M0: --result 거부 뒤 짝 훅이 커밋을 막는다"
bash "$HOOK" --skip-reason "M0 선행 마커 2" >/dev/null 2>&1
bash "$HOOK" --begin >/dev/null 2>&1
# M6: .file 이 객체·.line 이 문자열이면 "?" — 원문이 섞여 나오지 않는다
F=$(bfile '[{"file":{"summary":"password=SAMPLE-m6-leak"},"line":"L-TEXT","severity":"important"}]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "M0: builtin important → 거부"
ok "gone" "$(gone "$MARKER")" "M0: builtin important 거부 → 같은 지문 마커 삭제"
contains "$out" "  - ?:?" "M6: 문자열 아닌 .file·숫자 아닌 .line 은 ?:? 로 출력"
not_contains "$out" "SAMPLE-m6-leak" "M6: .file 객체 원문을 출력하지 않는다"
not_contains "$out" "L-TEXT" "M6: .line 문자열 원문을 출력하지 않는다"
ok "gone" "$(gone "$PENDING")" "M1: important 거부 시 .review-pending 소거"
# M1: ng 뒤 같은 pending 으로 재제출 / --begin 다시 + [] 재제출 → 둘 다 거부
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "M1: ng 직후 pending 없이 [] 재제출 → 거부"
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "M1: ng 뒤 --begin 다시 + [] 재제출 → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "M1: ng 재제출 거부 → 마커 불변"
contains "$out" "--skip-reason" "M1: 재제출 거부 안내에 --skip-reason 경로"

# M4: -a 로 ng 를 받은 뒤 모드를 바꿔도 거부(두 지문 기록)
stage_change 5
printf 'b3\n' >> "$REPO/b.txt"   # 스테이징 밖 추적 파일 변경 → 인덱스 지문 ≠ -a 지문
H4I="$(expect_staged_hash)"; H4A="$(expect_amend_hash)"
[ "$H4I" != "$H4A" ]; ok "0" "$?" "(전제) M4: 인덱스 지문 ≠ -a 지문"
seed_marker; bash "$HOOK" --begin -a >/dev/null 2>&1
F=$(bfile '[{"file":"a.txt","line":1,"severity":"important"}]')
out=$(bash "$HOOK" --builtin "$F" -a 2>&1); rc=$?
ok "1" "$rc" "M4: -a important → 거부"
ok "1" "$(grep -c " builtin-ng important=1 idx=$H4I " "$LOG" | tr -d ' ')" "M4: ng 를 인덱스 지문으로도 기록"
ok "1" "$(grep -c " idx=$H4I all=$H4A\$" "$LOG" | tr -d ' ')" "M4: ng 를 -a 지문으로도 기록"
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "M4: -a ng 뒤 -a 없는 --result → 거부"
bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "M4: -a ng 뒤 -a 없는 --builtin → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "M4: 모드 전환 거부 → 마커 불변"
# N1 양성: -a 모드 ng 의 원인(미스테이징 b.txt)을 고치면 -a 재리뷰로 통과한다(all 칸만 대조)
printf 'fixed\n' >> "$REPO/b.txt"
H4A2="$(expect_amend_hash)"
bash "$HOOK" --begin -a >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" -a 2>&1); rc=$?
ok "0" "$rc" "N1: -a 에서 미스테이징 파일 수리 후 --builtin -a → 통과"
ok "$(date +%F) $H4A2" "$(marker_now)" "N1: 수리 후 마커 = 새 -a 지문"
# N1 음성(역방향): 인덱스 모드 ng 뒤 -a 로 바꿔도 거부(ng 시점 all 칸이 일치)
stage_change 55
H5I="$(expect_staged_hash)"
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[{"file":"a.txt","line":2,"severity":"important"}]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "N1: 인덱스 모드 important → 거부"
bash "$HOOK" --begin -a >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" -a 2>&1); rc=$?
ok "1" "$rc" "N1: 인덱스 모드 ng 뒤 -a 로 바꾼 --builtin → 거부"
out=$(bash "$HOOK" --result "$TMP/ok.json" -a 2>&1); rc=$?
ok "1" "$rc" "N1: 인덱스 모드 ng 뒤 -a 로 바꾼 --result → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "N1: 역방향 모드 전환 거부 → 마커 불변"
git -C "$REPO" checkout -q -- b.txt
# E1 음성: 스테이징 0 에서 -a 로 ng(idx= 칸이 빈 값) → 같은 내용을 스테이징한 뒤 인덱스 모드 --result/--builtin 도 거부
git -C "$REPO" commit -q -m e1-base   # 스테이징 0 으로 만든다(임시 저장소)
printf 'e1\n' >> "$REPO/a.txt"        # 미스테이징 변경만
HE1="$(expect_amend_hash)"
seed_marker; bash "$HOOK" --begin -a >/dev/null 2>&1
F=$(bfile '[{"file":"a.txt","line":1,"severity":"important"}]')
out=$(bash "$HOOK" --builtin "$F" -a 2>&1); rc=$?
ok "1" "$rc" "E1: 스테이징 0 + -a important → 거부"
ok "1" "$(grep -c " $HE1 builtin-ng important=1 idx= all=$HE1\$" "$LOG" | tr -d ' ')" "(전제) E1: ng 의 idx= 칸이 빈 값으로 기록"
git -C "$REPO" add a.txt
ok "$HE1" "$(expect_staged_hash)" "(전제) E1: 스테이징 뒤 인덱스 지문 = ng 의 -a 지문"
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "E1: 빈 idx= 칸 ng 뒤 인덱스 모드 --result → 거부"
bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[]')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "E1: 빈 idx= 칸 ng 뒤 인덱스 모드 --builtin → 거부"
ok "2000-01-01 SENTINEL" "$(marker_now)" "E1: 빈 칸 모드 전환 거부 → 마커 불변"

# 이후 케이스용 새 지문(ng 기록 없음)
stage_change 6

# M2: 임시 디렉터리 밖 결과 파일 → 거부·보존 / 형식 판정 전 거부된 임시 디렉터리 안 일반 파일 → 보존
OUTSIDE="$TMP/outside-tmp"; FAKETMP="$TMP/fake-tmpdir"; mkdir -p "$OUTSIDE" "$FAKETMP"
_tmp_real=$(cd "$TMP" && pwd -P)
case "$_tmp_real" in
  /tmp/*|/private/tmp/*) echo "  ⚠️ M2 임시 디렉터리 밖 케이스 건너뜀(테스트 TMP 가 /tmp 아래)" ;;
  *)
    seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
    printf '[]' > "$OUTSIDE/precious.json"
    out=$(TMPDIR="$FAKETMP" bash "$HOOK" --builtin "$OUTSIDE/precious.json" 2>&1); rc=$?
    ok "1" "$rc" "M2: 임시 디렉터리 밖 결과 파일 → 거부"
    ok "exists" "$(gone "$OUTSIDE/precious.json")" "M2: 임시 디렉터리 밖 파일은 지우지 않는다"
    ok "2000-01-01 SENTINEL" "$(marker_now)" "M2: 임시 디렉터리 밖 → 마커 불변" ;;
esac
rm -f "$PENDING"
printf 'precious notes\n' > "$TMP/precious.txt"
out=$(bash "$HOOK" --builtin "$TMP/precious.txt" 2>&1); rc=$?
ok "1" "$rc" "M2: pending 없이 넘긴 일반 텍스트 파일 → 거부"
ok "exists" "$(gone "$TMP/precious.txt")" "M2: 결과 배열이 아닌 임시 디렉터리 안 파일은 지우지 않는다"

# M3: 대소문자만 바꾼 레포 안 경로 / 같은 저장소의 linked worktree → '안'으로 거부·보존
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
printf '[]' > "$REPO/bi-case.json"
UPREPO="$(dirname "$REPO")/REPO"
if [ -e "$UPREPO/bi-case.json" ]; then
  out=$(bash "$HOOK" --builtin "$UPREPO/bi-case.json" 2>&1); rc=$?
  ok "1" "$rc" "M3: 대소문자만 바꾼 레포 안 경로 → 거부"
  ok "exists" "$(gone "$REPO/bi-case.json")" "M3: 대소문자 경로의 레포 안 파일은 지우지 않는다"
  contains "$out" "즉시 지우고" "M7: 레포 안 거부 안내에 즉시 삭제 지시"
else
  echo "  ⚠️ M3 대소문자 케이스 건너뜀(대소문자 구분 파일시스템)"
fi
rm -f "$REPO/bi-case.json"
git -C "$REPO" worktree add -q --detach "$TMP/wt-sibling" 2>/dev/null
printf '[]' > "$TMP/wt-sibling/bi-wt.json"
out=$(bash "$HOOK" --builtin "$TMP/wt-sibling/bi-wt.json" 2>&1); rc=$?
ok "1" "$rc" "M3: 같은 저장소의 linked worktree 안 경로 → 거부"
ok "exists" "$(gone "$TMP/wt-sibling/bi-wt.json")" "M3: linked worktree 안 파일은 지우지 않는다"
ok "2000-01-01 SENTINEL" "$(marker_now)" "M3: 레포 안 거부 → 마커 불변"

# M8: 판정 도중 다른 세션이 --begin 으로 pending 을 바꾸면 성공해도 그 pending 은 지우지 않는다
REALJQ=$(command -v jq)
mkdir -p "$TMP/shim"
cat > "$TMP/shim/jq" <<SHIM
#!/bin/bash
case "\$*" in *'map(select('*) printf '9999999999 OTHER\n' > "$PENDING" ;; esac
exec "$REALJQ" "\$@"
SHIM
chmod +x "$TMP/shim/jq"
seed_marker; bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile '[]')
out=$(PATH="$TMP/shim:$PATH" bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "0" "$rc" "M8: 판정 도중 pending 교체 → 이번 판정은 통과"
ok "9999999999 OTHER" "$(cat "$PENDING" 2>/dev/null)" "M8: 다른 세션이 새로 쓴 pending 은 지우지 않는다"
rm -f "$PENDING"

# ── 9. 수리 2라운드(N2·N3·이전 로그 형식 호환) ──────────────────────────────
stage_change 7
H7="$(expect_staged_hash)"
# N3: 형식 판정 불가는 절차 거부 — 같은 지문의 기존 마커를 지우지 않는다
bash "$HOOK" --skip-reason "N3 선행 마커" >/dev/null 2>&1
bash "$HOOK" --begin >/dev/null 2>&1
F=$(bfile 'not a json array')
out=$(bash "$HOOK" --builtin "$F" 2>&1); rc=$?
ok "1" "$rc" "N3: 형식 판정 불가 → 거부"
ok "$(date +%F) $H7" "$(marker_now)" "N3: 형식 판정 불가 거부 → 같은 지문 기존 마커 보존"
rm -f "$F"
# N2: 임시 디렉터리 아래 다른 git 레포의 추적 파일 → 거부·보존
OTHER="$TMP/other-repo"; mkdir -p "$OTHER"
git -C "$OTHER" init -q; git -C "$OTHER" config user.email t@example.invalid; git -C "$OTHER" config user.name t
printf '[]' > "$OTHER/data.json"; git -C "$OTHER" add data.json; git -C "$OTHER" -c commit.gpgsign=false commit -q -m d
out=$(bash "$HOOK" --builtin "$OTHER/data.json" 2>&1); rc=$?
ok "1" "$rc" "N2: 다른 git 레포 안 결과 파일 → 거부"
ok "exists" "$(gone "$OTHER/data.json")" "N2: 다른 git 레포의 추적 파일은 지우지 않는다"
ok "" "$(git -C "$OTHER" status --porcelain)" "N2: 다른 git 레포 작업 트리 변화 없음"
# 이전 형식 ng 줄(idx=/all= 없음)은 그 지문을 두 칸 모두로 읽는다
printf '%s %s builtin-ng important=1\n' "$(date +%F)" "$H7" >> "$LOG"
seed_marker
out=$(bash "$HOOK" --result "$TMP/ok.json" 2>&1); rc=$?
ok "1" "$rc" "호환: 이전 형식 ng 줄 → 인덱스 모드 --result 거부"
out=$(bash "$HOOK" --result "$TMP/ok.json" -a 2>&1); rc=$?
ok "1" "$rc" "호환: 이전 형식 ng 줄 → -a 모드 --result 거부"

# --help·짝 훅 문구 — 기본 = 워크플로, 빌트인 = 대체 엔진 안내, 호출 금지 문장 제거
out=$(bash "$HOOK" --help 2>/dev/null)
contains "$out" "--result      = 리뷰 워크플로(commit-review.js) 결과 JSON 이 있을 때 — A티어 기본 엔진" "--help 가 워크플로를 A티어 기본 엔진으로 안내한다"
contains "$out" "--begin → --builtin = 레포 규약이 빌트인 Skill(code-review)을 대체 엔진으로" "--help 가 빌트인 경로를 대체 엔진으로 안내한다"
contains "$out" 'Result 가 `(none)` 이면 `[]` 로 옮긴다' "N1: --help 가 (none) → [] 변환을 안내한다"
seed_marker
REASON="$(reminder_reason)"
contains "$REASON" "bash .claude/hooks/mark-review.sh --begin" "짝 훅 deny 문구에 --begin 호출형이 있다"
contains "$REASON" "bash .claude/hooks/mark-review.sh --builtin <결과 JSON 파일>" "짝 훅 deny 문구에 --builtin 호출형이 있다"
contains "$REASON" "Skill(code-review)" "짝 훅 deny 문구가 빌트인 리뷰(대체 엔진)를 안내한다"
not_contains "$REASON" "호출 금지" "짝 훅 deny 문구에 빌트인 호출 금지 문장이 없다"
contains "$REASON" 'Result 가 `(none)` 이면 `[]` 로 옮기고' "N1: 짝 훅 deny 문구가 (none) → [] 변환과 폴백을 안내한다"

# D3-1(델타 3라운드): -a 지문용 임시 인덱스가 원본 인덱스 mtime 을 보존해야 racy-git 재비교가 살아 있다 —
#   같은 mtime·같은 크기로 바뀐 미스테이징 추적 파일이 -a 지문에 들어가야 한다. 결정적 재현: 엔트리·파일·인덱스 mtime 을 모두 과거
#   한 시각으로 고정(= racy) → 임시 인덱스가 지금 시각을 받으면(cp) racy 가 풀려 g 를 놓치고, 보존하면(cp -p) 잡는다. ctime 은 trustctime=false.
RR="$TMP/racy"; mkdir -p "$RR"; RT=202001010000
git -C "$RR" init -q; git -C "$RR" config user.email "test@example.invalid"; git -C "$RR" config user.name "hook test"
git -C "$RR" config commit.gpgsign false; git -C "$RR" config core.hooksPath "$TMP/no-such-hooks"; git -C "$RR" config core.trustctime false
printf 'f0\n' > "$RR/f.txt"; printf 'g0\n' > "$RR/g.txt"; touch -t "$RT" "$RR/g.txt"
git -C "$RR" add f.txt g.txt; git -C "$RR" commit -q -m base
printf 'f1\n' > "$RR/f.txt"; git -C "$RR" add f.txt
printf 'BG\n' > "$RR/g.txt"; touch -t "$RT" "$RR/g.txt"     # 같은 크기(3바이트)·엔트리와 같은 mtime
touch -t "$RT" "$(git -C "$RR" rev-parse --path-format=absolute --git-path index)"   # 인덱스 파일도 같은 시각 = racy
d=$(git -C "$RR" diff $RD_FLAGS --cached 2>/dev/null); RI=$(printf '%s' "$d" | shasum -a 256 | awk '{print $1}')   # lib 과 같은 계산(명령치환이 후행 개행을 벗김)
( export CLAUDE_PROJECT_DIR="$RR"; cd "$RR" && bash "$HOOK" --begin -a >/dev/null 2>&1 )
RA=$(awk '{print $2}' "$RR/.claude/.review-pending" 2>/dev/null)
[ -n "$RA" ] && [ "$RA" != "$RI" ]; ok "0" "$?" "D3-1: racy 조건(같은 mtime·같은 크기)의 미스테이징 변경이 -a 지문에 들어간다(cp -p)"
# A2: RA 가 "HEAD + 스테이징 f + 워킹트리 g 내용"의 지문과 정확히 같은지. 기대 인덱스는 stat 캐시를 전혀 쓰지 않는 경로로 만든다 —
#   새 인덱스에 read-tree HEAD 후 f 는 현 인덱스의 blob(`:f.txt`), g 는 워킹트리 내용을 hash-object 한 blob 을 --cacheinfo 로 넣는다.
#   diff --cached 는 트리와 인덱스 blob 만 비교하므로 racy 판정(mtime·크기)에 영향받지 않는다 → 코드의 cp -p·add -u 경로와 독립.
RX="$TMP/racy-expect-idx"; rm -f "$RX"
_fb=$(git -C "$RR" rev-parse :f.txt); _gb=$(git -C "$RR" hash-object -w g.txt)
GIT_INDEX_FILE="$RX" git -C "$RR" read-tree HEAD
GIT_INDEX_FILE="$RX" git -C "$RR" update-index --cacheinfo "100644,$_fb,f.txt" --cacheinfo "100644,$_gb,g.txt"
d=$(GIT_INDEX_FILE="$RX" git -C "$RR" diff $RD_FLAGS --cached 2>/dev/null); RE=$(printf '%s' "$d" | shasum -a 256 | awk '{print $1}')
case "$d" in *"+BG"*) r=has ;; *) r=none ;; esac; ok "has" "$r" "(전제) A2: 기대 diff 에 g 의 워킹트리 내용(BG)이 들어 있다"
ok "$RE" "$RA" "A2: racy 조건의 -a 지문 = 독립 경로로 만든 기대 -a 지문"

# A1: -a 지문용 임시 인덱스는 0600 — 원본 인덱스가 0644 여도 cp -p 뒤 권한을 좁힌다.
#   관측: PATH 앞 git 심이 `add -u`(GIT_INDEX_FILE = 임시 인덱스) 호출 순간의 권한을 기록한다(임시 인덱스는 trap 으로 곧 지워진다).
REALGIT=$(command -v git); mkdir -p "$TMP/gshim"; PERMLOG="$TMP/idx-perm.log"; rm -f "$PERMLOG"
cat > "$TMP/gshim/git" <<GSHIM
#!/bin/bash
case " \$* " in *" add -u "*) [ -n "\${GIT_INDEX_FILE:-}" ] && { stat -c %a "\$GIT_INDEX_FILE" 2>/dev/null || stat -f %Lp "\$GIT_INDEX_FILE"; } >> "$PERMLOG" 2>/dev/null ;; esac
exec "$REALGIT" "\$@"
GSHIM
chmod +x "$TMP/gshim/git"
chmod 644 "$(git -C "$RR" rev-parse --path-format=absolute --git-path index)"
_ri=$(git -C "$RR" rev-parse --path-format=absolute --git-path index)
ok "644" "$(stat -c %a "$_ri" 2>/dev/null || stat -f %Lp "$_ri")" "(전제) A1: 원본 인덱스 권한 0644"
( export CLAUDE_PROJECT_DIR="$RR" PATH="$TMP/gshim:$PATH"; cd "$RR" && bash "$HOOK" --begin -a >/dev/null 2>&1 )
ok "600" "$(head -1 "$PERMLOG" 2>/dev/null)" "A1: -a 지문용 임시 인덱스 권한 = 0600"

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" = "$pass" ]
