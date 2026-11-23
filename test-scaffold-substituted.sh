#!/usr/bin/env bash
# 킷 스캐폴드 시험을 "설치된 모양"(플레이스홀더 토큰을 치환한 사본)으로 돌린다.
#   목적: 스캐폴드 훅·시험은 설치 때 토큰이 치환되는 것을 전제로 짜여 있어, 킷 작업 트리에서 그대로 돌리면
#         토큰 모양(중괄호) 때문에 설치본과 다른 판정이 나온다. 여기서는 추적 파일만 임시 사본으로 옮겨 치환한 뒤 돌린다.
#   사용: bash test-scaffold-substituted.sh        (시험별 제한 시간 = SCAFFOLD_TEST_TIMEOUT 초, 기본 300)
#   판정: 시험마다 rc 0 이고, 출력의 마지막 `Tests run:` 줄에서 run > 0 · Passed == run · Skipped 가 있으면 0 → PASS.
#         그 밖(요약 줄 없음·시간 초과 포함)은 FAIL. 하나라도 FAIL 이면 exit 1, 전부 PASS 면 0, 준비 단계 실패는 exit 2.
#   치환: {{ROOT}} → 사본 프로젝트 루트, 그 밖의 {{[A-Z_]+}} → tok-<이름>. 치환 뒤 그 꼴이 남으면 exit 2.
#   출력의 임시 경로는 <d>, 홈 경로는 ~ 로 가린다.
# ponytail: 토큰 값이 한 벌(tok-X)이라 실제 값 모양(숫자 포트·다단 패키지)에 따른 결함은 못 잡는다 / 업그레이드 = 실제 모양 값 묶음으로 한 번 더 돌린다.
# ponytail: lib/git-cmd.test.sh 의 인자 없는 mktemp 는 TMPDIR 를 따르지 않아 사본 밖(시스템 임시)에 쓴다 — 그 정리는 그 시험의 trap 몫 /
#           업그레이드 = 그 시험의 mktemp 를 TMPDIR 기준 템플릿으로(별도 커밋).
set -u
KIT=$(cd "$(dirname "$0")" && pwd) || exit 2
d=$(mktemp -d "${TMPDIR:-/tmp}/scaffold-sub.XXXXXX") || exit 2
trap 'rm -rf "$d"' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # 정리(EXIT 트랩) 뒤 비정상 종료
d=$(cd "$d" && pwd -P) || exit 2
# 치환 값이 시험의 따옴표 문자열에 들어간다 — 경로 문자를 허용 목록으로 묶는다.
printf '%s' "$d" | grep -Eq '^[A-Za-z0-9._/-]+$' || { echo "임시 경로 문자 허용 밖 — 실행하지 않았다"; exit 2; }
# 사본이 git 작업 트리 안이면 시험의 git 조작이 그 레포로 샐 수 있다.
if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then echo "임시 경로가 git 작업 트리 안 — 실행하지 않았다"; exit 2; fi

P="$d/proj"; C="$P/.claude"; SRC=global/agent-scaffold/claude
mkdir -p "$C" "$d/tmp" || exit 2
n=0
while IFS= read -r -d '' f; do
  rel=${f#"$SRC"/}
  mkdir -p "$C/$(dirname "$rel")" && cp -p "$KIT/$f" "$C/$rel" || { echo "복사 실패: $rel"; exit 2; }
  n=$((n + 1))
done < <(git -C "$KIT" ls-files -z "$SRC")   # 목록이 비면 아래 n 검사가 멈춘다
[ "$n" -gt 0 ] || { echo "복사할 추적 파일 없음 — 실행하지 않았다"; exit 2; }

# 치환(perl -pi — BSD/GNU 공통, 권한 유지). 값은 env 로 넘겨 정규식 이스케이프를 피한다.
grep -rlE '\{\{[A-Z_]+\}\}' "$C" > "$d/subst.list"; [ $? -le 1 ] || exit 2
while IFS= read -r f; do
  R="$P" perl -pi -e 's/\{\{ROOT\}\}/$ENV{R}/g; s/\{\{([A-Z_]+)\}\}/tok-$1/g' "$f" || { echo "치환 실패: ${f#"$C"/}"; exit 2; }
done < "$d/subst.list"
if grep -rqE '\{\{[A-Z_]+\}\}' "$C"; then echo "치환 뒤 토큰 잔존 — 실행하지 않았다"; exit 2; fi

TO=${SCAFFOLD_TEST_TIMEOUT:-300}
case "$TO" in ''|*[!0-9]*) echo "SCAFFOLD_TEST_TIMEOUT 은 양의 정수"; exit 2 ;; esac
[ "$TO" -gt 0 ] || { echo "SCAFFOLD_TEST_TIMEOUT 은 양의 정수"; exit 2; }
mask() { D="$d" D2="${d#/private}" perl -pe 's/\Q$ENV{D}\E/<d>/g; s/\Q$ENV{D2}\E/<d>/g; s/\Q$ENV{HOME}\E/~/g if length $ENV{HOME} > 1'; }

find "$C/hooks" -type f -name '*.test.sh' | LC_ALL=C sort > "$d/tests.list" || exit 2
[ -s "$d/tests.list" ] || { echo "시험 없음 — 실행하지 않았다"; exit 2; }
pass=0; fail=0
while IFS= read -r t; do
  name=${t#"$C"/}; out="$d/out.txt"; tof="$d/timeout.flag"; rm -f "$tof" "$tof.sig"
  # 환경 = 허용 목록(env -i) — 시험 대상 경로를 바꾸는 노브(HOOKS_*·GATE·GUARD·SCRIPTS_DIR 등)와 GIT_*·CLAUDE_* 가 새지 않게.
  # 시험은 새 프로세스 그룹에서 돈다 — 시간 초과(표식 tof)·래퍼가 받은 INT·TERM·HUP(표식 tof.sig, 128+n)·정상 종료 모두
  # 그룹째 KILL 해 남은 하위 프로세스를 걷는다(터미널 신호는 떨어진 그룹에 닿지 않으므로 래퍼가 대신 전한다. 핸들러는 fork 전에 건다).
  # ponytail: 정상 종료 경로의 그룹 KILL 은 리더 회수 뒤라 같은 번호의 새 그룹이 생기는 이론상 경합이 있다 / 업그레이드 = 리더를 좀비로 둔 채 KILL 후 회수
  # ponytail: fork~exec 사이 자식은 부모 핸들러를 물려받는다(%SIG = () 는 핸들러를 풀지 않는다 — exec 가 되돌린다) · 두 setpgrp 가 끝나기 전
  #           부모만 지목한 신호가 오면 그룹 KILL 이 빗나가 alarm 전 waitpid 로 기다린다 / 업그레이드 = 자식에서 $SIG{$_}="DEFAULT" 명시 · 그룹 KILL 실패 시 PID KILL 폴백
  ( cd "$P" && env -i PATH="$PATH" HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/bash}" \
      LANG="${LANG:-en_US.UTF-8}" TERM="${TERM:-dumb}" TMPDIR="$d/tmp" \
      perl -e '$t = shift; $f = shift;
               sub mark { open(my $h, ">", $_[0]); close $h }
               sub stop { if (defined $p && $p > 0) { kill "KILL", -$p; waitpid($p, 0) } exit $_[0] }
               my %n = (INT => 2, TERM => 15, HUP => 1);
               for my $s (keys %n) { $SIG{$s} = sub { mark("$f.sig"); stop(128 + $n{$s}) } }
               $SIG{ALRM} = sub { mark($f); stop(1) };
               $p = fork; defined $p or exit 2;
               if (!$p) { %SIG = (); setpgrp(0, 0); exec @ARGV or exit 127 }
               setpgrp($p, $p);
               alarm $t; waitpid($p, 0); $r = $?; kill "KILL", -$p;
               exit($r & 127 ? 128 + ($r & 127) : $r >> 8)' "$TO" "$tof" bash "$t" ) > "$out" 2>&1 < /dev/null
  rc=$?
  # 래퍼가 신호를 받았을 때만(표식 tof.sig) 러너도 멈춘다 — 시험 자신의 129/130/143 은 아래에서 rc= FAIL 로 센다.
  if [ -e "$tof.sig" ]; then echo "중단(신호) — $name"; exit "$rc"; fi
  last=$(grep -E '^Tests run:' "$out" | tail -n 1)
  run=$(printf '%s' "$last" | sed -nE 's/^Tests run: *([0-9]+).*/\1/p')
  ok=$(printf '%s' "$last" | sed -nE 's/.*Passed: *([0-9]+).*/\1/p')
  sk=$(printf '%s' "$last" | sed -nE 's/.*Skipped: *([0-9]+).*/\1/p')
  why=""
  if [ -e "$tof" ]; then why="timeout(${TO}s)"
  elif [ "$rc" -ne 0 ]; then why="rc=$rc"
  elif [ -z "$run" ] || [ -z "$ok" ]; then why="요약 줄 없음"
  elif [ "$run" -le 0 ]; then why="Tests run 0"
  elif [ "$ok" -ne "$run" ]; then why="Passed≠run"
  elif [ -n "$sk" ] && [ "$sk" -ne 0 ]; then why="Skipped $sk"
  fi
  if [ -z "$why" ]; then
    pass=$((pass + 1)); echo "PASS $name — $last"
  else
    fail=$((fail + 1)); echo "FAIL $name — $why${last:+ · $last}"
    tail -n 8 "$out" | mask | sed 's/^/    | /'
  fi
done < "$d/tests.list"
echo "합계: PASS $pass / FAIL $fail (시험 $((pass + fail))개 · 복사 ${n}개 · 치환 $(grep -c . "$d/subst.list")개 파일)"
[ "$fail" -eq 0 ]
