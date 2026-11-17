#!/usr/bin/env bash
# PreToolUse(Bash) 가드 — 검증 명령을 **옛 코드가 떠 있는 앱**에 대고 돌리려 할 때 차단한다.
# 2026-09-17 경고형(additionalContext) → 차단형(deny) 승격. 근거 = docs/agent-forensics-20260910/apply/PLAN.md
# 처분 hook:PreToolUse-Bash:8(표본 3회 실측, 아래 ①②③). 판정축은 승격 전과 동일(변경 없음).
#
# 왜 있나(3회 실측, 매번 검증 결과가 거짓이었다):
#   ①2026-09-04 반증 변이를 원복하고 재컴파일 없이 기동 → 변이본이 돌아 E2E 가 거짓 FAIL.
#   ②2026-09-09 관리자IP 락아웃 가드 — 거부 부등호를 뒤집은 변이가 실린 채 기동해 E2E 의 '설정' 클릭이
#     **dev 를 실제 락아웃**시켰다(DB UPDATE 로 원복). 변이 대상이 가드 분기면 피해가 거짓 결과를 넘어 실데이터 파괴가 된다.
#   ③2026-09-09 메뉴 계층 정합 — 렌더 층 철회 후 재컴파일 없이 회귀 스위트를 돌려 초록을 받았다(철회 전 코드가 돌았다).
#   memory [[mutation-revert-needs-recompile]] 가 있었는데도 ②③이 났다 = 경고(additionalContext)로는 안 지켜졌다
#   → 차단형 승격.
#
# 판정축(유지) = **소스 최신 mtime > 앱 기동 시각**.
#   클래스(target/classes) mtime 을 쓰면 안 된다 — `mvn test`/`compile` 은 소스 무변경이라도 클래스를 다시 써서
#   상시 오탐이 나고, 오탐이 잦은 가드는 우회가 습관이 되어 죽는다(2026-09-09 실측으로 이 축을 폐기했다. 이 폐기 이력은
#   차단형 승격 후에도 유효 — 클래스 mtime 축을 되살리지 마라).
#   부가로 소스가 클래스보다 새로우면 "재컴파일 자체를 안 했다"로 한 단계 더 짚는다.
#   보조축(2026-11-05) = **같은 모듈의 소스 최신 mtime > 그 모듈 target/classes 최신 mtime** 이면 앱이 소스보다
#   늦게 떴어도 막는다 — 기동({{RUN_SKILL}})이 컴파일 없이 target/classes 를 싣는 구성(`java -cp target/classes …`)이면
#   "소스 수정 → 컴파일 없이 재기동"은 주축(기동 시각)으로는 정상처럼 보인다. 이 축은 클래스가 **더 오래된** 쪽만 보고
#   (mvn 이 클래스를 새로 쓰면 풀린다 — 위 폐기 축 = 클래스 mtime vs 기동 시각과 다르다), 소스 모집단은 컴파일·복사로
#   target/classes 에 들어가는 src/main/java 의 .java + src/main/resources 다(있는 것만). webapp 파일·src/main/java 안의
#   비 .java(Maven 기본 설정은 복사하지 않음) 등 classes 로 가지 않는 파일은 컴파일로도 재기동으로도 classes 보다 새 상태가
#   풀리지 않아 넣으면 영구 오탐이 된다(주축은 src/main 전체 그대로).
# ponytail: pom 이 classes 로 복사하지 않는 resources(excludes·비기본 설정)는 이 축에서 영구 오탐 / 업그레이드 = 대응 classes 파일이 있는 소스만 비교
# ponytail: 반대로 pom 이 src/main/java 의 비 .java(매퍼 XML 등)를 classes 로 복사하는 구성이면 그 파일만 고치고 컴파일 없이 재기동한 경우를
#   이 축은 놓친다(주축 = 기동 시각은 그대로 잡는다) / 업그레이드 = 위와 같음.
#   포트별로 그 앱이 싣는 모듈만 본다({{ADMIN_PORT}} = Core+Admin, {{FRONT_PORT}} = Core+Front — 기동 명령의 -cp 와
#   다르면 아래 PORT_MODS 를 그 레포 기동 명령에 맞춘다).
#
# 우회: 명령 앞에 ALLOW_STALE_APP=1 을 붙인다(셸 변수 대입 형태로만 인정 — 문자열에 우연히 섞여도 안 뚫리게).
#   오탐(아래 한계)이라고 판단해 우회했으면 그 판단을 사용자에게 알릴 것(레포 CLAUDE.md 상태주장 조항).
#
# 안전(fail-open): jq/python3/lsof 부재 · 검증 명령 아님 · 앱 미기동 · 남의 레포 · 파싱 실패 → 조용히 exit 0
#   (fail-open 은 차단형 승격 후에도 유지 — 도구 부재로 다른 Bash 호출까지 막으면 안 된다).
#
# 남는 한계(차단형이라 우회 필요 — 경고형 때보다 비용이 크다):
#   - `python3 -c '...'` 인자나 echo 문자열 안에 트리거 문구가 있으면 여전히 오탐한다(heredoc 만 걷어낸다).
#   - 이 세션의 Bash 만 본다 — 서브에이전트·다른 세션이 띄운 앱은 `e2e-verify` 반환 규율(검증 환경 필드)이 맡는다.
#   - 사용자 인스턴스(에이전트 포트 밖)는 대상이 아니다.
#   - "소스 수정 → 컴파일 없이 기동 → 그 뒤 컴파일(재기동 없음)"은 못 잡는다 — 지금 클래스·소스·기동 시각이 모두 정상
#     순서라 기동 당시 클래스 상태를 알 수 없다. 잡으려면 폐기한 클래스-기동 축이 필요하다.
#     # ponytail: 기동 시점 클래스 상태 미기록 / 업그레이드 경로 = 기동 스킬이 기동 직전 classes 최신 mtime 을 기록하고 훅이 대조
#   - 보조축은 모듈의 최신값끼리만 비교한다 — classes 쪽에 더 새 파일이 하나라도 생기면(템플릿을 target/classes 로
#     cp 하는 절차 등) 그 모듈의 미컴파일 Java 가 가려져 통과한다(놓치는 쪽).
#     # ponytail: 모듈 최신값끼리만 비교해 classes 쪽 새 파일(템플릿 cp 등)이 미컴파일 Java 를 가린다 / 업그레이드 = .java→.class 파일 단위 대조
#   - 명령이 겨냥한 포트와 무관하게 떠 있는 에이전트 포트({{ADMIN_PORT}}·{{FRONT_PORT}}) 전부를 검사한다 — 한쪽 앱만 stale 이어도
#     다른 포트를 겨냥한 검증까지 막는다(과차단 쪽, 주축부터의 성질). 그 경우 ALLOW_STALE_APP=1 우회 + 사용자 보고.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v lsof >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# 명시적 우회 — 셸 변수 대입 형태로만 인정한다(커밋 메시지·문자열에 우연히 섞인 문구로는 뚫리지 않게).
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_STALE_APP=1[[:space:]]'; then
  exit 0
fi

proj="${CLAUDE_PROJECT_DIR:-$cwd}"
# 이 레포의 소스를 기준으로 판정한다 — 다른 레포에서 부른 명령엔 발동하지 않는다.
[ -d "$proj/{{MODULE_CORE}}/src/main" ] || exit 0

# ── 트리거: 떠 있는 앱을 대상으로 하는 검증 명령만 ──────────────────────────────
#   좁게 잡는다(빌드·기동 명령 자체는 대상이 아니다 — 그것들이 stale 을 해소하는 쪽이다).
#   ⚠️판정 전에 **히어독 판정**을 거친다 — 문서·memory 를 히어독으로 쓰는 본문은 실행이 아니라 텍스트다
#   (2026-09-09 실측: 이 훅을 서술하는 문서를 히어독으로 쓰다 자기 트리거 문구에 발동했다). 판정 규칙은 공용 lib
#   (git-cmd.sh git_strip_heredoc — 데이터 싱크가 문서 확장자로 쓸 때만 본문 제외)이고, 종전 인라인 awk 는
#   `<<<`·인용 안 `<<` 를 히어독으로 오인해 다음 줄의 검증 명령을 걷어냈다(2026-09-18 교체). lib 부재 시 원문.
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ -f "$_lib" ] && . "$_lib" && command -v git_strip_heredoc >/dev/null 2>&1; then
  scan=$(git_strip_heredoc "$cmd")
else
  scan="$cmd"
fi
#   node 스크립트형 Playwright(`node x.mjs`)는 명령줄에 포트가 없다 — 스크립트 파일 안에 에이전트 포트가 있으면 검증으로 본다.
_hit=0
printf '%s' "$scan" | grep -Eq 'playwright[[:space:]]+test|{{REGRESS_SKILL}}|(curl|wget)[^|;]*:({{ADMIN_PORT}}|{{FRONT_PORT}})|{{PORT_ENV_PREFIX}}_(ADMIN|FRONT)_PORT' && _hit=1
if [ "$_hit" = 0 ]; then
  set -f  # 명령에서 뽑은 경로가 글롭으로 펼쳐져 엉뚱한 파일을 읽지 않게 한다
  # ponytail: 따옴표로 감싼 경로·`node --flag x.mjs`·`cd d && node x.mjs` 는 못 잡는다(놓치는 쪽) / 필요해지면 shlex 파싱으로
  for _f in $(printf '%s' "$scan" | grep -Eo 'node[[:space:]]+[^[:space:];|&]+\.(mjs|cjs|js)' | awk '{print $2}'); do
    case "$_f" in /*) ;; *) _f="$cwd/$_f" ;; esac  # 상대경로는 명령이 실행되는 cwd 기준
    [ -f "$_f" ] && grep -Eq '({{ADMIN_PORT}}|{{FRONT_PORT}})' "$_f" && { _hit=1; break; }
  done
  set +f
fi
[ "$_hit" = 1 ] || exit 0

result=$(APP_PROJ="$proj" python3 <<'PY' 2>/dev/null
import os, subprocess, time

proj = os.environ["APP_PROJ"]
PORTS = ("{{ADMIN_PORT}}", "{{FRONT_PORT}}")
SRC_EXT = (".java", ".xml", ".html", ".js", ".css", ".properties", ".yml")

def app_start(port):
    """포트를 LISTEN 하는 프로세스의 기동 epoch(없으면 None)."""
    try:
        pids = subprocess.run(["lsof", "-ti", ":" + port, "-sTCP:LISTEN"],
                              capture_output=True, text=True, timeout=5).stdout.split()
    except Exception:
        return None
    for pid in pids:
        try:
            env = dict(os.environ, LC_ALL="C")
            raw = subprocess.run(["ps", "-p", pid, "-o", "lstart="],
                                 capture_output=True, text=True, timeout=5, env=env).stdout.strip()
            if raw:
                return time.mktime(time.strptime(raw, "%a %b %d %H:%M:%S %Y"))
        except Exception:
            continue
    return None

def newest(roots, exts=None):
    """roots 아래 파일 중 최신 mtime 과 그 경로."""
    best, bestp = 0.0, None
    for root in roots:
        for dp, dn, fn in os.walk(root):
            dn[:] = [d for d in dn if d not in ("target", "node_modules", ".git")]
            for f in fn:
                if exts and not f.endswith(exts):
                    continue
                p = os.path.join(dp, f)
                try:
                    m = os.path.getmtime(p)
                except OSError:
                    continue
                if m > best:
                    best, bestp = m, p
    return best, bestp

src_roots = [os.path.join(proj, m, "src", "main")
             for m in ("{{MODULE_CORE}}", "{{MODULE_ADMIN}}", "{{MODULE_FRONT}}")
             if os.path.isdir(os.path.join(proj, m, "src", "main"))]
cls_roots = [os.path.join(proj, m, "target", "classes")
             for m in ("{{MODULE_CORE}}", "{{MODULE_ADMIN}}", "{{MODULE_FRONT}}")
             if os.path.isdir(os.path.join(proj, m, "target", "classes"))]
if not src_roots:
    raise SystemExit(0)

src_m, src_p = newest(src_roots, SRC_EXT)
cls_m, _ = newest(cls_roots)
if not src_m:
    raise SystemExit(0)

# 보조축 — 모듈별 (소스 최신, classes 최신). classes 가 없는 모듈은 판정하지 않는다(fail-open).
PORT_MODS = {"{{ADMIN_PORT}}": ("{{MODULE_CORE}}", "{{MODULE_ADMIN}}"), "{{FRONT_PORT}}": ("{{MODULE_CORE}}", "{{MODULE_FRONT}}")}
mod = {}
for m in ("{{MODULE_CORE}}", "{{MODULE_ADMIN}}", "{{MODULE_FRONT}}"):
    # classes 로 가는 소스만(webapp 등 제외) — java 디렉터리는 .java 만(비 .java 는 Maven 기본 설정이 복사하지 않는다)
    picks = [newest([os.path.join(proj, m, "src", "main", d)], exts)
             for d, exts in (("java", (".java",)), ("resources", SRC_EXT))
             if os.path.isdir(os.path.join(proj, m, "src", "main", d))]
    c_dir = os.path.join(proj, m, "target", "classes")
    if picks and os.path.isdir(c_dir):
        mod[m] = (max(picks, key=lambda t: t[0]), newest([c_dir])[0])

hhmm = lambda t: time.strftime("%H:%M:%S", time.localtime(t))
msgs = []
for port in PORTS:
    st = app_start(port)
    if st is None:
        continue                      # 미기동
    if src_m <= st:
        # 앱은 최신 소스 이후에 떴다 — 그래도 그 앱이 싣는 모듈의 소스가 classes 보다 새로우면 미컴파일 기동이다.
        for m in PORT_MODS[port]:
            if m not in mod:
                continue
            (ms, mp), mc = mod[m]
            if mc and ms > mc:
                msgs.append("포트 %s 는 %s 기동이지만 %s(%s)가 %s/target/classes(%s)보다 새롭습니다 — "
                            "재컴파일 없이 기동해 옛 클래스로 돌고 있습니다."
                            % (port, hhmm(st), os.path.relpath(mp, proj), hhmm(ms), m, hhmm(mc)))
                break
        continue
    stage = ("재컴파일도 아직입니다(소스가 target/classes 보다 새롭습니다)"
             if cls_m and src_m > cls_m
             else "재컴파일은 됐지만 앱이 그 전에 떠서 옛 클래스를 물고 있습니다")
    msgs.append("포트 %s 는 %s 기동인데 %s 가 %s 에 바뀌었습니다 — %s."
                % (port, hhmm(st), os.path.relpath(src_p, proj), hhmm(src_m), stage))

if msgs:
    print(" / ".join(msgs))
PY
)

[ -n "$result" ] || exit 0

reason="[stale 앱 차단] ${result} 지금 이 검증은 **바뀌기 전 코드**를 재는 것이라 초록도 빨강도 근거가 되지 않습니다(원 레포에서 3회 재현 — 한 번은 변이본이 실린 채 돌아 dev DB 를 실제로 락아웃시켰습니다). 재컴파일(\`mvn -pl <모듈> -am compile -Dmaven.repo.local={{MAVEN_REPO}}\`) → 앱 재기동({{RUN_SKILL}}) 후 다시 돌리고, 보고에는 **기동 시각과 소스/클래스 타임스탬프 두 값**을 함께 적으세요.

소스 변경이 이 검증과 무관하다고 판단해 그대로 진행하려면(예: 오탐), 명령 앞에 ALLOW_STALE_APP=1 을 붙여 재실행하고 그 판단을 사용자에게 알리세요."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
