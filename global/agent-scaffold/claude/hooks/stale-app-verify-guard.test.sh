#!/usr/bin/env bash
# stale-app-verify-guard.sh 반증검사 — 2026-09-17 경고형→차단형(deny) 승격 검증.
# 양성(stale→deny) 1 · 음성(fresh→미발화) 1 · 우회(ALLOW_STALE_APP=1→미발화) 1 ·
# 대조(트리거 미매치 명령→미발화, 스코프가 넓어지지 않았는지) 1 + 히어독(S*)·node(N*)·미컴파일 기동(U*) 묶음
# + 마지막 줄 "Tests run: N, Passed: M".
#
# lsof/ps 는 진짜 프로세스를 재로 실측할 수 없으니 $WORK/bin 에 가짜 실행파일을 두고
# PATH 앞에 얹는다(python3 subprocess.run 은 목록 인자라 PATH 탐색 — inherited env 로 도달).
#   FAKE_LSOF_PID   : lsof 가 반환할 PID(비우면 "포트 미기동" 시뮬레이션)
#   FAKE_PS_LSTART  : ps -o lstart= 가 반환할 문자열("%a %b %d %H:%M:%S %Y" 형식)
# CLAUDE_PROJECT_DIR 는 명시적으로 unset — 이 세션의 실제 레포를 proj 로 오인하면 안 된다.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/stale-app-verify-guard.sh"
[ -x "$HOOK" ] || { echo "훅 파일이 없거나 실행권한이 없습니다: $HOOK" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/savg-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

run=0
pass=0

assert() {
  label="$1"; ok="$2"
  run=$((run + 1))
  if [ "$ok" -eq 0 ]; then
    pass=$((pass + 1))
    echo "PASS: $label"
  else
    echo "FAIL: $label"
  fi
}

# ── 가짜 프로젝트: {{MODULE_CORE}}/src/main 아래 소스 1개(지금 시각으로 mtime) ──
proj="$WORK/proj"
mkdir -p "$proj/{{MODULE_CORE}}/src/main/java"
src="$proj/{{MODULE_CORE}}/src/main/java/Foo.java"
printf 'class Foo {}\n' > "$src"
touch "$src"
src_epoch=$(python3 -c "import os; print(int(os.path.getmtime('$src')))")

# ── 가짜 lsof/ps (PATH 최우선) ──
bin="$WORK/bin"
mkdir -p "$bin"
cat > "$bin/lsof" <<'EOF'
#!/usr/bin/env bash
# 인자(-ti :PORT -sTCP:LISTEN) — FAKE_LSOF_PID 로 제어. FAKE_LSOF_PORT 가 있으면 그 포트에만 응답한다.
if [ -n "${FAKE_LSOF_PORT:-}" ] && [ "${2:-}" != ":$FAKE_LSOF_PORT" ]; then
  exit 0
fi
if [ -n "${FAKE_LSOF_PID:-}" ]; then
  echo "$FAKE_LSOF_PID"
fi
exit 0
EOF
cat > "$bin/ps" <<'EOF'
#!/usr/bin/env bash
# -p PID -o lstart= 만 흉내 — FAKE_PS_LSTART 를 그대로 출력.
echo "${FAKE_PS_LSTART:-}"
exit 0
EOF
chmod +x "$bin/lsof" "$bin/ps"

fmt_epoch() {
  # macOS(BSD date) 로 epoch → "%a %b %d %H:%M:%S %Y" (ps lstart 형식).
  # LC_ALL=C 필수 — 훅의 strptime 은 C 로케일 영문 요일·월명만 인식한다(로컬 로케일이면
  # date 가 "목 9월 17 …" 같은 한글을 내보내 strptime 파싱이 통째로 실패해 거짓 양성이 난다).
  LC_ALL=C date -j -f "%s" "$1" "+%a %b %d %H:%M:%S %Y"
}

stdin_json() {
  # stdin_json <command>
  jq -n --arg cmd "$1" --arg cwd "$proj" \
    '{tool_input:{command:$cmd}, cwd:$cwd, session_id:"sess-savg"}'
}

run_hook() {
  # run_hook <command> <fake_lsof_pid> <fake_ps_lstart>
  stdin_json "$1" | env -u CLAUDE_PROJECT_DIR PATH="$bin:$PATH" \
    FAKE_LSOF_PID="$2" FAKE_PS_LSTART="$3" "$HOOK"
}

trigger_cmd="npx playwright test foo.spec.js --project=admin"

# ---- 양성: 앱이 소스보다 1시간 먼저 기동(stale) → deny ----
old_start=$(fmt_epoch $((src_epoch - 3600)))
out_pos=$(run_hook "$trigger_cmd" "99999" "$old_start")
case "$out_pos" in
  *'"permissionDecision"'*'"deny"'*'stale 앱 차단'*) assert "양성(stale → deny)" 0 ;;
  *) assert "양성(stale → deny) — 실제출력: $out_pos" 1 ;;
esac

# ---- 음성: 앱이 소스보다 1시간 뒤 기동(fresh) → 미발화 ----
new_start=$(fmt_epoch $((src_epoch + 3600)))
out_neg=$(run_hook "$trigger_cmd" "99999" "$new_start")
if [ -z "$out_neg" ]; then
  assert "음성(fresh → 미발화)" 0
else
  assert "음성(fresh → 미발화) — 실제출력: $out_neg" 1
fi

# ---- 우회: stale 조건 그대로 + ALLOW_STALE_APP=1 접두 → 미발화 ----
out_bypass=$(run_hook "ALLOW_STALE_APP=1 $trigger_cmd" "99999" "$old_start")
if [ -z "$out_bypass" ]; then
  assert "우회(ALLOW_STALE_APP=1 → 미발화)" 0
else
  assert "우회(ALLOW_STALE_APP=1 → 미발화) — 실제출력: $out_bypass" 1
fi

# ---- 대조: 트리거 미매치 명령(스코프 확인) — stale 조건이라도 미발화 ----
out_ctrl=$(run_hook "ls -la" "99999" "$old_start")
if [ -z "$out_ctrl" ]; then
  assert "대조(트리거 미매치 → 미발화)" 0
else
  assert "대조(트리거 미매치 → 미발화) — 실제출력: $out_ctrl" 1
fi

# ---- 히어독 판정(2026-09-18, lib git_strip_heredoc 로 교체) ----
# 반증 예고: 종전 인라인 awk 판이면 S1·S3 의 2건이 미발화로 빨강 — 종전 판은 `<<<y` 의 두 번째 << 부터 토큰으로
#   잡아 뒤 줄을 걷어냈고, 히어독 여는 줄 자체를 빈 줄로 바꿔 같은 줄 뒤쪽 명령까지 버렸다. S2 는 두 판 모두 초록.
out_hs=$(run_hook "$(printf 'grep -q x <<<y\n%s' "$trigger_cmd")" "99999" "$old_start")
case "$out_hs" in
  *'"deny"'*) assert "S1 here-string 다음 줄의 검증 명령 → deny" 0 ;;
  *) assert "S1 here-string 다음 줄의 검증 명령 → deny — 실제출력: $out_hs" 1 ;;
esac
out_doc=$(run_hook "$(printf 'cat > note.md <<EOF\n%s\nEOF' "$trigger_cmd")" "99999" "$old_start")
if [ -z "$out_doc" ]; then assert "S2 문서 히어독 본문의 검증 문구 → 미발화" 0
else assert "S2 문서 히어독 본문의 검증 문구 → 미발화 — 실제출력: $out_doc" 1; fi
out_same=$(run_hook "$(printf 'cat > note.md <<EOF; %s\n본문\nEOF' "$trigger_cmd")" "99999" "$old_start")
case "$out_same" in
  *'"deny"'*) assert "S3 히어독 여는 줄과 같은 줄의 검증 명령 → deny" 0 ;;
  *) assert "S3 히어독 여는 줄과 같은 줄의 검증 명령 → deny — 실제출력: $out_same" 1 ;;
esac

# ---- node 스크립트형 검증(2026-10-30) — 명령줄에 포트가 없고 스크립트 파일 안에만 있다 ----
# 반증 예고: node 분기를 지우면 N1·N3 이 미발화로 빨강 · 상대경로를 proj 기준으로 되돌리면 N3 만 빨강. N2 는 늘 초록.
printf 'await page.goto("http://localhost:{{ADMIN_PORT}}/x");\n' > "$proj/v.mjs"
out_n1=$(run_hook "node v.mjs" "99999" "$old_start")
case "$out_n1" in
  *'"deny"'*) assert "N1 포트가 든 node 스크립트 → deny" 0 ;;
  *) assert "N1 포트가 든 node 스크립트 → deny — 실제출력: $out_n1" 1 ;;
esac
printf 'console.log(1);\n' > "$proj/plain.mjs"
out_n2=$(run_hook "node plain.mjs" "99999" "$old_start")
if [ -z "$out_n2" ]; then assert "N2 포트 없는 node 스크립트 → 미발화" 0
else assert "N2 포트 없는 node 스크립트 → 미발화 — 실제출력: $out_n2" 1; fi
mkdir -p "$proj/sub"; cp "$proj/v.mjs" "$proj/sub/w.mjs"
out_n3=$(jq -n --arg cmd "node w.mjs" --arg cwd "$proj/sub" '{tool_input:{command:$cmd}, cwd:$cwd, session_id:"sess-savg"}' \
  | env CLAUDE_PROJECT_DIR="$proj" PATH="$bin:$PATH" FAKE_LSOF_PID="99999" FAKE_PS_LSTART="$old_start" "$HOOK")
case "$out_n3" in
  *'"deny"'*) assert "N3 하위 디렉터리 cwd 의 상대경로 node 스크립트 → deny" 0 ;;
  *) assert "N3 하위 디렉터리 cwd 의 상대경로 node 스크립트 → deny — 실제출력: $out_n3" 1 ;;
esac

# ---- 미컴파일 기동(2026-11-05) — 소스 수정 후 컴파일 없이 재기동하면 앱 기동 시각은 소스보다 늦다 ----
# 반증 예고: 보조축(모듈별 소스 > classes)을 지우면 U1·U4 가 미발화로 빨강. U2(클래스가 기동보다 새로워도 소스보다
#   새로우면 정상 — 폐기 축 부활 감시)·U3(Front 미컴파일은 {{ADMIN_PORT}} 앱과 무관)은 두 판 모두 초록.
# 별도 프로젝트를 쓴다 — 위 케이스들은 target/classes 가 없는 프로젝트를 전제로 한다.
uproj="$WORK/uproj"
for m in {{MODULE_CORE}} {{MODULE_ADMIN}} {{MODULE_FRONT}}; do mkdir -p "$uproj/$m/src/main/java" "$uproj/$m/target/classes"; done
for m in {{MODULE_CORE}} {{MODULE_ADMIN}} {{MODULE_FRONT}}; do
  printf 'class A {}\n' > "$uproj/$m/src/main/java/A.java"; printf 'x' > "$uproj/$m/target/classes/A.class"
done
base=$(python3 -c "import time; print(int(time.time()) - 86400)")
setm() { python3 -c "import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))" "$1" "$2"; }
# 기본: 모든 모듈 classes 가 소스보다 새롭다(컴파일됨)
for m in {{MODULE_CORE}} {{MODULE_ADMIN}} {{MODULE_FRONT}}; do
  setm "$uproj/$m/src/main/java/A.java" "$base"; setm "$uproj/$m/target/classes/A.class" $((base + 60))
done
late_start=$(fmt_epoch $((base + 3600)))
run_uhook() {
  # run_uhook <fake_lsof_port>
  jq -n --arg cmd "$trigger_cmd" --arg cwd "$uproj" '{tool_input:{command:$cmd}, cwd:$cwd, session_id:"sess-savg"}' \
    | env -u CLAUDE_PROJECT_DIR PATH="$bin:$PATH" FAKE_LSOF_PID="99999" FAKE_LSOF_PORT="$1" FAKE_PS_LSTART="$late_start" "$HOOK"
}
# U1: Core 소스를 고치고(base+120) 컴파일 안 함(classes base+60) → 앱 base+3600 기동 → deny
setm "$uproj/{{MODULE_CORE}}/src/main/java/A.java" $((base + 120))
out_u1=$(run_uhook {{ADMIN_PORT}})
case "$out_u1" in
  *'"deny"'*'{{MODULE_CORE}}/target/classes'*) assert "U1 Core 미컴파일 상태로 기동(기동 > 소스) → deny" 0 ;;
  *) assert "U1 Core 미컴파일 상태로 기동(기동 > 소스) → deny — 실제출력: $out_u1" 1 ;;
esac
# U2: 그 뒤 컴파일(classes base+7200, 기동보다도 새롭다 = mvn test 재기록 꼴) → 미발화
setm "$uproj/{{MODULE_CORE}}/target/classes/A.class" $((base + 7200))
out_u2=$(run_uhook {{ADMIN_PORT}})
if [ -z "$out_u2" ]; then assert "U2 classes 가 소스·기동보다 새로움 → 미발화" 0
else assert "U2 classes 가 소스·기동보다 새로움 → 미발화 — 실제출력: $out_u2" 1; fi
# U5: classes 로 가지 않는 파일(src/main/webapp)만 classes 보다 새롭고 기동보다는 오래됨 → 미발화
#   (보조축 모집단 = src/main/java·resources. 반증 예고: 모집단을 src/main 으로 되돌리면 U5 가 deny 로 빨강)
mkdir -p "$uproj/{{MODULE_CORE}}/src/main/webapp"; printf '<p>x</p>\n' > "$uproj/{{MODULE_CORE}}/src/main/webapp/index.html"
setm "$uproj/{{MODULE_CORE}}/target/classes/A.class" $((base + 2000))
setm "$uproj/{{MODULE_CORE}}/src/main/webapp/index.html" $((base + 3000))
out_u5=$(run_uhook {{ADMIN_PORT}})
if [ -z "$out_u5" ]; then assert "U5 webapp 파일만 classes 보다 새로움 → 미발화" 0
else assert "U5 webapp 파일만 classes 보다 새로움 → 미발화 — 실제출력: $out_u5" 1; fi
setm "$uproj/{{MODULE_CORE}}/src/main/webapp/index.html" "$base"; setm "$uproj/{{MODULE_CORE}}/target/classes/A.class" $((base + 7200))   # U2 상태로 복귀
# U6: src/main/java 안의 비 .java(.xml)만 classes 보다 새롭고 기동보다는 오래됨 → 미발화
#   (Maven 기본 설정은 src/main/java 의 비 .java 를 classes 로 복사하지 않는다. 반증 예고: java 디렉터리 확장자를 SRC_EXT 로
#   되돌리면 U6 만 deny 로 빨강)
printf '<x/>\n' > "$uproj/{{MODULE_CORE}}/src/main/java/A.xml"
setm "$uproj/{{MODULE_CORE}}/target/classes/A.class" $((base + 2000))
setm "$uproj/{{MODULE_CORE}}/src/main/java/A.xml" $((base + 3000))
out_u6=$(run_uhook {{ADMIN_PORT}})
if [ -z "$out_u6" ]; then assert "U6 src/main/java 의 .xml 만 classes 보다 새로움 → 미발화" 0
else assert "U6 src/main/java 의 .xml 만 classes 보다 새로움 → 미발화 — 실제출력: $out_u6" 1; fi
setm "$uproj/{{MODULE_CORE}}/src/main/java/A.xml" "$base"; setm "$uproj/{{MODULE_CORE}}/target/classes/A.class" $((base + 7200))   # U2 상태로 복귀
# U3: Front 만 미컴파일 + {{ADMIN_PORT}}(Admin) 만 기동 → 미발화
setm "$uproj/{{MODULE_FRONT}}/src/main/java/A.java" $((base + 120))
out_u3=$(run_uhook {{ADMIN_PORT}})
if [ -z "$out_u3" ]; then assert "U3 Front 미컴파일·Admin 포트만 기동 → 미발화" 0
else assert "U3 Front 미컴파일·Admin 포트만 기동 → 미발화 — 실제출력: $out_u3" 1; fi
# U4: 같은 상태 + {{FRONT_PORT}}(Front) 기동 → deny
out_u4=$(run_uhook {{FRONT_PORT}})
case "$out_u4" in
  *'"deny"'*'{{MODULE_FRONT}}/target/classes'*) assert "U4 Front 미컴파일·Front 포트 기동 → deny" 0 ;;
  *) assert "U4 Front 미컴파일·Front 포트 기동 → deny — 실제출력: $out_u4" 1 ;;
esac

echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ]
