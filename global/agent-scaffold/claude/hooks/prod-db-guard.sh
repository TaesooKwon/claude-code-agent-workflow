#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=차단
# PreToolUse(Bash) 가드 — "운영 DB 절대 금지(쓰기·DDL)" 규칙의 강제화. (agent-scaffold 범용판)
# Bash 에서 DB 접속을 '직접 여는' 명령을 막는다. 두 층으로 판정한다.
#   ⑴ 허용 형태 판정기(lib/cmdform.py db — 규칙 정본은 그 파일의 judge_db):
#      ① 인라인 파이썬(-c·히어독·파이프·같은 호출에서 쓰고 실행)에 DB 커넥터 낱말이 살아 있으면 **호스트와 무관하게** 차단
#        (정본 경로 = 프로젝트 DB MCP · DDL 적용 스킬의 스크립트 *파일* 실행 — 명령 텍스트에 커넥터 낱말이 없어 통과한다).
#      ② DB CLI 접속 호출의 동행 실행어는 허용 목록(ssh·socat·kubectl·스크립트 동행 = 차단) ③ 히어독 구분자는 순수형만
#      ④ DB CLI 옵션은 허용 목록(--ssh*·소켓·목록 밖 긴 옵션·값 묶음 = 차단) ⑤ 단독 ssh·autossh 터널 생성(-L·LocalForward·-N) 차단.
#   ⑵ DB CLI 호스트·포트 판정(아래 「DB CLI 판정」, bash): DB 낱말이 든 세그먼트는 기본 = 접속, 통과는 읽기 전용 실행어·
#      도움말뿐. 접속 대상은 화이트리스트 2축 — ALLOWED_DB_HOSTS_REGEX(표준 포트 한정 허용) ·
#      ALLOWED_DB_HOSTS_ANYPORT_REGEX(포트 무관 허용, 기본 빈 값). 어디에도 없는 호스트는 운영·미확인으로 보고 차단하며,
#      한 세그먼트에 여러 호스트가 있으면 **전부 허용일 때만** 통과한다(AND). ※ 부트스트랩 시 프로젝트 dev DB 호스트를 ANYPORT 축에 추가할 것.
#   settings.json permissions.deny 의 mysql/mysqldump 패턴은 1차 방어로 두고 이 훅이 2차로 판정한다.
#   grep/cat 등 코드 검색·열람 명령은 접속 '실행' 패턴이 아니므로 통과(출력을 실행될 만한 파일로 쓰면 그 텍스트는 판정한다).
# 안전(fail-closed): jq 부재 → stdin 원문(JSON 이스케이프를 편 사본)에 DB·python·터널 낱말이 보이면 차단.
#   판정기·python3 부재·예외·시간 초과(timeout 5 + 판정기 내부 상한)·형식 밖 출력 → DB·터널 낱말이 보이면 차단.
#   DB·터널 낱말이 없는 명령은 판정기를 띄우지 않고 통과(빠른 경로).
# ponytail: 위협 모델 = 에이전트가 실수로 칠 법한 접속을 막는다. 의도적 은폐는 다 막지 못한다 — 명령을 실행하는 도구의
#           옵션(git -c·mvn exec·less !)·표준입력으로 셸에 넘기기(echo '…' | bash)·변수 간접 실행 /
#           업그레이드 경로 = 네트워크 층 차단(운영 DB 로의 송신 자체를 막는다)
# ponytail: 인라인 python 외 런타임 드라이버(node -e mysql2·perl DBI·java jshell)는 미판정 / 업그레이드 = 네트워크 층
# ponytail: 스크립트 파일 실행(python3 x.py)은 본문을 보지 않는다. 같은 호출에서 쓰고 실행하는 형태는 실행어가 python 낱말·
#           셸/node 러너일 때만 본다 — 런처의 파일 실행(uv run a.py·pytest a.py)·경로 실행(./a)·변수 실행어($X a.py)는 미판정 /
#           업그레이드 = 네트워크 층
# ponytail: 런처 경유 탐색은 인용 안 된 낱말만 본다(uv run 'ssh'·\ssh 는 못 본다), 런처·find -exec 뒤 sh -c 문자열은
#           하위 명령으로 펼치지 않는다 / 업그레이드 = 네트워크 층(호출 전체 허용 목록 축은 실사용 오차단이 커서 보류)
# ponytail: 출력 리다이렉트 대상은 확장자 허용 목록(/dev/null·문서 확장자)만 본다 — 실행 권한·심볼릭 링크는 판정하지 않는다 /
#           업그레이드 = 네트워크 층 운영 DB 송신 차단
# ponytail: DB CLI 옵션 허용 목록은 목록 밖 정상 옵션도 막는다(fail-closed) / 업그레이드 = 실사용 거부 로그로 목록 보강
set -u

# 허용(로컬) DB 호스트 정규식 — **표준 포트일 때만** 허용되는 축.
#   비표준 포트는 SSH 로컬 포워딩 종단(배포 dev·운영 DB)일 수 있어 차단한다(아래 ④).
ALLOWED_DB_HOSTS_REGEX='localhost|127\.0\.0\.1'
# 포트 무관 허용 축 — 접속만으로 안전이 보장되는 dev 샌드박스 호스트를 여기에 등록한다
#   (예: 'dev\.example\.com'). 기본은 빈 값 = 포트 무관 허용 호스트 없음.
#   ※ 부트스트랩 시 프로젝트 dev DB 호스트를 이 변수에 추가할 것(ALLOWED_DB_HOSTS_REGEX 가 아니라).
ALLOWED_DB_HOSTS_ANYPORT_REGEX=''
# 로컬 호스트에 허용되는 표준 포트.
ALLOWED_DB_PORTS_REGEX='3306|3316'

# DB·터널 낱말(빠른 경로·판정기 부재 판정 공용) — 판정기의 hot 조건(커넥터·CLI 이름·ssh)을 부분 문자열로 덮는 상위 집합.
_HOT_RE='mysql|mariadb|mycli|sqlalchemy|create_engine|sshtunnel|asyncmy|ssh'

_deny() { # $1 = 차단 사유 한 줄. jq 가 없으면 사유의 따옴표·백슬래시·제어문자를 걷어 JSON 을 직접 쓴다.
  local r
  r="[운영 DB 가드] $1
(팀 규칙: 운영 DB 쓰기·DDL 절대 금지, 즉석 DB 원라이너 금지)

정본 경로를 사용하세요:
  - dev 조회/DML → 프로젝트 DB MCP
  - dev DDL     → 프로젝트 DDL 적용 스킬의 스크립트 파일 실행(dev 호스트 가드·비밀번호 비노출 내장)
인라인 python(-c·히어독·파이프·같은 호출에서 .py 를 쓰고 실행)의 DB 접속은 호스트와 무관하게 막습니다.
DB CLI(mysql 등)는 허용 호스트(dev·로컬 표준 포트 ${ALLOWED_DB_PORTS_REGEX})로의 단독 호출만 통과합니다 — 같은 호출에 ssh·socat·kubectl·스크립트를 섞지 마세요.
ssh·autossh 로 로컬 포워딩(-L·LocalForward·-N) 터널을 여는 호출도 막습니다(다음 호출의 localhost 접속이 운영 DB 로 갈 수 있다)."
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    r=$(printf '%s' "$r" | LC_ALL=C tr -d '\000-\037\177"\\')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r"
  fi
  exit 0
}

input=$(cat 2>/dev/null || true)
if ! command -v jq >/dev/null 2>&1; then
  # jq 부재 — 명령을 꺼낼 수 없다. 이스케이프(\n·\t·\"·\\·\uXXXX 등)를 공백으로 편 원문에 DB·python·터널 낱말이 보이면 차단(fail-closed).
  printf '%s' "$input" | sed -E 's/\\(u[0-9A-Fa-f]{4}|[\\"\/bfnrt])/ /g' | grep -Eiq "${_HOT_RE}|python|socat|ncat|port-forward" \
    && _deny "jq 가 없어 명령을 판정할 수 없습니다 — DB·python·터널 낱말이 보여 막습니다(jq 설치 후 재시도)."
  exit 0
fi

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# ⑴ 허용 형태 판정기 — DB·터널 낱말(따옴표·백슬래시·줄바꿈을 지운 사본)이나 $'…'(ANSI-C 인용 — 낱말을 숨길 수 있다)이
#    보일 때만 띄운다(모든 Bash 호출에서 도는 훅이라 python 기동 비용을 아낀다). tr·grep 이 실패하면 띄운다(fail-closed).
_hot=0
case "$cmd" in *"\$'"*) _hot=1 ;; esac
if [ "$_hot" -eq 0 ]; then
  if _fast=$(printf '%s' "$cmd" | tr -d '\042\047\134\n' 2>/dev/null); then
    printf '%s' "$_fast" | grep -Eiq -- "$_HOT_RE" 2>/dev/null; [ $? -ne 1 ] && _hot=1
  else
    _hot=1
  fi
fi
if [ "$_hot" -eq 1 ]; then
  _pyj="$(dirname "$0")/lib/cmdform.py"
  if command -v python3 >/dev/null 2>&1 && [ -f "$_pyj" ]; then
    # 시간 상한 = timeout 5(있으면) + 판정기 내부 상한(LIMIT_SEC). rc≠0(시간 초과 124 포함)·형식 밖 출력 = 차단.
    if command -v timeout >/dev/null 2>&1; then
      _r=$(printf '%s' "$cmd" | timeout 5 python3 -I "$_pyj" db 2>/dev/null); _rc=$?
    else
      _r=$(printf '%s' "$cmd" | python3 -I "$_pyj" db 2>/dev/null); _rc=$?
    fi
    [ "$_rc" -eq 0 ] || _deny "판정기 오류(rc=$_rc — 시간 초과·예외)로 판정할 수 없어 막습니다."
    case "$_r" in
      ALLOW) ;;
      DENY*) _why=${_r#DENY}; _deny "허용 형태가 아닌 DB 접속·터널 호출입니다(사유: ${_why#	})." ;;
      *) _deny "판정기 출력 형식을 알 수 없어 막습니다." ;;
    esac
  else
    _deny "판정기(lib/cmdform.py·python3)가 없어 판정할 수 없습니다 — DB·터널 낱말이 보여 막습니다(lib·python3 복구 후 재시도)."
  fi
fi

# heredoc 판정 — 공용 lib(git-cmd.sh git_strip_heredoc)의 허용 목록 규칙을 쓴다(2026-09-18, 종전 인라인 awk 교체).
#   본문은 **데이터 싱크(cat·tee 등)가 문서·데이터 확장자로 쓸 때만** 걷어낸다 — 실측 오탐이던
#   `cat >> 문서.md <<'EOF' … MariaDB … host= … EOF` 는 계속 통과하고, python·DB CLI·bash·ssh 로 넘기거나
#   `| python3` 파이프·스크립트 파일로 쓰는 본문은 남아 판정된다(`python3 - <<'PY' import pymysql …` 우회 차단 유지).
#   종전 인라인 판은 "인터프리터면 남긴다" 금지 목록이라 here-string·인용 안 << 를 히어독으로 오인해 다음 줄의
#   접속 명령까지 걷어낼 수 있었다. lib 가 없으면 걷어내지 않는다(fail-closed — 오탐은 나도 미탐은 없다).
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ -f "$_lib" ] && . "$_lib" && command -v git_strip_heredoc >/dev/null 2>&1; then
  cmd_nohd=$(git_strip_heredoc "$cmd")
else
  cmd_nohd="$cmd"
fi

# 인라인 파이썬·터널·CLI 옵션·동행 실행어 판정은 위 ⑴ 판정기 몫이다. 아래는 DB CLI 의 호스트·포트 판정(⑵)이다.

# ── DB CLI 판정(2026-10-08 허용 목록 재설계) ─────────────────────────────────────────────
# 종전 판정은 "이런 모양이면 접속"을 하나씩 더하는 금지 목록이라 반증 한 번에 미탐 13·오탐 5 가 나왔다
# (따옴표 안 실행어·이스케이프·$(…)·래퍼 옵션 값·주석 위장·포트 첫 값 채택 등). 그래서 뒤집는다:
#   DB 낱말이 든 세그먼트는 **기본 = 접속**이고, 통과는 ⓐ첫 실행어가 SAFE_READERS ⓑ인자가 도움말·버전뿐, 둘만.
#   접속으로 본 세그먼트는 첫 실행어가 DB 낱말·투명 래퍼·셸 문법 토큰·$/백틱일 때만 호스트·포트 허용 목록으로
#   판정하고, 그 밖의 실행어(ssh·bash -c·모르는 명령) 뒤에 온 DB 낱말은 호스트를 믿을 수 없어 차단한다.
# 레포마다 값만 바꾸는 줄(VAR=) — DB 낱말(basename 완전일치 정규식, 대소문자 무시) · 통과 실행어 · 호스트 판정을 허용하는 래퍼.
# DB 낱말은 계열 접두로 본다(mysqlcheck·mysqlpump·mysqlbinlog·mysql_upgrade·mariadb-dump 등) — 빠른 경로는 같은 값을
# 부분 문자열로 쓴다. 점(.)이 든 낱말(mysql.connector·*.jar)은 실행어가 아니라 이름 일부라 빠진다.
DB_CLI_NAMES='(mysql|mariadb)[a-z0-9_-]*|mycli'
SAFE_READERS='grep|egrep|fgrep|rg|git|echo|printf|ls|cat|head|tail|less|brew|which|type|man|pgrep|ps|mvn|wc'
DB_WRAPPERS='env|command|exec|time|nice|timeout|sudo|nohup|xargs|stdbuf'
# ponytail: ①변수 간접 실행은 같은 명령 안 대입만 본다(이전 호출에서 정한 $m 은 못 본다) ②xargs 가 표준입력으로 실행어를
#           받는 형태는 앞 세그먼트(echo 등 통과 실행어)에 DB 낱말이 있어 샌다 ③스크립트 파일 실행은 본문을 보지 않는다
#           / 업그레이드 경로 = 명령 전체 단위 'DB 낱말 존재 → 호스트 확정 못 하면 차단'

# 1) 정규화(awk 만, eval 없음): 따옴표는 걷고 내용은 남긴다("mysql"→mysql, m''ysql→mysql), 따옴표 밖 \x→x,
#    따옴표 밖에서 낱말 머리의 # 부터 줄 끝까지 주석 제거, 따옴표 밖 ; & | 줄바꿈 = 세그먼트 경계,
#    ( ) ` = 독립 토큰($( 는 "$" "(" 두 토큰). 따옴표 안 줄바꿈은 공백. 히어독은 위에서 lib 규칙으로 걷힌 뒤다.
_db_norm() {
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0; n = length(s); q = 0; out = ""; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (q == 1) { if (c == "\047") q = 0; else out = out (c == "\n" ? " " : c); i++; continue }
      if (q == 2) {
        if (c == "\"") { q = 0; i++; continue }
        if (c == "\\" && i < n) { d = substr(s, i + 1, 1); if (index("$`\"\\\n", d)) { out = out (d == "\n" ? " " : d); i += 2; continue } }
        out = out (c == "\n" ? " " : c); i++; continue
      }
      if (c == "\047") { q = 1; i++; continue }
      if (c == "\"") { q = 2; i++; continue }
      if (c == "\\") { if (i < n) { d = substr(s, i + 1, 1); out = out (d == "\n" ? " " : d) } i += 2; continue }
      if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t\n]/)) {
        while (i <= n && substr(s, i, 1) != "\n") i++
        continue
      }
      if (c == ";" || c == "&" || c == "|" || c == "\n") { out = out "\n"; i++; continue }
      if (c == "(" || c == ")" || c == "`") { out = out " " c " "; i++; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { out = out " $ "; i++; continue }
      if (c == "\t") c = " "
      out = out c; i++
    }
    if (q != 0) exit 3          # 닫히지 않은 따옴표 = 판정 불가
    printf "%s\n", out
  }'
}

# 2) 세그먼트 하나의 호스트·포트 판정 — 지시자별 **마지막 값**(클라이언트가 마지막 값을 쓴다), 지시자 뒤 공백 수 무관.
#    -h/--host(=)·host:port·URI(@·://, 옵션 낱말 제외)·MYSQL_HOST/MYSQL_TCP_PORT 대입. 설정 파일(--defaults-*·
#    --login-path)은 호스트를 알 수 없어 차단. 호스트가 하나도 없으면 차단(기존 계약). 전부 허용일 때만 0.
_db_seg_hosts_ok() {
  local -a w; read -ra w <<<"$1"
  local i n=${#w[@]} t v host="" port="" envhost="" envport="" uris=""
  for ((i = 0; i < n; i++)); do
    t=${w[$i]}
    case "$t" in
      --defaults-file=*|--defaults-extra-file=*|--defaults-file|--defaults-extra-file|--login-path=*|--login-path) return 1 ;;
      -h|--host) v=${w[$((i + 1))]:-}; [ -n "$v" ] && host=$v; i=$((i + 1)) ;;
      --host=*) host=${t#--host=} ;;
      -h?*) host=${t#-h} ;;
      -P|--port) v=${w[$((i + 1))]:-}; [ -n "$v" ] && port=$v; i=$((i + 1)) ;;
      --port=*) port=${t#--port=} ;;
      -P?*) port=${t#-P} ;;
      MYSQL_HOST=*) envhost=${t#MYSQL_HOST=} ;;
      MYSQL_TCP_PORT=*) envport=${t#MYSQL_TCP_PORT=} ;;
      -*) ;;
      *://*|*@*) v=${t##*@}; v=${v#*://}; v=${v%%[/?]*}; uris="$uris $v" ;;
    esac
  done
  [ -n "$port" ] || port=$envport
  local list="$host $envhost $uris" h hp hl seen=0
  for h in $list; do
    seen=1; hp=""
    case "$h" in *:*) hp=${h##*:}; h=${h%%:*} ;; esac
    hl=$(printf '%s' "$h" | tr 'A-Z' 'a-z')
    if [ -n "$ALLOWED_DB_HOSTS_ANYPORT_REGEX" ] && printf '%s' "$hl" | grep -Eq "^(${ALLOWED_DB_HOSTS_ANYPORT_REGEX})\$"; then
      continue
    fi
    printf '%s' "$hl" | grep -Eq "^(${ALLOWED_DB_HOSTS_REGEX})\$" || return 1
    for p in "$hp" "$port"; do
      [ -z "$p" ] || printf '%s' "$p" | grep -Eq "^(${ALLOWED_DB_PORTS_REGEX})\$" || return 1
    done
  done
  [ "$seen" -eq 1 ]
}

# 3) 세그먼트 판정 — 0 = 통과(DB 낱말 없음·예외), 1 = 차단.
_db_is_name() { # 낱말 → basename 소문자가 DB 낱말이면 0 (VAR=값 이면 값으로 본다 — `m=mysql; $m …` 대비)
  local t=${1#*=}; t=${t##*/}
  printf '%s' "$t" | tr 'A-Z' 'a-z' | grep -Eqx "${DB_CLI_NAMES}"
}
_db_seg_ok() {
  local -a w; read -ra w <<<"$1"
  local n=${#w[@]} i has=0 first="" fl k=0
  [ "$n" -gt 0 ] || return 0
  for ((i = 0; i < n; i++)); do _db_is_name "${w[$i]}" && { has=1; break; }; done
  [ "$has" -eq 1 ] || return 0
  # 첫 실행어 = 앞의 VAR=값 대입을 건너뛴 첫 낱말
  while [ "$k" -lt "$n" ] && printf '%s' "${w[$k]}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; do k=$((k + 1)); done
  [ "$k" -lt "$n" ] || return 1                                   # 대입만 있고 DB 낱말이 값 = 차단
  first=${w[$k]}
  fl=$(printf '%s' "${first##*/}" | tr 'A-Z' 'a-z')
  case "$first" in \$*|\`*|\\*) ;; *)                                # ⓐ 통과 실행어(경로 basename 비교)
    printf '%s' "$fl" | grep -Eqx "${SAFE_READERS}" && return 0 ;;
  esac
  if _db_is_name "$first"; then                                   # ⓑ 도움말·버전뿐이면 통과
    local only=1
    for ((i = k + 1; i < n; i++)); do case "${w[$i]}" in --help|--version|-V|'-?') ;; *) only=0 ;; esac; done
    [ "$only" -eq 1 ] && [ $((n - k)) -gt 1 ] && return 0
    _db_seg_hosts_ok "$1"; return $?
  fi
  case "$first" in \$*|\`*|'('|'{'|'!'|if|then|else|elif|do|while|until) _db_seg_hosts_ok "$1"; return $? ;; esac
  if printf '%s' "$fl" | grep -Eqx "${DB_WRAPPERS}"; then
    # 확실한 래퍼 형태만 벗기고 안쪽 첫 실행어가 통과 실행어면 통과(`xargs grep …`·`timeout 30 grep …`).
    # 옵션 값을 확정할 수 없으면 벗기지 않고 지금처럼 호스트 판정(보수). 안쪽이 DB·모르는 실행어여도 호스트 판정.
    local j=$k inner="" cur
    while [ "$j" -lt "$n" ]; do
      cur=$(printf '%s' "${w[$j]##*/}" | tr 'A-Z' 'a-z')
      case "$cur" in
        timeout) printf '%s' "${w[$((j + 1))]:-}" | grep -Eq '^[0-9]+(\.[0-9]+)?[smhd]?$' || break; j=$((j + 2)) ;;
        xargs)
          j=$((j + 1))
          while [ "$j" -lt "$n" ]; do
            case "${w[$j]}" in
              -0) j=$((j + 1)) ;;
              -n) printf '%s' "${w[$((j + 1))]:-}" | grep -Eq '^[0-9]+$' || break 2; j=$((j + 2)) ;;
              -I) [ -n "${w[$((j + 1))]:-}" ] || break 2; j=$((j + 2)) ;;
              -*) break 2 ;;
              *) break ;;
            esac
          done ;;
        env) j=$((j + 1)); while [ "$j" -lt "$n" ] && printf '%s' "${w[$j]}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; do j=$((j + 1)); done ;;
        command|exec|time|nohup|nice|sudo|stdbuf) case "${w[$((j + 1))]:-}" in -*) break ;; esac; j=$((j + 1)) ;;
        *) inner=$cur; break ;;
      esac
    done
    case "${w[$j]:-}" in \$*|\`*|\\*) inner="" ;; esac
    [ -n "$inner" ] && printf '%s' "$inner" | grep -Eqx "${SAFE_READERS}" && return 0
    _db_seg_hosts_ok "$1"; return $?
  fi
  return 1                                                        # 모르는 실행어(ssh·bash -c 등) 뒤의 DB 낱말 = 차단
}

db_cli_deny=0
# 커밋 메시지 히어독(`git commit -F - <<'EOF'` · `--file=-`)의 본문은 git 이 표준입력으로 읽는 데이터다 — 이 훅의 CLI 판정
# 에서만 걷는다(lib 의 히어독 허용 목록은 여러 가드가 공유해 넓히지 않는다). 그 줄 자체(git …)는 그대로 판정된다.
db_src=$(printf '%s\n' "$cmd_nohd" | awk '
  skip { t = $0; if (dash) sub(/^\t+/, "", t); if (t == tok) skip = 0; next }
  {
    if ($0 ~ /(^|[;&|( \t])git([ \t]|$)/ && $0 ~ /[ \t]commit([ \t]|$)/ \
        && $0 ~ /[ \t](-F[ \t]*-|--file[= ]-)([ \t]|$)/ \
        && match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      tok = substr($0, RSTART, RLENGTH); dash = (tok ~ /^<<-/)
      sub(/^<<-?[ \t]*["\047]?/, "", tok); sub(/["\047]$/, "", tok); skip = 1
    }
    print
  }') || db_src="$cmd_nohd"
# 빠른 경로 — 정밀 판정은 낱말마다 프로세스를 띄워 긴 명령에서 수백 ms 가 든다(모든 Bash 호출에서 돈다).
# 백슬래시·따옴표만 지운 사본에 DB 낱말(DB_CLI_NAMES 를 부분 문자열 정규식으로)이 하나도 없으면 건너뛴다.
# 따옴표·이스케이프를 먼저 지우므로 m''ysql·\mysql·"my""sql" 은 여기 걸리지 않고 정밀 판정으로 간다.
# tr 이 실패하거나 grep 이 오류(2)면 건너뛰지 않는다(fail-closed — 정밀 판정으로 떨어진다).
db_need=1
# tr 인자는 8진(\042 " · \047 ' · \134 \) — 문자 그대로 쓰면 tr 이 인자 속 \ 를 이스케이프로 먹는다.
if db_fast=$(printf '%s' "$db_src" | tr -d '\042\047\134' 2>/dev/null); then
  printf '%s' "$db_fast" | grep -Eiq -- "${DB_CLI_NAMES}" 2>/dev/null
  [ $? -eq 1 ] && db_need=0
fi
if [ "$db_need" -eq 0 ]; then
  :
elif norm=$(_db_norm "$db_src"); then
  while IFS= read -r seg; do
    _db_seg_ok "$seg" || { db_cli_deny=1; break; }
  done <<EOF_SEGS
$norm
EOF_SEGS
else
  # 정규화 실패(닫히지 않은 따옴표 등) — DB 낱말이 보이면 차단(fail-closed), 없으면 통과.
  printf '%s' "$db_src" | tr -c 'A-Za-z0-9_-' '\n' | tr 'A-Z' 'a-z' | grep -Eqx "${DB_CLI_NAMES}" && db_cli_deny=1
fi

[ "$db_cli_deny" -eq 1 ] || exit 0
_deny "허용 호스트(dev·로컬) 목록에 없는 직접 DB 접속 명령입니다. 한 세그먼트에 허용/비허용 호스트가 섞여 있으면 전부 허용일 때만 통과합니다. 로컬 호스트(localhost/127.0.0.1)도 표준 포트(${ALLOWED_DB_PORTS_REGEX}) 외면 차단됩니다 — SSH 로컬 포워딩 종단(예: -L 33306 → 배포 dev DB)일 수 있기 때문입니다."
