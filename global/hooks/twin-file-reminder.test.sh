#!/usr/bin/env bash
# twin-file-reminder.sh 테스트 — 격리된 임시 git 레포(mktemp)에서만 동작. 실제 작업
# 레포는 읽지도 쓰지도 않는다(데이터손실 방지: trap 으로 임시 디렉토리만 정리).
# 판정은 substring grep 이 아니라 jq 로 JSON 구조·필드값을 단언한다(반증검사 부칙 — 메시지는 구조적으로).
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/twin-file-reminder.sh"
if [ ! -e "$HOOK" ]; then
  echo "FAIL: 훅 파일 없음: $HOOK"
  echo "Tests run: 1, Passed: 0"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/twin-file-reminder-test.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

git -C "$WORK" init -q

# --- 픽스처 ---------------------------------------------------------------
mkdir -p "$WORK/ModA/src/main/resources" "$WORK/ModB/src/main/resources" \
         "$WORK/ModA/src/main/java/pkg" "$WORK/ModB/src/main/java/pkg" \
         "$WORK/Nested/Sub/src/main/resources"

echo "v=1" > "$WORK/ModA/src/main/resources/shared.properties"
echo "v=2" > "$WORK/ModB/src/main/resources/shared.properties"      # 양성: 동일 상대경로 트윈(값은 다름 = 계약 다를 수 있음)
echo "class OnlyA {}" > "$WORK/ModA/src/main/java/pkg/OnlyA.java"    # 음성: ModB 에 대응 없음
: > "$WORK/ModA/pom.xml"                                             # 경계: src/main 밖(모듈 루트)
echo "v=9" > "$WORK/Nested/Sub/src/main/resources/x.properties"      # 경계: 중첩(다단) 모듈 — 판정 밖이어야 함
echo "v=9" > "$WORK/ModB/src/main/resources/x.properties"            # (있으면 가드가 없을 때만 오탐 유발)

total=0
pass=0

# expect_hit=yes/no. yes 일 때 want_path 를 hits 안에서 확인.
check() {
  local name="$1" expect_hit="$2" json="$3" want_path="${4:-}"
  total=$((total + 1))
  out=$(printf '%s' "$json" | "$HOOK" 2>/dev/null)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name — 훅 exit code=$rc (0 이어야 함, fail-open 위반)"
    return
  fi

  if [ "$expect_hit" = "yes" ]; then
    if [ -z "$out" ]; then
      echo "FAIL: $name — 기대=발동, 실제=무출력"
      return
    fi
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      echo "FAIL: $name — 출력이 유효한 JSON 아님: $out"
      return
    fi
    ev=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty')
    ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [ "$ev" != "PostToolUse" ]; then
      echo "FAIL: $name — hookEventName='$ev' (PostToolUse 기대)"
      return
    fi
    case "$ctx" in
      "복제본 존재: "*"— 함께 실측(계약은 다를 수 있다)") ;;
      *) echo "FAIL: $name — additionalContext 형식 불일치: '$ctx'"; return ;;
    esac
    if [ -n "$want_path" ] && ! printf '%s' "$ctx" | grep -qF -- "$want_path"; then
      echo "FAIL: $name — 기대 경로 '$want_path' 가 컨텍스트에 없음: '$ctx'"
      return
    fi
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    if [ -n "$out" ]; then
      echo "FAIL: $name — 기대=무발동, 실제출력='$out'"
      return
    fi
    echo "PASS: $name"
    pass=$((pass + 1))
  fi
}

# 1) 양성 — 다른 모듈에 동일 상대경로 트윈 존재
check "양성: ModA 편집 시 ModB 트윈 검출" yes \
  "$(printf '{"tool_input":{"file_path":"%s/ModA/src/main/resources/shared.properties"}}' "$WORK")" \
  "ModB/src/main/resources/shared.properties"

# 1b) 대칭성 — 반대쪽(ModB) 편집 시에도 ModA 트윈 검출
check "양성: ModB 편집 시 ModA 트윈 검출(대칭)" yes \
  "$(printf '{"tool_input":{"file_path":"%s/ModB/src/main/resources/shared.properties"}}' "$WORK")" \
  "ModA/src/main/resources/shared.properties"

# 2) 음성 — 트윈 없는 파일
check "음성: 트윈 없는 파일" no \
  "$(printf '{"tool_input":{"file_path":"%s/ModA/src/main/java/pkg/OnlyA.java"}}' "$WORK")"

# 3) 경계 — src/main 세그먼트 밖(모듈 루트 pom.xml)
check "경계: src/main 밖 파일" no \
  "$(printf '{"tool_input":{"file_path":"%s/ModA/pom.xml"}}' "$WORK")"

# 4) 경계 — 중첩(다단) 모듈은 판정 밖(ModB 에 동일 sub 파일이 실재해도 미발동)
check "경계: 중첩 모듈은 대상 아님" no \
  "$(printf '{"tool_input":{"file_path":"%s/Nested/Sub/src/main/resources/x.properties"}}' "$WORK")"

# 5) 트러스트 경계 — file_path 없는 입력(malformed stdin) → 조용히 무발동
check "트러스트경계: file_path 없음" no '{"tool_input":{}}'

# 6) 트러스트 경계/우회형 — 존재하지 않는 파일 경로(가짜 file_path) → 무발동
check "트러스트경계: 미존재 파일 경로" no \
  "$(printf '{"tool_input":{"file_path":"%s/ModA/src/main/resources/ghost.properties"}}' "$WORK")"

# 7) 우회형 — git 레포 밖 경로(레포 최상위 바깥) → 무발동
OUTSIDE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/twin-file-reminder-outside.XXXXXX")
mkdir -p "$OUTSIDE_DIR/Mod/src/main/resources"
echo "v=1" > "$OUTSIDE_DIR/Mod/src/main/resources/x.properties"
check "우회형: git 레포 아닌 경로" no \
  "$(printf '{"tool_input":{"file_path":"%s/Mod/src/main/resources/x.properties"}}' "$OUTSIDE_DIR")"
rm -rf "$OUTSIDE_DIR" 2>/dev/null || true

echo "Tests run: $total, Passed: $pass"
[ "$pass" -eq "$total" ]
