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

TMP="$(mktemp -d)"
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

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" = "$pass" ]
