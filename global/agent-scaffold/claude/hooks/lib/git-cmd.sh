#!/usr/bin/env bash
# 공용 라이브러리 — git 서브커맨드 탐지(DRY). 소비 훅 모집단 = `grep -ln git_has_subcommand .claude/hooks/*.sh`.
# git 과 SUBCMD 사이에 전역옵션이 0개 이상 끼어도 매칭한다(옵션 값 = 아래 _GIT_OPTVAL 허용 형태 — 공백 든 따옴표 값 포함):
#   -C /path(공백형) · -c k=v · --long[=val] ·
#   --git-dir /x · --work-tree /x(공백-값형 롱옵션) · 단일 플래그(-p 등).
#   ※ 붙임형 -C/path 도 매칭하지만 이는 방어심층일 뿐 — git 자신이 'unknown option'으로 거부하는
#     비-유효 문법이라 실제 우회 벡터는 아니다(2026-07-10 실측: `git -C/tmp …` → unknown option).
# 반면 'git log --grep=commit' · 'git config commit.x' 류는 비매칭 유지(SUBCMD 가 독립 토큰이어야 함).
# 선행 문맥은 줄머리·구분자(| ; &)·공백 외에 서브셸/그룹 여는 괄호와 따옴표·백틱·$( 도 인정하고,
#   git 앞의 경로 접두(/usr/bin/git)도 허용한다 — `sh -c "git commit …"`·`(git commit …)`·절대경로 호출이
#   전부 미탐이던 구멍을 막는다(2026-08-05 감사 실측: 세 커밋 게이트가 한 줄 래핑으로 동시 무력화).
# ※ 한계(정규식 파싱의 천장): 셸 문법을 정규식으로 완전히 파싱할 수는 없다. 이 게이트는 **실수 방지**용이며
#   의도적 우회를 막지 못한다(예: 변수 조립 `g=git; $g commit`). fail-closed 가 필요한 층은 별도 수단으로 이중화한다.
# 사용: git_has_subcommand "$cmd" commit   → rc 0 이면 해당 서브커맨드 호출.
#      git_strip_quoted "$cmd"             → 따옴표 안 문자열을 제거한 사본(넛지형 훅의 오탐 억제용).
#      git_commit_call_form "$cmd" "$cwd"   → NONE | ALLOW | DENY<TAB>사유 — 커밋 게이트의 PreToolUse 경로 판정(허용 형태,
#                                             판정기 = 같은 디렉터리의 cmdform.py). 층 A(git 훅) 경로는 git_has_subcommand 를 쓴다.
#
# 배경: ①여러 가드가 동일 정규식을 복붙(수정 시 사본마다 동기화)하던 것을 공용 lib로 통합(DRY).
#   ②옵션 커버리지 보강 — 실제 유효 git 문법이면서 지난 세션 정규식이 놓치던 '공백-값형 롱옵션'
#     (예: `git --git-dir /x commit` — 2026-07-10 실측 유효)을 여기서 포함. (붙임형 -C/path 는 위 주석대로 비-위협.)
# 옵션 값 한 낱말의 허용 형태 = 큰따옴표 조각("…")·작은따옴표 조각('…')·맨 글자 조각의 연결
#   (`user.name="A B"` · `"/a b"` · `'x y'`) 또는 종전 형태(공백 없는 한 덩어리 — 짝 안 맞는 따옴표 포함).
#   따옴표 조각 안의 공백은 값의 일부다. 따옴표 조각은 한 줄 안에서만 짝짓는다(grep 이 줄 단위).
_GIT_OPTVAL="((\"[^\"]*\"|'[^']*'|[^[:space:]\"'])+|[^[:space:]]+)"
git_unfold_lines() {
  # 줄 잇기(\+LF)를 공백 1칸으로 편다(그 밖 바이트 불변) → 결과 = 전역 _GIT_UNFOLDED. 종전 ${s//$'\\\n'/ } 와 같은 결과다.
  # 그 치환은 bash 3.2 에서 줄 잇기 수·길이에 비선형이라(실측 10만 자·줄 잇기 400 = 160s) 훅 timeout(fail-open)에 걸린다
  #   → 줄 잇기가 있을 때만 sed 한 번(H 로 모아 s///g 한 번 — 선형). 끝 개행은 센티널 x 로 보존, LC_ALL=C = 비 UTF-8 바이트 그대로.
  #   sed 가 없거나 실패하면(센티널 소실) 종전 치환으로 폴백한다 — 느려도 결과는 같다.
  case $1 in
    *$'\\\n'*)
      if _GIT_UNFOLDED=$(printf '%sx' "$1" | LC_ALL=C sed -n 'H;${x;s/\\\n/ /g;s/^\n//;p;}') && [ "${_GIT_UNFOLDED%x}" != "$_GIT_UNFOLDED" ]; then _GIT_UNFOLDED=${_GIT_UNFOLDED%x}
      else _GIT_UNFOLDED=${1//$'\\\n'/ }; fi ;;
    *) _GIT_UNFOLDED=$1 ;;
  esac
}
git_has_subcommand() {
  # 줄 잇기(\+개행)는 펴고 본다 — `git \⏎ commit` 은 한 명령이다. 명령 이름 앞 `\`(별칭 회피 `\git`)도 인정한다.
  local _s; git_unfold_lines "$1"; _s=$_GIT_UNFOLDED
  printf '%s' "$_s" | grep -Eq "(^|[|;&({\`\"'[:space:]])\\\\?([^[:space:]]*/)?git([[:space:]]+(-[cC][[:space:]]*$_GIT_OPTVAL|--(git-dir|work-tree|namespace|super-prefix|exec-path)([[:space:]]+|=)$_GIT_OPTVAL|--[A-Za-z][A-Za-z0-9-]*(=$_GIT_OPTVAL)?|-[A-Za-z]))*[[:space:]]+$2([^[:alnum:]_]|\$)"
}

# 따옴표(작은·큰) 안의 문자열을 지운 사본을 표준출력으로 낸다.
# 안내문·echo 라벨에 'git commit' 이 인용된 것만으로 발동하면 안 되는 훅 — 리마인더와, 마커 지문·기록으로
# 판정하는 게이트(code-review-marker 는 deny 형이다) — 이 오탐으로 막히거나 그날 1회 기회를 소진하는 것을 막는다.
# ※ 스테이징 실물(.java·.sql·시크릿·테스트 수·프로파일 키)을 검사하는 가드는 따옴표 스트립을 쓰지 않고 인용 안의
#   명령도 판정한다. 히어독 판정(아래 git_strip_heredoc)은 두 부류 모두 같은 허용 목록 규칙을 쓴다.
#   각 규칙을 쓰는 훅 모집단 = `grep -l git_strip_quoted .claude/hooks/*.sh` · `grep -l git_strip_heredoc .claude/hooks/*.sh`.
# ※ 셸 래퍼(sh -c "…" · bash -lc "…")는 따옴표 안이 곧 실행될 명령이므로 스트립하지 않고 원문을 돌려준다
#   — 스트립하면 위에서 막 메운 래핑 미탐이 넛지 훅에서만 되살아난다.
# 히어독 판정 — **본문을 걷어내지 않는 것이 기본**이고, 아래를 모두 만족할 때만 본문을 걷어낸 사본을 낸다.
#   ⓐ 히어독을 받는 명령(그 세그먼트의 첫 단어 — VAR=·$(·(·{ 는 벗기고, 경로는 떼고 본다)이 데이터 싱크:
#      cat tee grep jq sort head tail wc diff tr cut. (sed 의 e 명령·awk 의 system() 은 실행할 수 있어 제외)
#   ⓑ 같은 줄에서 히어독 뒤로 파이프 하류가 없다(`cat <<EOF | bash` 는 남긴다 — 하류가 싱크여도 남긴다).
#   ⓒ 출력 리다이렉트 대상(tee 는 파일 인자까지)이 없거나 문서·데이터 확장자 또는 /dev/null 이다. 따옴표로 감싼
#      대상은 원문의 같은 자리에서 읽어 판정한다. `> run.sh`·확장자 없는 대상·변수 대상은 남긴다.
#   ⓓ 최상위 단순 명령이다 — `<<` 앞에 닫히지 않은 `(`·`{`·`$(` 가 있거나(단 `이름=$(` 캡처는 예외) 줄이 `\` 로
#      끝나면 남긴다. 그룹·연속행은 파이프 하류가 뒤 줄에 올 수 있고, 맨 `$(…)` 는 출력이 곧 실행되기 때문이다.
# 판정은 가린 사본으로 한다: 인용 안·백슬래시 이스케이프·인용 밖 `#` 주석·`$((…))` 산술의 << 는 히어독 시작이
#   아니다. 단 `<<` 뒤 토큰 단어 안의 백슬래시는 토큰 인용(`<<\EOF`·`<<E\OF` = `<<'EOF'`)이라 가리지 않는다.
#   토큰은 한 단어이고 종료 줄은 bash 의미대로 찾는다(`<<` = 줄 전체 동등, `<<-` = 앞 탭만 떼고 동등 — 본문 속
#   들여쓴 `  EOF` 는 종료가 아니다). 한 줄의 히어독 여러 개는
#   나온 순서대로 본문을 소비한다.
# (2026-09-18 교차 리뷰 G1~G3·재설계 R1~R6 — 종전 규칙 "걷어내되 인터프리터면 남긴다" 는 금지 목록이었다.)
# 구분자 토큰은 순수형 4종만 인정한다 — `EOF` · `'EOF'` · `"EOF"` · `\EOF`(이름 = [A-Za-z_][A-Za-z0-9_]*).
#   그 밖(`<<E\OF`·`<<"E"OF`·`<<E"OF"`·`<<X\"y`)이 **하나라도** 있으면 어떤 본문도 걷지 않고 원문을 그대로 낸다
#   (토큰을 잘못 읽어 종료 줄을 못 찾고 뒤 줄 명령까지 본문으로 삼키던 미탐을 닫는다 — 걷지 않으면 원문 전체가 판정된다).
# 알려진 한계(정규식 게이트의 천장): 다음 Bash 호출에서 실행 · 변수 조립 후 eval · 데이터 확장자로 쓴 뒤 실행 ·
#   fail-closed 오탐 = 싱크로 넘기는 파이프(`| tee x.md`)·변수 대상(`> $OUT`)·줄을 넘긴 `$((`·따옴표 든 tee 인자·
#   순수형이 아닌 구분자가 든 명령의 모든 히어독 본문.
git_strip_heredoc() {
  printf '%s' "$1" | awk '
    function mask(s,   i, j, k, m, n, c, out, q, keep) {
      out = ""; q = ""; keep = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == sq) {                                  # 홑따옴표 안 — 이스케이프가 없다
          if (c == sq) { q = ""; out = out c } else out = out (keep ? c : " ")
          continue
        }
        if (c == "\\" && i < n) {
          if (q == "" && out ~ /<<-?[[:space:]]*[^[:space:]<>;|&()"'"'"']*$/) { out = out c; continue }   # <<\EOF·<<E\OF — 토큰 인용
          out = out "  "; i++; continue                 # 이스케이프된 글자까지 가린다
        }
        if (q == "\"") {
          if (c == "\"") { q = ""; out = out c } else out = out (keep ? c : " ")
          continue
        }
        if (c == "\"" || c == sq) { keep = (out ~ /<<-?[[:space:]]*$/); q = c; out = out c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) {   # 인용 밖 주석 — 줄 끝까지
          for (; i <= n; i++) out = out " "
          break
        }
        if (substr(s, i, 3) == "$((") {                 # 산술 확장 — 짝 )) 까지
          j = index(substr(s, i + 3), "))")
          m = j ? j + 4 : n - i + 1
          for (k = 0; k < m; k++) out = out " "
          i += m - 1
          continue
        }
        out = out c
      }
      return out
    }
    function grouped(pre,   i, c, n, st, k) {       # << 앞에 닫히지 않은 그룹·명령 치환이 있나(캡처 대입 제외)
      n = 0
      for (i = 1; i <= length(pre); i++) {
        c = substr(pre, i, 1)
        if (c == "(") {
          if (i > 1 && substr(pre, i - 1, 1) == "$")
            st[++n] = (substr(pre, 1, i - 2) ~ /(^|[[:space:];|&])[A-Za-z_][A-Za-z0-9_]*=$/) ? "cap" : "sub"
          else st[++n] = "grp"
        } else if (c == "{") {
          st[++n] = (i > 1 && substr(pre, i - 1, 1) == "$") ? "var" : "grp"
        } else if (c == ")" || c == "}") {
          if (n > 0) n--
        }
      }
      for (k = 1; k <= n; k++) if (st[k] == "grp" || st[k] == "sub") return 1
      return 0
    }
    function firstword(seg,   w) {
      sub(/^[[:space:]]+/, "", seg)
      while (1) {
        if (match(seg, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          seg = substr(seg, RLENGTH + 1)
          if (substr(seg, 1, 2) == "$(") { seg = substr(seg, 3) } else { sub(/^[^[:space:]]*/, "", seg) }
          sub(/^[[:space:]]+/, "", seg); continue
        }
        if (substr(seg, 1, 2) == "$(") { seg = substr(seg, 3); sub(/^[[:space:]]+/, "", seg); continue }
        if (seg ~ /^[({]/) { seg = substr(seg, 2); sub(/^[[:space:]]+/, "", seg); continue }
        break
      }
      w = ""
      if (match(seg, /^[^[:space:]<>]+/)) w = substr(seg, 1, RLENGTH)
      sub(/.*\//, "", w)
      return w
    }
    function doctarget(t) {
      if (t == "/dev/null") return 1
      return (tolower(t) ~ /\.(md|txt|json|sql|xml|yaml|yml|properties|html|css|csv|log|conf|diff|patch)$/)
    }
    function strippable(seg, oseg, fw, tok,   rest, base, st, len, t, tp, q1, ot, k, nw, w, i, after) {
      if (!(fw in SINK)) return 0
      rest = seg; base = 0
      while (match(rest, />>?[[:space:]]*[^[:space:];|<>]*/)) {
        st = base + RSTART; len = RLENGTH
        t = substr(seg, st, len); sub(/^>>?[[:space:]]*/, "", t)
        tp = st + len - length(t)                       # 대상의 시작 위치(seg 기준, 원문과 같은 자리)
        base = st + len - 1; rest = substr(seg, base + 1)
        if (t ~ /^&[12]$/) continue                     # 2>&1·>&2 — 표준 출력·오류로의 복제(>&3 처럼 모르는 fd 는 남긴다)
        q1 = substr(t, 1, 1)
        if (q1 == "\"" || q1 == sq) {                   # 따옴표로 감싼 대상 — 원문에서 닫는 따옴표까지 읽는다
          ot = substr(oseg, tp + 1); k = index(ot, q1)
          t = k ? substr(ot, 1, k - 1) : ""
        }
        if (t == "" || !doctarget(t)) return 0          # 판정 불가·실행될 만한 대상 = 남긴다
      }
      if (fw == "tee") {                                # tee 는 파일 인자도 쓰기 대상이다
        nw = split(seg, w, /[[:space:]]+/); after = 0
        for (i = 1; i <= nw; i++) {
          if (!after) { if (w[i] ~ /(^|\/)tee$/) after = 1; continue }
          if (w[i] == "" || w[i] ~ /^[-<>]/ || w[i] == tok) continue
          if (!doctarget(w[i])) return 0
        }
      }
      return 1
    }
    function issep(s, k,   c, p) {                      # ;|& 세그먼트 경계(>& <& 의 & 는 fd 문법이라 제외)
      c = substr(s, k, 1); p = (k > 1) ? substr(s, k - 1, 1) : ""
      if (c == ";" || c == "|") return 1
      return (c == "&" && p != ">" && p != "<")
    }
    BEGIN {
      sq = sprintf("%c", 39)
      split("cat tee grep jq sort head tail wc diff tr cut", a, " ")
      for (i in a) SINK[a[i]] = 1
      qn = 0; qi = 1; impure = 0; orig = ""; buf = ""
      nm = "[A-Za-z_][A-Za-z0-9_]*"                     # 순수형 4종 = NAME · 'NAME' · "NAME" · \NAME
      PURE = "^(" nm "|" sq nm sq "|\"" nm "\"|\\\\" nm ")$"
    }
    {
      orig = orig $0 "\n"                              # 순수형이 아닌 구분자가 보이면 END 에서 원문 전체를 낸다
      if (qi <= qn) {                                   # 히어독 본문 안 — 순서대로 소비한다
        tl = $0; if (QD[qi]) sub(/^\t+/, "", tl)
        if (tl == QT[qi]) { if (!QS[qi]) buf = buf $0 "\n"; qi++; next }
        if (!QS[qi]) buf = buf $0 "\n"
        next
      }
      qn = 0; qi = 1
      d = $0
      gsub(/<<</, "   ", d)                             # here-string(<<<word)은 히어독이 아니다
      d = mask(d)
      cont = ($0 ~ /\\$/)                               # 연속행 — 파이프 하류가 다음 줄에 올 수 있다
      off = 0; rest = d
      while (match(rest, /<<-?[[:space:]]*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]<>;|&()"'"'"']+)/)) {
        p = off + RSTART; L = RLENGTH
        t = substr(d, p, L); sub(/^<<-?[[:space:]]*/, "", t)
        nx = substr(d, p + L, 1)                        # 토큰 단어가 매치 뒤로 이어지면(<<"E"OF·<<E"OF") 섞인 형태
        if ((nx != "" && nx !~ /[[:space:]<>;|&()]/) || t !~ PURE) impure = 1
        gsub(/["'"'"'\\]/, "", t)
        s0 = 0; for (k = p - 1; k >= 1; k--) if (issep(d, k)) { s0 = k; break }
        e0 = 0; for (k = p + L; k <= length(d); k++) if (issep(d, k)) { e0 = k; break }
        sl = (e0 ? e0 : length(d) + 1) - s0 - 1
        seg = substr(d, s0 + 1, sl); oseg = substr($0, s0 + 1, sl)
        pipe = (e0 && substr(d, e0, 1) == "|" && substr(d, e0 + 1, 1) != "|")
        qn++; QT[qn] = t; QD[qn] = (substr(d, p, 3) == "<<-")
        QS[qn] = (!pipe && !cont && !grouped(substr(d, 1, p - 1)) \
                  && strippable(seg, oseg, firstword(substr(d, s0 + 1, p - 1 - s0)), t))
        off = p + L - 1; rest = substr(d, p + L)
      }
      buf = buf $0 "\n"
    }
    END { printf "%s", (impure ? orig : buf) }'
}

git_strip_quoted() {
  if printf '%s' "$1" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?(sh|bash|zsh|env)[[:space:]]+(-[A-Za-z]*c|-c)"; then
    printf '%s' "$1"
    return 0
  fi
  printf '%s' "$1" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g'
}

# ── 커밋 호출 형태 판정(커밋 게이트의 PreToolUse 경로 공용) ───────────────────────────────────
# 정규식으로 "대상 레포가 어디인가"를 맞히는 대신, 허용 형태(단독 커밋 + 같은 레포 cd + 읽기 전용 동행)로 확정될 때만
#   ALLOW 한다. 문법 정본 = cmdform.py judge_commit. 출력 = NONE(커밋 아님) · ALLOW · DENY<TAB>사유 — 판정 불가는 DENY.
# 시간 상한 = timeout 5(있으면) + 판정기 내부 상한. 판정기 rc≠0·형식 밖 출력 = DENY(fail-closed).
# 판정기(python3·cmdform.py)를 부를 수 없으면 _git_commit_form_fallback 으로 떨어진다.
git_commit_call_form() { # $1 = 명령 원문, $2 = 입력 cwd
  local _py _out _rc _f
  # 빠른 경로 — 따옴표·백슬래시·줄바꿈을 지운 사본에 commit 부분 문자열이 없고 $'…'(ANSI-C 인용)도 없으면 판정기를 띄우지 않는다
  #   (판정기의 NONE 조건보다 넓은 상위 집합 — 모든 Bash 호출에서 도는 경로라 python 기동 비용을 아낀다). tr 실패 = 판정기로.
  case "$1" in
    *"\$'"*) ;;
    *) if _f=$(printf '%s' "$1" | tr -d '\042\047\134\n' 2>/dev/null); then
         case "$_f" in *commit*) ;; *) echo NONE; return 0 ;; esac
       fi ;;
  esac
  _py="${BASH_SOURCE[0]%/*}/cmdform.py"
  if command -v python3 >/dev/null 2>&1 && [ -f "$_py" ]; then
    if command -v timeout >/dev/null 2>&1; then
      _out=$(printf '%s' "$1" | timeout 5 python3 -I "$_py" commit "$2" 2>/dev/null); _rc=$?
    else
      _out=$(printf '%s' "$1" | python3 -I "$_py" commit "$2" 2>/dev/null); _rc=$?
    fi
    if [ "$_rc" -eq 0 ]; then
      case "$_out" in
        NONE|ALLOW|"DENY	"*) printf '%s\n' "$_out"; return 0 ;;
      esac
    fi
    printf 'DENY\t판정기 오류(rc=%s — 시간 초과·예외·형식 밖 출력)\n' "$_rc"
    return 0
  fi
  _git_commit_form_fallback "$1"
}

# 판정기 부재 창의 대체 판정 — ①따옴표·백슬래시를 지운 사본에 commit(·commit-tree) 낱말이 없고 $'…' 도 없으면 NONE
#   ②구분자(;&|·개행)·치환($(·백틱)이 없는 단일 단순 명령이고 첫 실행어가 grep·rg·echo·printf·cat·ls 이거나
#   git log·show·status·diff 면 NONE ③그 밖은 DENY(커밋도 막힌다 — lib·python3 복구 후 재시도).
# ponytail: 판정기 부재 창(lib·python3)의 대체 판정은 단일 단순 명령만 구제한다 — gh --body 류 오차단 /
#   업그레이드 = lib 선배치 배포 순서 준수
_git_commit_form_fallback() { # $1 = 명령 원문
  local _s
  local -a _w
  _s=$(printf '%s' "$1" | tr -d '\042\047\134') || { printf 'DENY\t판정기 부재(대체 판정 실패)\n'; return 0; }
  case "$1" in
    *"\$'"*) ;;
    *) printf '%s' "$_s" | grep -Eq '(^|[^A-Za-z0-9_.-])commit(-tree)?([^A-Za-z0-9_.-]|$)' || { echo NONE; return 0; } ;;
  esac
  case "$1" in
    *[\;\&\|\`]*|*'$('*|*$'\n'*) ;;
    *)
      read -ra _w <<<"$_s"
      case "${_w[0]:-}" in
        grep|rg|echo|printf|cat|ls) echo NONE; return 0 ;;
        git) case "${_w[1]:-}" in log|show|status|diff) echo NONE; return 0 ;; esac ;;
      esac ;;
  esac
  printf 'DENY\t판정기 부재(lib/cmdform.py·python3 — 복구 후 재시도)\n'
}

# PreToolUse 경로 deny 안내문(커밋 게이트 공용). 사유 코드는 호출부가 덧붙인다.
git_commit_form_guide() {
  printf '%s' "커밋은 단독 호출로 치세요 — git add·git restore·마커(mark-review.sh)는 앞 호출에서 따로 실행합니다. 다른 레포·linked worktree 의 커밋은 cd·git -C 로 넘기지 말고 그 레포(작업트리)를 연 세션에서 하세요. 메시지는 -m, 히어독(git commit -q -F - <<'EOF' … EOF), 앞 호출에서 써 둔 파일(-F <파일> — 같은 호출에서 파일을 쓰고 커밋하지 않습니다)로 넘깁니다. 허용 형태 = [cd <이 레포> &&] [읽기 전용 git log/status/diff/show·echo·tail 등 &&] [ALLOW_*=1] git commit [-q -s -v --amend --no-edit -m/-F] [| tail 등] [&& 읽기 전용 명령]. 경로 인자·-a·-i·-o·훅 건너뛰기 옵션·git 전역 옵션(-C·-c·--git-dir)·||·&·서브셸·if/for 는 쓰지 않습니다."
}
