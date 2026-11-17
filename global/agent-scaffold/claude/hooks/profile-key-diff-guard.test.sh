#!/usr/bin/env bash
# profile-key-diff-guard.sh 자체검사(근거 처분 project:프로젝트설정:7).
# 실행: bash .claude/hooks/profile-key-diff-guard.test.sh
#
# 샌드박스 git 레포를 mktemp 로 만들어 실물 훅에 stdin JSON 을 먹인다. 이 레포의 실제
# application*.properties 는 건드리지 않는다(CLAUDE_PROJECT_DIR 을 샌드박스로 덮어쓴다).
# 정리는 trap EXIT.
# ※ 커밋 명령 문자열은 이 파일 안에만 둔다 — Bash 도구 명령줄에 직접 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
set -u

HOOKS_DIR="{{ROOT}}/.claude/hooks"
# GUARD 환경변수로 검사 대상 훅을 바꿀 수 있다(변이 반증용 사본).
GUARD="${GUARD:-$HOOKS_DIR/profile-key-diff-guard.sh}"

for f in "$GUARD" "$HOOKS_DIR/lib/git-cmd.sh"; do
  [ -f "$f" ] || { echo "선행조건 실패: $f 없음"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/profile-key-diff-guard-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# 검사 대상 훅의 PROD_PROFILE_FILE 줄 값만 바꾼 사본(lib 함께 — 훅이 dirname 기준으로 읽는다). 값은 환경변수로 넘긴다.
# 설치 레포가 그 값을 바꿔도(예: application-prod.properties) 같은 테스트가 통과하도록, 기본값(.sample)을 전제로 하는
# 케이스까지 전부 기본값을 **명시한** 사본으로 돈다 — 설치값을 그대로 쓰는 케이스는 두지 않는다.
SRC_GUARD=$GUARD
pvariant() { # 이름 값(따옴표 포함 셸 리터럴) → 사본 경로
  local d="$SANDBOX/pv-$1"; mkdir -p "$d/lib"
  cp "$HOOKS_DIR/lib/git-cmd.sh" "$d/lib/"
  grep -q '^PROD_PROFILE_FILE=' "$SRC_GUARD" || { echo "선행조건 실패: 훅에 PROD_PROFILE_FILE 줄 없음" >&2; exit 1; }
  V="$2" awk 'index($0, "PROD_PROFILE_FILE=") == 1 && !done { print "PROD_PROFILE_FILE=" ENVIRON["V"]; done = 1; next } { print }' \
    "$SRC_GUARD" > "$d/profile-key-diff-guard.sh"
  printf '%s' "$d/profile-key-diff-guard.sh"
}
GUARD=$(pvariant default "'application-prod.properties.sample'") || exit 1

COMMIT_CMD='git commit -m "chore: 샌드박스 커밋(실행되지 않음)"'
BYPASS_CMD="ALLOW_PROFILE_KEY_DIFF=1 $COMMIT_CMD"

run=0; pass=0

assert_eq() { # 설명 기대 실제
  run=$((run + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s\n        기대: [%s]\n        실제: [%s]\n' "$1" "$2" "$3"
  fi
}

mkrepo() { # 번호 → 레포 경로(초기 커밋까지)
  r="$SANDBOX/repo$1"
  mkdir -p "$r/{{MODULE_ADMIN}}/src/main/resources" "$r/{{MODULE_FRONT}}/src/main/resources"
  git -C "$r" init -q >/dev/null 2>&1
  git -C "$r" config user.email "t@example.com"
  git -C "$r" config user.name "t"
  : > "$r/.gitignore"
  git -C "$r" add .gitignore >/dev/null 2>&1
  git -C "$r" commit -q -m init >/dev/null 2>&1
  printf '%s' "$r"
}

# 모듈 4파일을 "정합" 상태로 채운다. base 의 Globals.mariadb.Url 은 일부러 '#키=' 주석 자리만
# 둔다 — 주석 처리된 키도 "자리 있음"으로 인정되는지를 이 상태 자체가 검증한다.
write_parity() { # repo module
  local dir="$1/$2/src/main/resources"
  cat > "$dir/application.properties" <<'EOF'
spring.application.name=X
Globals.jwt.secret=
#Globals.mariadb.Url=
EOF
  cat > "$dir/application-dev.properties" <<'EOF'
spring.application.name=X
Globals.jwt.secret=devsecret
Globals.mariadb.Url=jdbc:dev
EOF
  cat > "$dir/application-prod.properties.sample" <<'EOF'
spring.application.name=X
Globals.jwt.secret=prodsecret
Globals.mariadb.Url=jdbc:prod
EOF
  cat > "$dir/application-local.properties" <<'EOF'
spring.application.name=X
Globals.jwt.secret=localsecret
Globals.mariadb.Url=jdbc:local
EOF
}

break_parity() { # repo module — dev 파일에만 있는 여분 키 하나 추가(차집합 유발)
  printf 'Globals.extraOnly=1\n' >> "$1/$2/src/main/resources/application-dev.properties"
}

stage_all() { # repo module
  git -C "$1" add "$2/src/main/resources" >/dev/null 2>&1
}

pre_json() { jq -n --arg c "$1" --arg d "$2" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

post_json() { jq -n --arg d "$1" --arg fp "$2" \
  '{hook_event_name:"PostToolUse",tool_name:"Edit",cwd:$d,tool_input:{file_path:$fp}}'; }

gate() { # cmd repo → permissionDecision(없으면 none)
  o=$(pre_json "$1" "$2" | CLAUDE_PROJECT_DIR="$2" bash "$GUARD" 2>/dev/null)
  if [ -z "$o" ]; then printf 'none'; else
    printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || printf 'parse-error'
  fi
}

gate_ctx() { # cmd repo → PreToolUse additionalContext 유무("yes"/"no")
  o=$(pre_json "$1" "$2" | CLAUDE_PROJECT_DIR="$2" bash "$GUARD" 2>/dev/null)
  c=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  [ -n "$c" ] && printf 'yes' || printf 'no'
}

warn() { # repo file_path(절대) → additionalContext 유무("yes"/"no")
  o=$(post_json "$1" "$2" | CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>/dev/null)
  if [ -z "$o" ]; then printf 'no'; else
    c=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    [ -n "$c" ] && printf 'yes' || printf 'no'
  fi
}

echo "── PreToolUse(커밋) ────────────────────────────────"

# T1 음성: 4파일 키 정합(base 는 주석 자리) → 통과
r=$(mkrepo t1); write_parity "$r" {{MODULE_ADMIN}}; write_parity "$r" {{MODULE_FRONT}}; stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T1 음성: 4파일 키 정합(주석 자리 인정) → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# T2 양성: dev 전용 키 하나 → 기본 모드(warn)에선 차단하지 않고 경고(additionalContext)
r=$(mkrepo t2); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}; stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T2 양성(warn 기본): dev 전용 키 → 차단 없음" "none" "$(gate "$COMMIT_CMD" "$r")"
assert_eq "T2a 양성(warn 기본): dev 전용 키 → 경고 발생" "yes" "$(gate_ctx "$COMMIT_CMD" "$r")"

# T2b: 경고 본문에 문제의 키 이름이 등장하는가
o=$(pre_json "$COMMIT_CMD" "$r" | CLAUDE_PROJECT_DIR="$r" bash "$GUARD" 2>/dev/null)
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
case "$reason" in *Globals.extraOnly*) t2b=yes ;; *) t2b=no ;; esac
assert_eq "T2b: 경고 본문에 누락 키 이름(Globals.extraOnly) 포함" "yes" "$t2b"

# T2c 양성(deny 모드): PROFILE_KEY_DIFF_MODE=deny 면 차단
assert_eq "T2c 양성(deny 모드): dev 전용 키 → deny" "deny" "$(PROFILE_KEY_DIFF_MODE=deny gate "$COMMIT_CMD" "$r")"

# T2d base 제외: base 에만 있는 키는 기본 비교 집합 밖 → 경고 없음 / INCLUDE_BASE=1 이면 경고
r=$(mkrepo t2d); write_parity "$r" {{MODULE_ADMIN}}
printf 'spring.only.in.base=1\n' >> "$r/{{MODULE_ADMIN}}/src/main/resources/application.properties"; stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T2d base 전용 키(기본 제외) → 경고 없음" "no" "$(gate_ctx "$COMMIT_CMD" "$r")"
assert_eq "T2e base 전용 키(INCLUDE_BASE=1) → 경고" "yes" "$(PROFILE_KEY_DIFF_INCLUDE_BASE=1 gate_ctx "$COMMIT_CMD" "$r")"

# T3 우회: ALLOW_PROFILE_KEY_DIFF=1 → 통과
r=$(mkrepo t3); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}; stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T3 우회: ALLOW_PROFILE_KEY_DIFF=1 → 통과" "none" "$(gate "$BYPASS_CMD" "$r")"

# T4 음성: 커밋 명령이 아님(git status) → 통과(불일치 있어도)
r=$(mkrepo t4); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}; stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T4 음성: 커밋 아닌 명령 → 통과" "none" "$(gate 'git status --short' "$r")"

# T5 음성: 불일치는 있지만 대상 파일이 스테이징 안 됨(문서만 스테이징) → 통과
r=$(mkrepo t5); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}
printf '# doc\n' > "$r/README.md"; git -C "$r" add README.md >/dev/null 2>&1
assert_eq "T5 음성: 대상 파일 미스테이징(문서만) → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# T6 모듈 스코프: Front 는 불일치, Admin 은 정합 — Admin 만 스테이징하면 통과해야 한다
r=$(mkrepo t6); write_parity "$r" {{MODULE_ADMIN}}; write_parity "$r" {{MODULE_FRONT}}; break_parity "$r" {{MODULE_FRONT}}
stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T6 모듈 스코프: 불일치 모듈(Front) 미스테이징 → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# T6b: 반대로 Front(불일치 모듈)를 스테이징하면 deny
git -C "$r" reset -q >/dev/null 2>&1
stage_all "$r" {{MODULE_FRONT}}
assert_eq "T6b 모듈 스코프: 불일치 모듈(Front) 스테이징 → 경고" "yes" "$(gate_ctx "$COMMIT_CMD" "$r")"

# T7 음성: local 파일이 없어도(미추적 환경) 나머지 3파일이 정합이면 통과
r=$(mkrepo t7); write_parity "$r" {{MODULE_ADMIN}}
rm -f "$r/{{MODULE_ADMIN}}/src/main/resources/application-local.properties"
stage_all "$r" {{MODULE_ADMIN}}
assert_eq "T7 음성: local 파일 부재(3파일만 정합) → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

echo "── PostToolUse(편집) ───────────────────────────────"

# T8 양성: 불일치 상태에서 dev 파일을 편집 → warn(additionalContext) 발생
r=$(mkrepo t8); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}
assert_eq "T8 양성: 편집 직후 불일치 → warn 발생" "yes" \
  "$(warn "$r" "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties")"

# T8b: T8 출력이 deny 가 아니라 additionalContext 인지(PostToolUse 는 permissionDecision 없음)
o=$(post_json "$r" "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties" | CLAUDE_PROJECT_DIR="$r" bash "$GUARD" 2>/dev/null)
pd=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
assert_eq "T8b: PostToolUse 는 permissionDecision 을 내지 않는다" "none" "$pd"

# T9 음성: 정합 상태에서 편집 → warn 없음
r=$(mkrepo t9); write_parity "$r" {{MODULE_ADMIN}}
assert_eq "T9 음성: 정합 상태 편집 → warn 없음" "no" \
  "$(warn "$r" "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties")"

# T10 음성: 허용목록 밖 파일명(.bak) → 관여 안 함(허용목록 방식 확인)
r=$(mkrepo t10); write_parity "$r" {{MODULE_ADMIN}}
cp "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties" \
   "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties.bak"
assert_eq "T10 음성: 허용목록 밖 파일명(.bak) → 관여 안 함" "no" \
  "$(warn "$r" "$r/{{MODULE_ADMIN}}/src/main/resources/application-dev.properties.bak")"

echo "── 하위 디렉터리 cwd(레포 루트 기준 경로) ──────────"

# T11 양성: 커밋을 하위 디렉터리에서 쳐도 비교가 살아 있어야 한다.
# 회귀 근거: 모듈 경로를 cwd 로 조합해 하위 디렉터리에서는 비교 대상이 2개 미만이 되어 조용히 통과했다
# (2026-09-18 실측: cwd=<repo>/docs/... 에서 무출력 allow).
r=$(mkrepo t11); write_parity "$r" {{MODULE_ADMIN}}; break_parity "$r" {{MODULE_ADMIN}}; stage_all "$r" {{MODULE_ADMIN}}
mkdir -p "$r/docs/deep/dir"
assert_eq "T11 전제: 루트 cwd 에서는 경고 발생" "yes" "$(gate_ctx "$COMMIT_CMD" "$r")"
o=$(pre_json "$COMMIT_CMD" "$r/docs/deep/dir" | CLAUDE_PROJECT_DIR="$r" bash "$GUARD" 2>/dev/null)
c=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_eq "T11 양성: 하위 디렉터리 cwd 에서도 경고 발생" "yes" "$([ -n "$c" ] && printf 'yes' || printf 'no')"
o=$(pre_json "$COMMIT_CMD" "$r/docs/deep/dir" | CLAUDE_PROJECT_DIR="$r" PROFILE_KEY_DIFF_MODE=deny bash "$GUARD" 2>/dev/null)
d=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
assert_eq "T11b 양성: 하위 cwd + deny 모드 → deny" "deny" "${d:-none}"

echo "── prod 파일 이름 변수(PROD_PROFILE_FILE) ──────────"
# pvariant() 는 위(SANDBOX 생성 직후)에 정의돼 있다 — 모든 케이스가 값을 명시한 사본으로 돈다.
MOD=$(sed -n 's/^MODULES="\([^ "]*\).*/\1/p' "$GUARD")   # 훅이 보는 첫 모듈(설치 레포 값 그대로)
PLAIN=$(pvariant plain "'application-prod.properties'") || exit 1
EMPTYP=$(pvariant empty "''") || exit 1
ORIG_GUARD=$GUARD
# prod 를 .sample 없이 둔 레포: write_parity 후 이름을 바꾸고 prod 에만 키를 더한다(dev·local 은 서로 정합).
mkplain() { # 번호 → 레포
  local r; r=$(mkrepo "$1"); write_parity "$r" "$MOD"
  local d="$r/$MOD/src/main/resources"
  mv "$d/application-prod.properties.sample" "$d/application-prod.properties"
  printf 'Globals.prodOnly=1\n' >> "$d/application-prod.properties"
  printf '%s' "$r"
}

r=$(mkplain t12); stage_all "$r" "$MOD"
GUARD=$PLAIN; assert_eq "T12 변수=application-prod.properties: prod 전용 키 → 커밋 경고(비교에 포함)" "yes" "$(gate_ctx "$COMMIT_CMD" "$r")"; GUARD=$ORIG_GUARD
assert_eq "T12b 대조: 기본값(.sample)이면 prod 파일을 안 봐서 경고 없음" "no" "$(gate_ctx "$COMMIT_CMD" "$r")"

r=$(mkplain t13)
GUARD=$PLAIN; assert_eq "T13 변수=application-prod.properties: prod 편집 → warn 발화" "yes" \
  "$(warn "$r" "$r/$MOD/src/main/resources/application-prod.properties")"; GUARD=$ORIG_GUARD
assert_eq "T13b 대조: 기본값이면 prod 편집은 조용히 통과" "no" "$(warn "$r" "$r/$MOD/src/main/resources/application-prod.properties")"

# 빈 값 → 기본값(.sample) 판정이어야 한다: .sample 에만 키를 더하고 .sample 을 편집하면 warn.
r=$(mkrepo t14); write_parity "$r" "$MOD"; printf 'Globals.sampleOnly=1\n' >> "$r/$MOD/src/main/resources/application-prod.properties.sample"
GUARD=$EMPTYP; assert_eq "T14 변수 빈 값 → 기본값(.sample)으로 비교·발화" "yes" \
  "$(warn "$r" "$r/$MOD/src/main/resources/application-prod.properties.sample")"; GUARD=$ORIG_GUARD

# 값(시크릿) 비출력 계약: 경고 본문엔 키 이름만 — write_parity 의 값 문자열이 하나도 없어야 한다.
r=$(mkrepo t15); write_parity "$r" "$MOD"; break_parity "$r" "$MOD"; stage_all "$r" "$MOD"
o=$(pre_json "$COMMIT_CMD" "$r" | CLAUDE_PROJECT_DIR="$r" bash "$GUARD" 2>/dev/null)
o2=$(post_json "$r" "$r/$MOD/src/main/resources/application-dev.properties" | CLAUDE_PROJECT_DIR="$r" bash "$GUARD" 2>/dev/null)
assert_eq "T15 전제: 커밋·편집 경고가 실제로 났다" "yes yes" \
  "$([ -n "$o" ] && echo yes || echo no) $([ -n "$o2" ] && echo yes || echo no)"
assert_eq "T15 값(시크릿) 비출력: devsecret·prodsecret·localsecret·jdbc: 0건" "0" \
  "$(printf '%s\n%s' "$o" "$o2" | grep -cE 'devsecret|prodsecret|localsecret|jdbc:')"

echo
printf 'Tests run: %d, Passed: %d\n' "$run" "$pass"
[ "$run" -gt 0 ] || exit 1
[ "$run" -eq "$pass" ]
