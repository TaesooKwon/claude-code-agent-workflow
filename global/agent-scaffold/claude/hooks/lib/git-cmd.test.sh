#!/usr/bin/env bash
# lib/git-cmd.sh 회귀 테스트 — 커밋 명령 탐지(git_has_subcommand)와 인용 스트립(git_strip_quoted) 계약,
# 그리고 같은 lib 디렉터리의 리뷰 지문(review-diff.sh review_diff_hash)이 staged / -a / --amend 를
# 어떻게 가르는지를 고정한다. 이 판정들이 조용히 바뀌면 커밋 게이트가 통째로 무검문이 된다.
# 근거 처분: hook:lib:18 (apply/PLAN.md, 2026-09-17).
#
# 실행: bash {{ROOT}}/.claude/hooks/lib/git-cmd.test.sh
# ⚠️ 검사 대상 명령 문자열은 **이 파일 안에만** 둔다. Bash 도구 명령줄에 그 문구를 직접 적으면
#    그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 호출에 반응할 수 있다 → 항상 `bash <파일>` 로만 돌린다.
#    (이 파일의 경로 'git-cmd.test.sh' 는 git 뒤에 공백이 없어 탐지 정규식에 걸리지 않는다 — 음성 절에서 단언한다.)
#
# 우회 환경변수: 없음. 이 파일은 게이트가 아니라 테스트이고, 검사 대상 lib 도 자체 우회 스위치를 두지 않는다
#   (우회는 lib 를 소비하는 각 가드가 개별로 가진다).
#
# 한계:
#   - 이 테스트는 lib 함수의 **판정**만 본다. 그 판정으로 각 가드가 무엇을 하는지는 그 가드의 테스트 몫이다.
#     다만 stdin JSON 실경로가 살아 있는지는 소비 훅 하나(sql-staging-guard)에만 태워 확인한다
#     (그 훅을 의도적으로 설치하지 않은 레포에선 그 절의 단언만 SKIP — lib 판정 단언은 그대로 돈다).
#   - 셸 문법을 정규식으로 완전히 파싱할 수 없다는 lib 자신의 천장은 그대로다 — 변수 조립 형태는
#     「문서화된 한계」절에서 비감지를 단언한다(기대값을 고정할 뿐 합격 판정이 아니다).
#   - 「관찰」절은 단언하지 않고 현행 동작만 출력한다(합계 제외). 그 판정은 리뷰 단계 몫이다.
#   - 전제 도구(아래 `for t in …` 목록)가 하나라도 없으면 조용히 통과시키지 않고 exit 2 로 끝낸다
#     — 미실행을 초록으로 위장하지 않는다.
set -u

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
for f in git-cmd.sh review-diff.sh; do
  [ -f "$LIB_DIR/$f" ] || { echo "라이브러리 없음: $LIB_DIR/$f"; exit 2; }
done
# shellcheck source=/dev/null
. "$LIB_DIR/git-cmd.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/review-diff.sh"

for t in git jq shasum python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "전제 도구 없음($t) — 테스트를 실행하지 않았다"; exit 2; }
done

SQL_GUARD="$LIB_DIR/../sql-staging-guard.sh"
[ -f "$SQL_GUARD" ] || { echo "소비 훅 없음: $SQL_GUARD — stdin JSON 실경로 절은 SKIP"; SQL_GUARD=""; }

run=0
passed=0
skipped=0
# 임시 저장소 등록부는 **변수가 아니라 파일**에 둔다 — 저장소 생성은 `x=$(_mkrepo)` 형태로 불려
# 서브셸에서 실행되므로 변수에 적으면 부모로 돌아오지 않고 그대로 유실된다(디렉터리가 쌓인다).
REGISTRY=$(mktemp) || { echo "임시 등록부 생성 실패"; exit 2; }

# 이 실행이 만든 것만 지운다: 존재 확인 + 허용 경로 목록(금지 목록 아님)
_cleanup() {
  [ -f "$REGISTRY" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    case "$d" in
      /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$d" ;;
      *) echo "정리 건너뜀(허용 경로 밖): $d" ;;
    esac
  done < "$REGISTRY"
  rm -f "$REGISTRY"
}
trap _cleanup EXIT

_judge() { # $1=기대 $2=실제 $3=설명
  run=$((run + 1))
  if [ "$1" = "$2" ]; then
    passed=$((passed + 1))
    printf 'ok    %-52s [%s]\n' "$3" "$2"
  else
    printf 'FAIL  %-52s 기대=%s 실제=%s\n' "$3" "$1" "$2"
  fi
}

# 실검사형 가드 경로: 명령 원문을 그대로 본다
_detect() { # $1=DETECT|none $2=설명 $3=명령
  local got
  if git_has_subcommand "$3" commit; then got=DETECT; else got=none; fi
  _judge "$1" "$got" "$2"
}

# 넛지형 훅 경로: git_strip_quoted 를 거친 사본을 본다
_detect_stripped() { # $1=DETECT|none $2=설명 $3=명령
  local got stripped
  stripped=$(git_strip_quoted "$3")
  if git_has_subcommand "$stripped" commit; then got=DETECT; else got=none; fi
  _judge "$1" "$got" "$2"
}

_mkrepo() { # 표준출력 = 새 임시 저장소 경로
  local d
  d=$(mktemp -d) || return 1
  printf '%s\n' "$d" >> "$REGISTRY"
  git -C "$d" init -q
  git -C "$d" config user.name app-hook-test
  git -C "$d" config user.email app-hook-test@example.invalid
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.hooksPath /dev/null   # 사용자 전역 훅이 테스트 저장소에 끼어들지 않게
  printf '%s' "$d"
}

echo "== 커밋 탐지 — 양성(우회 형태 포함) =="
_detect DETECT "맨 커밋"                       'git commit'
_detect DETECT "메시지 인자"                   'git commit -m "리뷰 마커 반영"'
_detect DETECT "--amend"                       'git commit --amend --no-edit'
_detect DETECT "묶음 플래그 -am"               'git commit -am "묶음"'
_detect DETECT "우회① -C 경로"                 'git -C /tmp/x commit'
_detect DETECT "우회② --git-dir 공백-값형"     'git --git-dir /tmp/x/.git commit -m m'
_detect DETECT "우회② --git-dir=/--work-tree=" 'git --git-dir=/tmp/x/.git --work-tree=/tmp/x commit'
_detect DETECT "우회③ && 체인"                 'cd /tmp/x && git commit'
_detect DETECT "우회③ ; 체인"                  'git status --short; git commit -a'
_detect DETECT "셸 래핑 sh -c"                 'sh -c "git commit"'
_detect DETECT "절대경로 호출"                 '/usr/bin/git commit'
_detect DETECT "서브셸 괄호"                   '(git commit -m x)'
_detect DETECT "-c k=v 전역옵션"               'git -c user.email=a@b.c commit'
_detect DETECT "환경변수 접두"                 'GIT_EDITOR=true git commit'
_detect DETECT "공백 다중"                     'git    commit'
_detect DETECT "여러 줄 명령(둘째 줄 커밋)"    'cd /tmp/x
git commit -m y'

# 2026-11-06 결함 사냥 G2~G4 — 공백 든 따옴표 옵션 값 · 줄 잇기 · 별칭 회피 역슬래시
_detect DETECT "G2 -c 값에 공백 든 큰따옴표"       'git -c user.name="A B" commit -m y'
_detect DETECT "G2 -C 공백 든 경로"                 'git -C "/x/My Project" commit -m y'
_detect DETECT "G2 --git-dir= 공백 든 경로"         'git --git-dir="/a b/.git" commit'
_detect DETECT "G2 -c 값에 공백 든 작은따옴표"     "git -c user.name='A B' commit -m y"
_detect DETECT "G2 --work-tree 공백-값형 따옴표"    'git --work-tree "/a b" commit'
_detect DETECT "G3 git 과 서브커맨드 사이 줄 잇기"  "$(printf 'git \\\n  commit -m y')"
_detect DETECT "G3 옵션 뒤 줄 잇기"                 "$(printf 'git -C /r \\\n  commit -m y')"
_detect DETECT "G4 \\git(별칭 회피)"                '\git commit -m y'

echo "== 커밋 탐지 — 음성(관여하면 안 된다) =="
_detect none "--grep 값으로만 등장"            'git log --grep=commit --oneline -5'
_detect none "config 키 이름으로만 등장"       'git config commit.template /tmp/x'
_detect none "git 아닌 명령의 commit 단어"     'npm run commit-lint'
_detect none "이 테스트 자신을 돌리는 명령"    'bash {{ROOT}}/.claude/hooks/lib/git-cmd.test.sh'
_detect none "무관한 빌드 명령"                'mvn test -pl {{MODULE_CORE}} -am'

# 2026-11-06 G2~G4 수리의 오탐 대조 — 넓어진 옵션 값 판정이 커밋 아닌 서브커맨드·줄 잇기 뒤 무관 낱말을 삼키지 않는다
_detect none "G2 대조: 공백 든 따옴표 값 뒤 status"  'git -C "/a b" status && echo commit'
_detect none "G2 대조: 따옴표 값 뒤 log -- commit"    'git -c x="a b" log -- commit'
_detect none "G3 대조: git 아닌 줄 잇기"              "$(printf 'echo a \\\nb commit')"

echo "== 문서화된 한계(비감지가 기대값 — 의도적 우회는 못 막는다) =="
_detect none "변수 조립 호출"                  'g=git; $g commit'

echo "== 인용 스트립 계약(git_strip_quoted) =="
_detect_stripped none   "인용문 안에만(큰따옴표)"   'echo "먼저 git commit 을 치세요"'
_detect_stripped none   "인용문 안에만(작은따옴표)" "echo '먼저 git commit 을 치세요'"
_detect_stripped none   "안내문 + 무해한 실명령"    'echo "git commit" && git status'
_detect DETECT          "같은 문자열의 원문 경로"   'echo "먼저 git commit 을 치세요"'
_detect_stripped DETECT "셸 래퍼는 스트립 제외"     'sh -c "git commit"'
_detect_stripped DETECT "셸 래퍼 bash -lc"          'bash -lc "git commit -m x"'
_detect_stripped DETECT "실커밋 + 인용 메시지"      'git commit -m "커밋 메시지"'

echo "== 히어독 판정 계약(git_strip_heredoc — 허용 목록) =="
# 소비 훅의 실경로 = git_strip_quoted(git_strip_heredoc(명령)). 규칙 = **걷어내지 않는 게 기본**이고, 셋 다 만족할 때만
# 본문을 걷어낸다: ⓐ수신 명령이 데이터 싱크 ⓑ히어독 뒤 파이프 하류 없음 ⓒ리다이렉트 대상이 없거나 문서·데이터 확장자.
# (2026-09-18 교차 리뷰 G1 — 종전 금지 목록(인터프리터 예외)은 "쓰고 실행"·"| bash"·ssh 를 놓쳤다.)
# 반증 예고: 허용 목록 도입 전 lib 로 돌리면 P4·P5·P6·P8·P9·P10·P12·P13·P14·N6 의 10건이 빨강,
#   F1 이전 lib(`.bak-20260918-f1`)면 P1~P3·P11 이 더해져 14건이어야 한다(P11 은 그 lib 에 따옴표 마스킹이 없어
#   `"$(cat <<EOF` 의 << 를 히어독으로 보고 본문을 걷어내기 때문 — 리뷰 예고 13건은 이것을 빠뜨렸다, 2026-09-18 실측).
#   그 외 건수면 케이스나 구현이 어긋난 것.
_detect_hd() { # $1=DETECT|none $2=설명 $3=명령
  local got
  if git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$3")")" commit; then got=DETECT; else got=none; fi
  _judge "$1" "$got" "$2"
}
_detect_hdr() { # 차단형 경로 = 히어독 판정만(따옴표 스트립 없음). 인용 안 명령은 넛지형 경로에선 원래 빠진다.
  local got
  if git_has_subcommand "$(git_strip_heredoc "$3")" commit; then got=DETECT; else got=none; fi
  _judge "$1" "$got" "$2"
}
# 양성 — 탐지돼야 한다(본문이 실행되거나, 히어독이 아닌 << 가 다음 줄을 삼키면 안 된다)
_detect_hd DETECT "P1 here-string 다음 줄"            "$(printf 'tr a-z A-Z <<<x\ngit commit -m x')"
_detect_hd DETECT "P2 큰따옴표 안 << 다음 줄"          "$(printf 'grep "a << b" f\ngit commit -m x')"
_detect_hd DETECT "P3 인용된 <<TOKEN 다음 줄"          "$(printf 'echo "see <<NOTE"\ngit commit -m x')"
_detect_hd DETECT "P4 히어독으로 run.sh 쓰고 실행"      "$(printf "cat <<'EOF' > run.sh\ngit commit -m x\nEOF\nbash run.sh")"
_detect_hd DETECT "P5 cat <<EOF | bash"               "$(printf 'cat <<EOF | bash\ngit commit -m x\nEOF')"
_detect_hd DETECT "P6 ssh host <<EOF"                 "$(printf 'ssh host <<EOF\ngit commit -m x\nEOF')"
_detect_hd DETECT "P7 bash <<EOF"                     "$(printf 'bash <<EOF\ngit commit -m x\nEOF')"
_detect_hd DETECT "P8 이스케이프 따옴표 안 << 다음 줄"  "$(printf 'echo "{\\"a\\":\\"<<PH>>\\"}"\ngit commit -m x')"
_detect_hd DETECT "P9 주석 속 << 다음 줄"              "$(printf 'echo hi # see <<TODO>> later\ngit commit -m x')"
_detect_hd DETECT "P10 산술 \$((x<<n)) 다음 줄"         "$(printf 'echo $((x<<n))\ngit commit -m x')"
_detect_hd DETECT "P11 eval \"\$(cat <<EOF …)\""       "$(printf 'eval "$(cat <<EOF\ngit commit -m x\nEOF\n)"')"
_detect_hd DETECT "P12 tee run.sh <<EOF"              "$(printf 'tee run.sh <<EOF\ngit commit -m x\nEOF')"
_detect_hd DETECT "P13 cat <<EOF > run(확장자 없음)"    "$(printf 'cat <<EOF > run\ngit commit -m x\nEOF')"
_detect_hdr DETECT "P14 python3 - <<EOF(차단형 경로)"              "$(printf "python3 - <<EOF\nimport os; os.system('git commit -m x')\nEOF")"
_detect_hd DETECT "P15a 히어독 없는 단독 커밋"          'git commit -m x'
_detect_hd DETECT "P15b sh -c 래핑"                    'sh -c "git commit -m x"'
_detect_hd DETECT "P16 문서 히어독 종료 뒤 실제 커밋"    "$(printf 'cat > a.md <<EOF\n본문\nEOF\ngit commit -m x')"
# 재설계 리뷰 1라운드(2026-09-18) — 반증 예고: 이 절 도입 직전 lib 로 돌리면 P17~P22 의 6건 + N8·N9 의 2건 = 8건 빨강.
_detect_hd DETECT "P17 <<\\EOF 문서 뒤 실제 커밋(R1)"    "$(printf 'cat > a.md <<\\EOF\n본문\nEOF\ngit commit -m x')"
_detect_hd DETECT "P18 <<EOF-1 문서 뒤 실제 커밋(R2)"    "$(printf 'cat <<EOF-1 > a.md\n본문\nEOF-1\ngit commit -m x')"
_detect_hd DETECT "P19 줄끝 \\ 이어 | bash(R3)"          "$(printf 'cat <<EOF \\\n| bash\ngit commit -m x\nEOF')"
_detect_hd DETECT "P20 { cat <<EOF; } | bash(R3)"        "$(printf '{ cat <<EOF; } | bash\ngit commit -m x\nEOF')"
_detect_hd DETECT "P21 ( cat <<EOF … ) | bash(R3)"       "$(printf '( cat <<EOF\ngit commit -m x\nEOF\n) | bash')"
_detect_hd DETECT "P22 맨 \$(cat <<EOF …) = 출력 실행"    "$(printf '$(cat <<EOF\ngit commit -m x\nEOF\n)')"
_detect_hd DETECT "P23 cat <<EOF >&3(모르는 fd)"         "$(printf 'cat <<EOF >&3\ngit commit -m x\nEOF')"   # R6 수리가 한때 흘렸다
# 재설계 리뷰 2라운드 — 반증 예고: 이 두 줄 도입 직전 lib 면 P24·N10 의 2건 빨강.
_detect_hd DETECT "P24 <<E\\OF(토큰 중간 백슬래시) 뒤 커밋" "$(printf 'cat > a.md <<E\\OF\n본문\nEOF\ngit commit -m x')"
# 킷 가드 v2(2026-11-11) — 구분자 순수형 4종만 인정, 섞인 형태가 하나라도 있으면 어떤 본문도 걷지 않는다.
# 반증 예고: 순수형 검사(PURE·nx)를 빼면 P25·P26 은 종전처럼 종료 줄을 못 찾아 뒤 줄 커밋까지 삼켜 none, P27 은 첫 본문을 걷어 none — 3건 빨강.
_detect_hd DETECT "P25 <<\"E\"OF(섞인 인용) 뒤 커밋"     "$(printf 'cat > a.md <<"E"OF\n본문\nEOF\ngit commit -m x')"
_detect_hd DETECT "P26 <<E\"OF\"(섞인 인용) 뒤 커밋"     "$(printf 'cat > a.md <<E"OF"\n본문\nEOF\ngit commit -m x')"
_detect_hd DETECT "P27 순수형 문서 본문 + 섞인 구분자 = 전부 남김" "$(printf 'cat > a.md <<EOF\ngit commit -m x\nEOF\ncat > b.md <<"E"OF\ny\nEOF')"
_detect_hd none   "N13 순수형 4종(EOF·'EOF'·\"EOF\"·\\\\EOF) 문서 본문" "$(printf "cat > a.md <<EOF\ngit commit -m a\nEOF\ncat > b.md <<'EOF'\ngit commit -m b\nEOF\ncat > c.md <<\"EOF\"\ngit commit -m c\nEOF\ncat > d.md <<\\\\EOF\ngit commit -m d\nEOF")"
# 음성 — 미탐이어야 한다(데이터 싱크가 문서·데이터로 쓰기만 하는 본문 = 오탐 해소)
_detect_hd none   "N1 cat > a.md <<EOF"               "$(printf 'cat > a.md <<EOF\ngit commit -m x\nEOF')"
_detect_hd none   "N2 cat <<'EOF' >> docs/x.md"       "$(printf "cat <<'EOF' >> docs/x.md\ngit commit -m x\nEOF")"
_detect_hd none   "N3 tee notes.txt <<EOF"            "$(printf 'tee notes.txt <<EOF\ngit commit -m x\nEOF')"
_detect_hd none   "N4a jq . <<EOF"                    "$(printf 'jq . <<EOF\ngit commit -m x\nEOF')"
_detect_hd none   "N4b grep -c x <<EOF"               "$(printf 'grep -c x <<EOF\ngit commit -m x\nEOF')"
_detect_hd none   "N5 cat <<-'EOF' 탭 들여쓰기"        "$(printf "cat <<-'EOF'\n\tgit commit -m x\n\tEOF")"
_detect_hd none   "N6 한 줄 히어독 2개(cat <<A; cat <<B)" "$(printf 'cat <<A; cat <<B\ngit commit -m x\nA\ngit commit -m x\nB')"
_detect_hd none   "N7 x=\$(cat <<EOF …)"               "$(printf 'x=$(cat <<EOF\ngit commit -m x\nEOF\n)')"
_detect_hd none   "N8 cat <<EOF > a.md 2>&1(R6)"      "$(printf 'cat <<EOF > a.md 2>&1\ngit commit -m x\nEOF')"
_detect_hd none   "N10 본문 속 들여쓴 '  EOF' 는 종료 아님"   "$(printf 'cat > a.md <<EOF\n예시:\n  EOF\ngit commit -m x\nEOF')"
_detect_hd none   "N9 따옴표로 감싼 문서 경로(R5)""$(printf 'cat > "docs/한글 문서.md" <<'"'"'EOF'"'"'\ngit commit -m x\nEOF')"
# 문서화된 한계(fail-closed 오탐 — 기대값을 고정할 뿐 합격 판정이 아니다): 하류가 싱크여도 파이프면 남긴다 ·
#   변수 대상은 판정 불가라 남긴다 · 줄을 넘긴 $(( 는 짝을 못 찾아 그 뒤를 가린다.
_detect_hd DETECT "L1 cat <<EOF | tee x.md(한계 R7)"  "$(printf 'cat <<EOF | tee x.md\ngit commit -m x\nEOF')"
_detect_hd DETECT "L2 cat > \$OUT <<EOF(한계 R8)"      "$(printf 'cat > $OUT <<EOF\ngit commit -m x\nEOF')"

echo "== 리뷰 지문 계약(review_diff_hash — staged / -a / --amend) =="
REPO=$(_mkrepo)
printf 'base\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m base
printf 'staged\n' >> "$REPO/a.txt"     # 인덱스에 올릴 변경
git -C "$REPO" add a.txt
printf 'worktree\n' > "$REPO/b.txt"    # 인덱스에 없는 워킹트리 변경
git -C "$REPO" add -N b.txt

h_staged=$(review_diff_hash "$REPO" 'git commit -m x'); rc_staged=$?
h_default=$(review_diff_hash "$REPO" '')
h_all=$(review_diff_hash "$REPO" 'git commit -a -m x')
h_am=$(review_diff_hash "$REPO" 'git commit -am x')
h_amend=$(review_diff_hash "$REPO" 'git commit --amend --no-edit')

_judge 0 "$rc_staged" "staged 지문 rc"
[ -n "$h_staged" ] && v=yes || v=no
_judge yes "$v" "staged 지문 산출됨"
[ "$h_staged" != "$h_all" ] && v=different || v=same
_judge different "$v" "-a 는 워킹트리까지 포함(staged 와 다름)"
[ "$h_am" = "$h_all" ] && v=same || v=different
_judge same "$v" "-am 은 -a 와 같은 지문"
[ "$h_amend" = "$h_staged" ] && v=same || v=different
_judge same "$v" "--amend 단독은 인덱스만(staged 와 같음)"
[ "$h_default" = "$h_staged" ] && v=same || v=different
_judge same "$v" "명령 미지정 기본 = 인덱스"

CLEAN=$(_mkrepo)
review_diff_hash "$CLEAN" '' >/dev/null; _judge 2 "$?" "변경 없음 → rc 2"
NOREPO=$(mktemp -d); printf '%s\n' "$NOREPO" >> "$REGISTRY"
review_diff_hash "$NOREPO" '' >/dev/null; _judge 1 "$?" "git 저장소 아님 → rc 1"

echo "== stdin JSON 실경로(소비 훅 = sql-staging-guard) =="
SQLREPO=$(_mkrepo)
printf 'seed\n' > "$SQLREPO/readme.txt"
git -C "$SQLREPO" add readme.txt
git -C "$SQLREPO" commit -q -m base
printf 'ALTER TABLE tn_x ADD COLUMN y INT;\n' > "$SQLREPO/draft_20260917.sql"
git -C "$SQLREPO" add draft_20260917.sql

_payload() { # $1=명령 $2=cwd → PreToolUse(Bash) stdin JSON
  python3 -c 'import json,sys
print(json.dumps({"session_id":"test","cwd":sys.argv[2],"hook_event_name":"PreToolUse",
                  "tool_name":"Bash","tool_input":{"command":sys.argv[1]}}, ensure_ascii=False))' "$1" "$2"
}
_hook_decision() { # $1=명령 $2=cwd
  local out
  out=$(_payload "$1" "$2" | bash "$SQL_GUARD" 2>/dev/null)
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "?parse-error"'
}

if [ -n "$SQL_GUARD" ]; then
_judge deny  "$(_hook_decision 'git commit -m "초안"' "$SQLREPO")"        "신규 .sql 스테이징 + 커밋 → deny"
_judge deny  "$(_hook_decision 'sh -c "git commit -m x"' "$SQLREPO")"     "우회형(셸 래핑)도 같은 판정"
_judge allow "$(_hook_decision 'git status --short' "$SQLREPO")"          "커밋 아닌 명령은 무관여"
else skipped=$((skipped + 3)); echo "SKIP  stdin JSON 실경로 3건 — 소비 훅(sql-staging-guard) 부재"; fi

echo
echo "== 관찰(단언 아님 — 합계 제외, 판정은 리뷰 단계 몫) =="
_observe() { # $1=설명 $2=명령
  local raw stripped
  if git_has_subcommand "$2" commit; then raw=DETECT; else raw=none; fi
  stripped=$(git_strip_quoted "$2")
  if git_has_subcommand "$stripped" commit; then stripped=DETECT; else stripped=none; fi
  printf '관찰  %-52s 원문=%-6s 스트립=%s\n' "$1" "$raw" "$stripped"
}
_observe "commit-graph(커밋 생성 아님)"        'git commit-graph write'
_observe "eval 래핑(래퍼 목록 밖)"             'eval "git commit -m x"'
_observe "원격 실행 ssh"                       'ssh host "git commit"'
h_msgdash=$(review_diff_hash "$REPO" 'git commit -m "flag -a 를 제거"')
[ "$h_msgdash" = "$h_all" ] && echo "관찰  메시지 속 -a 토큰 → -a 와 같은 지문(워킹트리 포함)" \
                            || echo "관찰  메시지 속 -a 토큰 → 인덱스만"

# 2026-11-06 선형 줄 잇기 펴기(git_unfold_lines) — 종전 ${s//$'\\\n'/ } 와 바이트 동일(경계) · 줄 잇기 있을 때만 sed 1회 · sed 없으면 종전 치환
if command -v git_unfold_lines >/dev/null 2>&1; then
  for _in in "" "a" $'\n' $'\\' $'\\\n' $'\\\n\n' $'\\\\\n' $'\\\\\\\n' $'a\\\n\\\nb' $'a\\\n' $'x\\' $'a\n\nb\n\n' $'\r\\\n' $'\\\r\n' $'\xff\\\n\xc3' $'\xea\xb0\x80\\\n'; do
    _exp=${_in//$'\\\n'/ }; git_unfold_lines "$_in"; _judge "$(printf %q "$_exp")" "$(printf %q "$_GIT_UNFOLDED")" "선형 펴기 = 종전 치환 $(printf %q "$_in")"
  done
  PATH=/nonexistent git_unfold_lines "$(printf 'a \\\nb')"
  _judge "a  b" "$_GIT_UNFOLDED" "선형 펴기: sed 없으면 종전 치환으로 폴백"
else
  _judge 정의됨 없음 "git_unfold_lines 정의(선형 펴기)"
fi
_lsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-sed.XXXXXX") || exit 2
echo "$_lsh" >> "$REGISTRY"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log"\nexec /usr/bin/sed "$@"\n' "$_lsh" > "$_lsh/sed"; chmod +x "$_lsh/sed"; : > "$_lsh/log"
_unf_used() { grep -qF 'H;${x;s/' "$_lsh/log" && echo yes || echo no; }   # 선형 펴기 sed 스크립트가 불렸는가
PATH="$_lsh:$PATH" git_has_subcommand "$(printf 'git \\\n  commit -m y')" commit; _judge 0 "$?" "선형 펴기: 줄 잇기 커밋 탐지"
_judge yes "$(_unf_used)" "선형 펴기: 줄 잇기 있으면 sed 1회 경로"
: > "$_lsh/log"; PATH="$_lsh:$PATH" git_has_subcommand 'git commit -m y' commit
_judge no "$(_unf_used)" "선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"

# 2026-11-06 r2 리뷰 — sed 결과 '채택'(센티널 있음)·'감지'(센티널 없음 → 종전 치환)·호출 1회를 가짜 sed 로 고정
if command -v git_unfold_lines >/dev/null 2>&1; then
  _fsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-fake.XXXXXX") || exit 2
  cat > "$_fsh/sed" <<'SHIM'
#!/bin/bash
# 가짜 sed — 선형 펴기 스크립트(H;${x;s/…)만 가로챈다: mode=adopt → payload+센티널 x, nosent → payload(센티널 없음, rc 0). 그 밖은 진짜 sed.
d=$(dirname "$0"); printf '%s\n' "$*" >> "$d/log"
case "$*" in *'H;${x;s/'*)
  m=$(cat "$d/mode" 2>/dev/null)
  if [ "$m" = adopt ]; then cat >/dev/null; printf '%sx\n' "$(cat "$d/payload")"; exit 0; fi
  if [ "$m" = nosent ]; then cat >/dev/null; printf '%s\n' "$(cat "$d/payload")"; exit 0; fi ;;
esac
exec /usr/bin/sed "$@"
SHIM
  chmod +x "$_fsh/sed"
  _fake() { printf '%s' "$1" > "$_fsh/mode"; printf '%s' "$2" > "$_fsh/payload"; : > "$_fsh/log"; }
  _fake_n() { grep -cF 'H;${x;s/' "$_fsh/log"; }   # 선형 펴기 sed 호출 수
  echo "$_fsh" >> "$REGISTRY"
  _fake adopt SEDOUT; PATH="$_fsh:$PATH" git_unfold_lines "$(printf 'a\\\nb')"
  _judge SEDOUT "$_GIT_UNFOLDED" "r2 펴기: 센티널 있는 sed 출력을 채택"
  _judge 1 "$(_fake_n)" "r2 펴기: sed 호출 1회"
  _fake nosent SEDOUT; PATH="$_fsh:$PATH" git_unfold_lines "$(printf 'a\\\nb')"
  _judge "a b" "$_GIT_UNFOLDED" "r2 펴기: 센티널 없으면 종전 치환(감지)"
else
  _judge 정의됨 없음 "r2 펴기: git_unfold_lines 정의"
fi

echo
if [ "$skipped" -gt 0 ]; then echo "Tests run: $run, Passed: $passed, Skipped: $skipped(의존 훅 부재)"
else echo "Tests run: $run, Passed: $passed"; fi
[ "$run" -gt 0 ] || { echo "실행된 단언 0 — 대상 훅이 모두 부재(통과가 아니다)"; exit 2; }
[ "$run" -eq "$passed" ] || exit 1
