#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=통과
# PreToolUse(Bash) 가드 — "푸시 = 사용자 전담"(처분 project:작업안전:11 / 프로젝트 CLAUDE.md 🛡️작업 안전)의 강제화.
# 에이전트가 치는 Bash 명령에 git push 호출이 들어 있으면 차단한다. 에이전트 몫은 커밋까지이고,
# 원격 반영은 사용자가 직접 친다(에이전트는 커밋 해시까지만 보고).
#
# 왜 훅인가: 푸시는 로컬에서 되돌릴 수 없는 유일한 경계(원격 공개)다. 규약 문장만으로는
# `cd x && git push` 같은 체인·래핑 형태에서 조용히 새어 나간다 — 판정을 기계화한 것이 이 훅이다.
#
# 우회(사용자가 명시적으로 허용했을 때만): 명령 앞에 ALLOW_GIT_PUSH=1 을 붙인다.
#   강제 푸시(-f·--force*·+refspec)는 바로 뒤에 ALLOW_GIT_FORCE_PUSH=1 까지 붙여야 열린다(ALLOW_GIT_PUSH=1 ALLOW_GIT_FORCE_PUSH=1 <명령>).
#   원격 삭제·미러(--mirror·--delete·--prune·-d·:ref)도 강제와 같이 두 대입을 요구한다(아래 허락 재확인 관문 G-P).
#   셸 변수 대입 형태로만 인정한다 — 줄 단위 원문 판정(줄머리 또는 ; & | 뒤)을 통과한 뒤, G-P 가 그 대입이 푸시 호출과
#   같은 세그먼트의 머리에 있는지(인용·주석 속 문구나 다른 세그먼트의 대입이 아닌지) 토큰 단위로 다시 본다.
#
# 한계(알고 쓰는 것):
#   - 판정은 정규식이라 셸 문법을 완전히 파싱하지 못한다. 변수 조립(`g=git; $g push`)·별칭은 미탐이다.
#     의도적 우회를 막는 장치가 아니라 **실수 방지**용이다.
#   - 서브커맨드가 push 인 형태만 본다 → `git subtree push …`·`git svn dcommit` 같은 우회 경로는 미탐이다
#     (처분표 사양이 git push 로 한정 — 필요해지면 판정식에 중간 토큰 1개를 허용하도록 확장).
#   - 인용부 안의 문자열은 판정 전에 지운다(처분 mechanizeSpec 의 `git_strip_quoted` 계약) →
#     `grep -rn "git push" <파일>` · `echo '… git push …'` · 그 문구가 든 커밋 메시지처럼
#     **따옴표로 감싼** 읽기전용·안내문은 걸리지 않는다(2026-09-18 실측). 따옴표가 아닌 인용 형태
#     (히어독 `<<EOF … EOF` 본문 등)는 스트립 대상이 아니라 그 안의 문구도 여전히 차단된다 —
#     문서·스크립트를 히어독으로 쓸 땐 문구를 변수로 조립하거나 ALLOW_GIT_PUSH=1 로 진행한다.
#     다만 셸 래퍼(`sh -c "…"`·`bash -lc "…"`)는 따옴표 안이 곧 실행될 명령이므로 원문 그대로 판정한다
#     — 여기서 스트립하면 래핑 우회가 되살아난다.
#     스트립의 대가: 따옴표로 감싼 실제 푸시를 다른 인터프리터가 실행하는 형태는 미탐이 된다
#     (변수 조립과 같은 등급의 의도적 우회 — 이 가드는 실수 방지용이다).
#   - 범위는 **Bash 도구 호출**뿐이다. 다른 훅이 자기 안에서 실행하는 푸시(예: mirror-history.sh 의
#     MIRROR_PUSH 옵트인)는 도구 권한 경로를 타지 않으므로 여기서 보이지 않는다.
#   - stdin JSON 파서(jq 또는 python3)가 둘 다 없으면 조용히 통과한다.
# ponytail: 파서 부재 시 fail-open / 업그레이드 경로 = sed 기반 최소 추출기 추가
#
# 안전: 파서 부재·JSON 파싱 실패·빈 명령·푸시 아님 → 조용히 exit 0. 다른 Bash 호출을 방해하지 않는다.
set -u

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

# stdin JSON 만 신뢰한다(환경변수·인자로 명령을 받지 않는다).
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)
else
  exit 0
fi
[ -n "$cmd" ] || exit 0

# git 서브커맨드 탐지 — 킷 스캐폴드 lib(~/.claude/agent-scaffold/claude/hooks/lib/git-cmd.sh — 프로젝트 레포 lib 의 배포원)의
# 판정 본문(_GIT_OPTVAL 정의 줄 + git_unfold_lines + git_has_subcommand)을 옮긴 것이다. 전역 층에는 공유 lib 디렉터리가 없어 여기 인라인으로 둔다
#   (레포 밖에서도 단독 동작해야 한다). 동기화 = 그 파일과 diff
# ponytail: 인라인 사본이라 lib 를 고치면 여기도 함께 고쳐야 한다 / 업그레이드 = 전역 층에서 source 할 공용 lib.
# git 과 서브커맨드 사이에 전역옵션(-C /x · -c k=v · --git-dir=/x · --work-tree /x · 단일 플래그)이
# 0개 이상 끼어도 매칭하고, 선행 문맥은 줄머리·구분자(| ; &)·괄호·따옴표·경로 접두(/usr/bin/git)를 인정한다.
# 서브커맨드는 독립 토큰이어야 하므로 `git log --grep=push` 류는 비매칭이다.
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

# 따옴표 안 문자열 제거 — 프로젝트 lib/git-cmd.sh 의 git_strip_quoted 와 동일 계약(전역층엔 lib 가 없어 인라인).
# 셸 래퍼(sh -c "…")는 따옴표 안이 곧 실행될 명령이므로 원문을 그대로 돌려준다.
git_strip_quoted() {
  if printf '%s' "$1" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?(sh|bash|zsh|env)[[:space:]]+(-[A-Za-z]*c|-c)"; then
    printf '%s' "$1"
    return 0
  fi
  printf '%s' "$1" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g'
}

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
# 알려진 한계(정규식 게이트의 천장): 다음 Bash 호출에서 실행 · 변수 조립 후 eval · 데이터 확장자로 쓴 뒤 실행 ·
#   fail-closed 오탐 = 싱크로 넘기는 파이프(`| tee x.md`)·변수 대상(`> $OUT`)·줄을 넘긴 `$((`·따옴표 든 tee 인자.
#   · 미탐 = 토큰 단어 안에 인용·이스케이프가 섞인 형태(`<<X\"y`·`<<E"O"F`) — 토큰을 잘못 읽어 종료 줄을 못 찾고
#   뒤 줄까지 본문으로 삼킨다(실사용 확률 낮음, 2026-09-18 T1 실측 — 고치려면 mask 의 keep·토큰 정규식·역인용을 함께).
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

git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" push || exit 0

# 명시적 우회 — 셸 변수 대입 형태로만. 강제 푸시(-f 묶음·--force*·축약 --for…·+refspec)는 ALLOW_GIT_FORCE_PUSH=1 까지 요구한다
# (일반 푸시 허락이 원격 이력 덮어쓰기까지 여는 것을 막는다).
# ponytail: 강제 판정은 따옴표·히어독을 걷은 명령 전체 텍스트 — 같은 명령의 다른 세그먼트 -f(rm -f·tail -f·--format 등)도 강제로 보아 더 엄격하다
#   (따옴표로 감싼 단일 강제 토큰 "-f"·"+main" 은 아래 G-P 가 토큰 단위로 본다) / 세그먼트 단위 판정
# 일반 허락 판정은 HEAD 와 같은 식을 원문에 그대로 쓴다(넓히면 인용 속 문구가 대입처럼 보이는 회귀가 났다 — 2026-11-17 재리뷰 4라운드).
# 위 줄 단위 원문 판정은 인용·주석 속 "; ALLOW_…" 꼴과 다른 세그먼트의 대입에도 맞는다 → 통과시키기 전에 아래 허락 재확인 관문을 거친다.
# 출력 = deny JSON 하나(호출부가 출력 뒤 바로 종료한다).
deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    HOOK_DENY_REASON="$1" python3 -c 'import json,os,sys
json.dump({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
          "permissionDecisionReason":os.environ.get("HOOK_DENY_REASON","")}}, sys.stdout, ensure_ascii=False)'
  fi
}

# 허락 재확인 관문 G-P — 위 허락 식이 맞고 강제 판정에도 걸리지 않은 호출에만 돈다(바뀌는 방향은 통과 → deny 뿐).
#   히어독을 걷은 명령을 shlex(posix, 따옴표 밖 줄바꿈 = ;, 따옴표 밖 낱말 머리 # = 주석)로 세그먼트로 나눠
#   git … push 세그먼트마다 ①머리 대입(VAR=…)들 안에 ALLOW_GIT_PUSH=1 이 있어야 하고
#   ②원격 삭제·미러·강제 토큰(--mirror·--delete·--prune 과 그 축약, -*d* 묶음, :ref, 따옴표를 벗긴 강제 토큰)이 있으면
#   그 바로 뒤에 ALLOW_GIT_FORCE_PUSH=1 대입이 있어야 한다. 출력 = 거부 사유(빈 출력 = 통과).
#   전체 파싱 실패(ValueError — 걷지 않은 히어독 본문의 아포스트로피 등)면 줄 단위로 다시 나누고, 파싱 안 되는 줄에
#   git 낱말과 push 가 함께 있으면 거부한다. push 세그먼트를 못 찾음·python 실패 = 거부(판정 불가).
# ponytail: 셸 래퍼(sh -c "…") 안의 푸시는 세그먼트로 보이지 않는다 — 보이는 푸시 세그먼트가 하나도 없으면 판정 불가로
#   거부되지만, 있으면 래퍼 안은 판정 밖이라 통과한다 · ANSI-C 인용 $'…' 안의 \' 는 shlex 가 닫히지 않은 따옴표로 읽는다 ·
#   줄 단위 폴백은 여러 줄 인용과 줄 경계가 어긋나게 조립한 명령을 bash 와 다르게 나눌 수 있다
#   / 업그레이드 = 셸 -c 본문 재귀(파괴 명령 가드 G-D2 와 같은 방식)·$'…' 해석·bash 파서 사용
gate_allow() {
  CMD="$1" python3 -I - <<'PY'
import os, re, shlex
def segments(s):
    """세그먼트(낱말 목록) 목록. 닫히지 않은 따옴표 등은 ValueError."""
    out, q, i, n = [], "", 0, len(s)
    while i < n:  # 따옴표 밖 줄바꿈 → ';' · \+줄바꿈 → 공백 · 따옴표 밖 낱말 머리 '#' ~ 줄 끝 제거
        c = s[i]
        if q == "'":
            out.append(c); q = "" if c == "'" else q
        elif q == '"':
            out.append(c)
            if c == "\\" and i + 1 < n: out.append(s[i + 1]); i += 1
            elif c == '"': q = ""
        elif c == "\\" and i + 1 < n:
            out.append(" " if s[i + 1] == "\n" else c + s[i + 1]); i += 1
        elif c in "'\"":
            q = c; out.append(c)
        elif c == "#" and (not out or out[-1][-1] in " \t;&|()"):
            while i + 1 < n and s[i + 1] != "\n": i += 1
        elif c == "\n":
            out.append(";")
        else:
            out.append(c)
        i += 1
    lex = shlex.shlex("".join(out), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True; lex.commenters = ""
    segs, cur = [], []
    for t in lex:
        if t and set(t) <= set(";&|()"):
            if cur: segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur: segs.append(cur)
    return segs
s = os.environ["CMD"]
try:
    segs = segments(s)
except ValueError:  # 걷지 않은 히어독 본문의 아포스트로피 등 — 줄 단위로 다시 나누고, 파싱 안 되는 줄에 git·push 가 함께 있으면 거부
    segs = []
    for line in s.replace("\\\n", " ").split("\n"):
        try:
            segs.extend(segments(line))
        except ValueError:
            if re.search(r"(^|[^A-Za-z0-9_.-])git([^A-Za-z0-9_-]|$)", line) and "push" in line:
                print("판정 불가(푸시가 든 줄의 닫히지 않은 따옴표 등)"); raise SystemExit(0)
RES = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "time"}
VALOPTS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--exec-path")
found = False
for a in segs:
    while a and a[0] in RES: a = a[1:]
    head = []
    for x in a:
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", x): break
        head.append(x)
    for g, x in enumerate(a):
        if os.path.basename(x) != "git": continue
        j = g + 1
        while j < len(a) and a[j].startswith("-"):
            j += 2 if a[j] in VALOPTS else 1
        if j >= len(a) or a[j] != "push": continue
        found = True
        if "ALLOW_GIT_PUSH=1" not in head:
            print("허락 대입(ALLOW_GIT_PUSH=1)이 이 푸시 세그먼트 머리에 없음"); raise SystemExit(0)
        rest = a[j + 1:]
        opts = rest[:rest.index("--")] if "--" in rest else rest
        risky = [y for y in opts if any(len(y) >= 4 and full.startswith(y) for full in ("--mirror", "--delete", "--prune"))
                 or re.fullmatch(r"-[a-zA-Z]*[df][a-zA-Z]*|--for[a-z-]*(=.*)?", y)]
        risky += [y for y in rest if (y.startswith(":") and len(y) > 1) or re.fullmatch(r"\+.+", y)]
        k = head.index("ALLOW_GIT_PUSH=1")
        if risky and head[k + 1:k + 2] != ["ALLOW_GIT_FORCE_PUSH=1"]:
            print("원격 삭제·미러·강제 형태(" + " ".join(risky[:3]) + ") — ALLOW_GIT_PUSH=1 바로 뒤에 ALLOW_GIT_FORCE_PUSH=1 필요"); raise SystemExit(0)
        break
if not found:
    print("판정 불가(허락 문구는 있으나 git push 세그먼트를 읽지 못함)")
PY
}

_stripped=$(git_strip_quoted "$(git_strip_heredoc "$cmd")")
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_GIT_PUSH=1[[:space:]]'; then
  if printf '%s' "$_stripped" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--for[a-z-]*(=[^[:space:]]*)?|\+[^[:space:]]+)([[:space:]]|$)' \
     && ! printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_GIT_PUSH=1[[:space:]]+ALLOW_GIT_FORCE_PUSH=1[[:space:]]'; then  # 일반 허락 바로 뒤 대입으로만
    deny "[푸시 가드] 강제 푸시 — ALLOW_GIT_PUSH=1 만으로는 열리지 않습니다.
원격 이력을 덮어쓰는 푸시(-f·--force·--force-with-lease·+refspec)입니다. 사용자가 강제 푸시를 명시적으로 지시했을 때만
'ALLOW_GIT_PUSH=1 ALLOW_GIT_FORCE_PUSH=1 <명령>' 으로 다시 실행하세요."
    exit 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    _g=$(gate_allow "$(git_strip_heredoc "$cmd")" 2>/dev/null) || _g="판정 불가(관문 실행 실패)"
  else
    _g="판정 불가(python3 없음)"
  fi
  if [ -n "$_g" ]; then
    deny "[푸시 가드] 허락 형태 확인 실패 — ${_g}.
ALLOW_GIT_PUSH=1 은 git push 와 같은 세그먼트의 머리에 셸 대입으로 둬야 열립니다(인용·주석 속 문구, 다른 세그먼트의 대입은 인정 안 함).
원격 브랜치 삭제·미러·강제 형태는 'ALLOW_GIT_PUSH=1 ALLOW_GIT_FORCE_PUSH=1 <명령>' 으로만 — 사용자가 그것까지 지시했을 때만 쓰세요."
  fi
  exit 0
fi

reason="[푸시 가드] 푸시는 사용자 전담 — 해시까지만 보고하세요.

이 명령에 git push 호출이 들어 있습니다. 원격 반영은 사용자가 직접 칩니다:
에이전트는 커밋까지만 수행하고, 완료 보고에는 커밋 해시까지만 적습니다(푸시 실행·대행 금지).

  - 커밋이 끝났으면 해시를 보고하고 멈추세요.
  - 푸시가 필요해 보이면 사용자에게 알리되, 대신 실행하지 마세요.
  - 따옴표('…'·"…") 안의 문자열은 판정에서 제외됩니다. 다만 히어독(<<EOF … EOF) 본문처럼
    스트립이 보지 못하는 인용 형태와 셸 래퍼(sh -c "…") 안은 그대로 판정하므로, 실제 푸시가
    아닌데 막혔다면 그 문구를 변수로 조립하거나 아래 우회를 쓰세요.

사용자가 이번 푸시를 명시적으로 지시한 경우에만 'ALLOW_GIT_PUSH=1 <명령>' 형태로 다시 실행하세요."

deny "$reason"
exit 0
