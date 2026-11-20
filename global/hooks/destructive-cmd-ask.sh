#!/usr/bin/env bash
# hook-policy: 강제=확인 · 도구부재=통과
# PreToolUse(Bash · 운영 DB MCP) 전역 훅 — 워킹트리·운영 DB 를 건드리는 호출에 사용자 확인(permissionDecision "ask")을 강제한다.
#   settings 의 permissions.ask 는 auto 모드에서 확인창을 띄우지 않았다(2026-10-10 실측 1회) → 훅이 직접 ask 를 반환한다.
#   대상: git checkout -- / . / -f · git restore(인덱스만 되돌리는 --staged/-S 단독 외 전부) · git reset --hard/--merge/--keep(위치 무관) ·
#         git switch -f / --discard-changes · git stash(무인자·push·drop·clear) ·
#         git clean 강제(-f/--force, -n/--dry-run 이면 통과) · find -delete / -exec·-execdir·-ok·-okdir rm|unlink(-exec 뒤 sudo·env·command 등 래퍼는 벗기고 본다 · 시작 경로가 전부 임시 디렉터리면 제외 — rm 과 같은 규칙, -H/-L·식 위치 -follow·-files0-from 이면 제외 없음. 단 -exec 와 rm 사이에 래퍼가 끼거나 rm 에 {} 밖의 대상이 있으면 추가 관문 G-D1 이 그 rm -r 을 대상 기준으로 다시 봐 임시 시작 경로여도 ask) ·
#         git branch 강제 삭제(-D·-Df·--delete --force·-d -f·긴 옵션 축약 등 순서·묶음 무관 — 병합 안 된 커밋 소실. -d 단독은 병합 안 된 브랜치를 git 이 거부하므로 통과) ·
#         rm -r/-R(실행어 basename 기준 — /bin/rm 포함. 대상이 전부 임시 디렉터리면 제외, 단 대상에 { * ? [ $ ` 가 있으면 제외 없음) ·
#         MCP 운영 DB 전 도구(서버명 규칙 — 소문자화해 -db 로 끝나고 개발 DB 접미사(-dev-db·-devserver-db)가 아닌 서버. 아래 MCP 분기 주석).
#   추가 관문(판정 본문 끝 G-D1~G-D4 — 위 판정이 통과시킨 호출에만, 바뀌는 방향은 통과 → ask): 세그먼트 중간 rm·git·find 재판정
#     (예약어 do·then·else·{·! 뒤, xargs·timeout·nice·sudo -u 경유, find -exec 뒤 래퍼를 낀 rm -r) · 셸 -c 본문 재판정(find -exec sh -c 포함) ·
#     git -c clean.* clean · git stash 허용 목록 밖 · 트리+경로 git checkout.
#   ponytail: 경로 하나짜리 git checkout <경로>(브랜치 이름과 구분 불가)·git worktree remove --force·인터프리터 삭제(python shutil.rmtree 등)·
#     gfind·원격 셸(ssh host 'rm …')은 미탐 / 업그레이드 = 레포를 조회해 브랜치·경로 판별, 인터프리터 본문 판정
#   ponytail: G-D1 은 판정되는 줄의 중간 낱말까지 보므로, 걷지 않은 히어독 본문(git commit -F - · python - 본문)이나 따옴표 없는
#     echo 인자의 문장 속 "rm -rf …" 도 ask 가 될 수 있다 / 업그레이드 = -F - 본문 걷기(아래 히어독 ponytail 과 같은 경로)
#   ponytail: only_braces 는 `--` 뒤의 '-' 로 시작하는 낱말도 옵션으로 보고 버려, find <임시> -exec rm -rf -- -x {} \; 는 미탐
#     / 업그레이드 = 첫 `--` 뒤 낱말을 전부 위치 인자로 센다
#   사유에 미커밋 변경 수를 싣는다(무엇이 사라질 수 있는지 보고 판단하게).
# 분할: 히어독 본문은 lib git_strip_heredoc 규칙(문서 싱크만 걷음 — 아래 인라인 사본, 킷 lib 와 드리프트 테스트)으로 걷은 뒤,
#   따옴표 밖 줄바꿈을 `;` 로 바꾸고 따옴표 밖 낱말 머리의 `#` 주석을 줄 끝까지 걷은 뒤 세그먼트를 나누고
#   (shlex posix + punctuation_chars, shlex 자체 주석 처리는 끔 — 낱말 중간 `#` 은 주석이 아니다) 세그먼트마다 판정한다.
#   git 전역옵션(-C x·-c k=v·--git-dir=…)과 실행 래퍼(command·sudo·nohup·time·exec·env)는 벗기고 본다.
# shlex ValueError(닫히지 않은 따옴표 등 — 걷지 않은 히어독 본문의 영문 아포스트로피 포함)면 줄 단위로 다시 판정하고,
#   혼자서도 파싱이 안 되는 줄에 rm·git 낱말이 있으면 판정 불가로 ask 다(앞 줄은 실행될 수 있다).
#   값을 받는 래퍼 옵션(sudo -u·env -u 등) 뒤의 명령은 위 벗기기로는 못 보고, 추가 관문 G-D1 의 중간 낱말 재판정으로 본다.
# ponytail: 명령 텍스트 파싱이라 $(…)·eval·별칭·변수 조립 형태는 샌다 / 업그레이드 = git 래퍼 또는 파일시스템 스냅샷(git stash create) 선기록.
# ponytail: 따옴표 없는 문서 히어독(cat > a.md <<EOF) 본문의 $(…) 는 걷혀 판정되지 않고, git commit -F - 히어독 본문 줄은
#   명령으로 판정돼 ask 가 뜰 수 있다 / 업그레이드 = 히어독 토큰 인용 여부로 걷기 판정 + -F - 본문 걷기(prod-db-guard 와 같은 규칙).
# MCP 운영 DB 분기는 jq·python3 부재 검사보다 앞이다 — 도구가 없어도 ask(fail-closed), 출력은 jq 없이 고정 JSON.
#   판정 = tool_name 전체를 소문자화해 개발 DB 접미사(`-dev-db__`·`-devserver-db__`)를 모두 지운 뒤에도 `mcp__*-db__*` 에 맞으면 ask
#   불변식: 개발 DB 접미사는 명시 목록이다 — 새 개발 DB 명명이 생기면 아래 case 앞 제거 목록과 doctor [5e] 추출 규칙에 함께 추가한다.
#   (서버명 위치를 `__` 로 자르지 않는다 — 서버명에 `__` 가 섞이거나 plugin 접두가 붙어도 잡힌다. 도구명에 -dev-db__ 가 섞인 운영 서버도 ask).
#   jq 가 없거나 tool_name 을 못 읽으면 원문의 "tool_name":"…" 후보 전부를 보고, 하나라도 맞으면 ask 한다(오탐 쪽으로 실패).
# ponytail: 이름이 -db 로 끝나지 않는 운영 DB MCP 는 미보호 / 그런 서버가 생기면 목록 파일(추가 전용)로 확장.
input=$(cat)
tool=
command -v jq >/dev/null 2>&1 && tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
if [ -n "$tool" ]; then cands=$tool
else cands=$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^"tool_name"[[:space:]]*:[[:space:]]*"//; s/"$//'); fi
set -f; oifs=$IFS; IFS='
'
for c in $cands; do
  case "$c" in [Mm][Cc][Pp]_*) ;; *) continue ;; esac
  lc=$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')
  lc=${lc//-dev-db__/}; lc=${lc//-devserver-db__/}
  case "$lc" in
    mcp__*-db__*)
      safe=$(printf '%s' "$c" | tr -cd 'A-Za-z0-9_.:-')
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[운영DB] %s — 운영 DB MCP 호출이다(서버명 -db 규칙). 조회 목적·대상이 맞는지 확인 후 승인."}}\n' "$safe"
      exit 0 ;;
  esac
done
IFS=$oifs; set +f
# jq·python3 부재는 조용히 통과(Bash 분기) — 레포 deny 규칙이 rm -rf·reset --hard·clean -f 를 따로 막는다.
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
# 싼 선필터 — 부분 문자열 git·rm·find 가 없으면 python 을 띄우지 않는다(/bin/rm·\rm·"rm" 도 걸리게 경계 없이 본다).
printf '%s' "$cmd" | grep -qE 'git|rm|find' || exit 0

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

scan=$(git_strip_heredoc "$cmd")

hit=$(CMD="$scan" HCWD="${cwd:-$PWD}" TMPD="${TMPDIR:-/tmp}" python3 -I - <<'PY' 2>/dev/null
import os, re, shlex
cmd = os.environ["CMD"]
hcwd = os.environ.get("HCWD") or "/"  # 상대 경로는 훅 프로세스가 아니라 도구 호출의 cwd 기준
tmp_roots = tuple(p.rstrip("/") + "/" for p in (os.environ.get("TMPD", "/tmp"), "/tmp", "/private/tmp", "/var/folders"))
GLOBISH = set("{*?[$" + chr(96))  # chr(96) = 백틱 — $( ) 안 히어독에 문자 그대로 두면 bash 파서가 짝을 찾는다
WRAPPERS = {"command", "sudo", "nohup", "time", "exec", "env"}
FIND_EXEC = ("-exec", "-execdir", "-ok", "-okdir")

def newlines_to_semis(s):
    """따옴표 밖 줄바꿈 → ';' (\\+줄바꿈 연속행은 공백), 따옴표 밖 낱말 머리 '#' ~ 줄 끝(개행 직전) 제거.
    따옴표 상태는 홑(이스케이프 없음)·겹(\\ 이스케이프)."""
    out, q, i, n = [], "", 0, len(s)
    while i < n:
        c = s[i]
        if q == "'":
            out.append(c)
            if c == "'": q = ""
        elif q == '"':
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1]); i += 1
            elif c == '"':
                q = ""
        elif c == "\\" and i + 1 < n:
            out.append(" " if s[i + 1] == "\n" else c + s[i + 1]); i += 1
        elif c in "'\"":
            q = c; out.append(c)
        elif c == "#" and (not out or out[-1][-1] in " \t;&|()"):
            while i + 1 < n and s[i + 1] != "\n":
                i += 1
        elif c == "\n":
            out.append(";")
        else:
            out.append(c)
        i += 1
    return "".join(out)

FIND_PUNCT = {"__FIND_SEMI__": ";", "__FIND_LP__": "(", "__FIND_RP__": ")"}
def protect_find_punct(s):
    # 인용 밖에서 \; \( \) 와 한 글자만 인용한 ';' "(" 는 셸에선 낱말인데 shlex 는 맨 ; ( ) 로 돌려준다 → 센티널 낱말로.
    # 인용·이스케이프 상태를 따라가며 바꾼다(\\; 의 ; 와 "x";"rm" 의 ; 는 실제 구분자라 그대로 둔다).
    m = {";": "__FIND_SEMI__", "(": "__FIND_LP__", ")": "__FIND_RP__"}
    out, q, i, n = [], "", 0, len(s)
    while i < n:
        c = s[i]
        if q:
            out.append(c)
            if q == '"' and c == "\\" and i + 1 < n:
                out.append(s[i + 1]); i += 1
            elif c == q:
                q = ""
        elif c == "\\" and i + 1 < n:
            nx = s[i + 1]
            out.append(" " + m[nx] + " " if nx in m else c + nx); i += 1
        elif c in "'\"" and i + 2 < n and s[i + 1] in m and s[i + 2] == c:
            out.append(" " + m[s[i + 1]] + " "); i += 2
        elif c in "'\"":
            q = c; out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)

def segments(s):
    lex = shlex.shlex(protect_find_punct(newlines_to_semis(s)), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    lex.commenters = ""  # 주석은 newlines_to_semis 가 걷었다
    toks = list(lex)  # ValueError 는 호출부가 줄 단위 재판정
    cur = []
    for t in toks:
        if t and set(t) <= set(";&|()"):
            if cur: yield cur
            cur = []
        else:
            cur.append(t)
    if cur: yield cur

def strip_prefix(a):
    while a:
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a[0]):  # VAR=값 접두
            a = a[1:]; continue
        if os.path.basename(a[0]) in WRAPPERS:
            a = a[1:]
            while a and a[0].startswith("-"):
                a = a[1:]
            continue
        break
    return a

def git_sub(a):
    """git 전역옵션을 벗기고 (서브커맨드, 나머지)."""
    i = 1
    while i < len(a):
        x = a[i]
        if x in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2; continue
        if x.startswith("-"):
            i += 1; continue
        return x, a[i + 1:]
    return None, []

def shorts(rest):
    return "".join(x[1:] for x in rest if x.startswith("-") and not x.startswith("--"))

def judge(a):
    a = strip_prefix(a)
    if not a: return None
    exe = os.path.basename(a[0])
    if exe == "rm":
        flags = [x for x in a[1:] if x.startswith("-") and not x.startswith("--")]
        if not (any(re.search(r"[rR]", f) for f in flags) or "--recursive" in a[1:]):
            return None
        targets = [x for x in a[1:] if not x.startswith("-")]
        globish = any(set(t) & GLOBISH for t in targets)
        if targets and not globish and all(
                os.path.normpath(os.path.join(hcwd, os.path.expanduser(t))).startswith(tmp_roots) for t in targets):
            return None
        return "rm -r " + " ".join(targets[:3])
    if exe == "find":
        args = [FIND_PUNCT.get(x, x) for x in a[1:]]
        j, follow, fpaths = 0, False, []  # 앞머리 옵션(GNU -H -L -P -D <arg> -O<n> · BSD 묶음 -HLPEXdsx · -f <path> · --)을 건너뛴 뒤 시작 경로를 모은다
        while j < len(args):
            x = args[j]
            if x == "--": j += 1; break
            if x in ("-D", "-f") and j + 1 < len(args):
                if x == "-f": fpaths.append(args[j + 1])
                j += 2; continue
            if re.fullmatch(r"-O\d*", x) or re.fullmatch(r"-[HLPEXdsx]+", x):
                follow = follow or "H" in x or "L" in x
                j += 1; continue
            break
        args = args[j:]
        k = next((i for i, x in enumerate(args) if x.startswith(("-", "(", "!"))), len(args))
        given = fpaths + args[:k]
        starts, expr = given or ["."], args[k:]  # 시작 경로 생략 = cwd(이 경우 임시 예외 없음 — 앞머리를 못 읽었을 수 있다)
        rm_exec = any(x in FIND_EXEC and i + 1 < len(expr)  # -exec 뒤 래퍼(sudo·env·command 등)는 strip_prefix 로 벗기고 본다
                      and os.path.basename((strip_prefix(expr[i + 1:]) or [""])[0]) in ("rm", "unlink") for i, x in enumerate(expr))
        if "-delete" not in expr and not rm_exec:
            return None
        if given and not follow and "-follow" not in expr and "-files0-from" not in expr and not any(set(t) & GLOBISH for t in starts) and all(
                os.path.normpath(os.path.join(hcwd, os.path.expanduser(t))).startswith(tmp_roots) for t in starts):
            return None
        return "find " + " ".join(starts[:3]) + (" -delete" if "-delete" in expr else " -exec rm")
    if exe != "git": return None
    sub, rest = git_sub(a)
    if sub is None: return None
    if sub == "checkout" and ("--" in rest or "." in rest or "-f" in rest or "--force" in rest):
        return "git checkout " + " ".join(rest[:3])
    if sub == "restore":
        sf = shorts(rest)
        staged = "--staged" in rest or "S" in sf
        worktree = "--worktree" in rest or "W" in sf
        if staged and not worktree:
            return None
        return "git restore " + " ".join(rest[:3])
    if sub == "reset" and any(x in ("--hard", "--merge", "--keep") for x in rest):
        return "git reset " + " ".join(rest[:3])
    if sub == "switch" and any(x in ("-f", "--force", "--discard-changes") for x in rest):
        return "git switch " + " ".join(rest[:3])
    if sub == "stash" and (not rest or rest[0] in ("push", "drop", "clear", "-u", "--include-untracked", "-a", "--all")):
        return "git stash " + " ".join(rest[:2])
    if sub == "branch":
        opts = rest[:rest.index("--")] if "--" in rest else rest  # -- 뒤는 브랜치 이름
        sf = shorts(opts)
        # git 은 모호하지 않은 긴 옵션 축약을 받는다(--del·--forc) → 접두 일치. 모호한 축약은 git 이 거부하니 ask 로 잡아도 무해.
        lng = lambda full: any(len(x) >= 3 and full.startswith(x) for x in opts if x.startswith("--"))
        delete = "d" in sf or lng("--delete")
        if "D" in sf or (delete and ("f" in sf or lng("--force"))):
            return "git branch " + " ".join(rest[:3])
    if sub == "clean":
        opts = rest[:rest.index("--")] if "--" in rest else rest
        sf, skip, flags = "", False, []
        for x in opts:  # -e 는 값을 받는다 — 묶음(-enx)의 나머지·분리(-e x) 다음 인자는 플래그가 아니다(값이 --dry-run 이어도)
            if skip: skip = False; continue
            if x.startswith("--") and "=" not in x and len(x) >= 3 and "--exclude".startswith(x):
                skip = True; continue
            flags.append(x)
            if x.startswith("-") and not x.startswith("--"):
                body = x[1:]
                if "e" in body:
                    sf += body[:body.index("e")]; skip = body.endswith("e")
                else:
                    sf += body
        lng = lambda full: any(len(x) >= 3 and full.startswith(x) for x in flags if x.startswith("--"))
        if ("f" in sf or lng("--force")) and not ("n" in sf or lng("--dry-run")):
            return "git clean " + " ".join(rest[:3])
    return None

try:
    segs = list(segments(cmd))
except ValueError:
    segs = []
    for line in cmd.replace("\\\n", " ").split("\n"):
        try:
            segs.extend(segments(line))
        except ValueError:
            if re.search(r"(^|[^A-Za-z0-9_.-])(rm|git)([^A-Za-z0-9_-]|$)", line):
                print("판정 불가(닫히지 않은 따옴표 등 — 앞부분은 실행될 수 있음)")
                raise SystemExit(0)
for seg in segs:
    r = judge(seg)
    if r:
        print(r.strip())
        raise SystemExit(0)

# 추가 관문 — 위 판정(judge 루프)이 통과시킨 호출에만 돈다. 바뀌는 방향은 통과 → ask 뿐이다.
#   G-D1 세그먼트 중간 실행어 재판정: 예약어(do·then·else·{·!)·xargs·timeout·nice·sudo -u·find -exec 래퍼 뒤의
#        rm·git·find 낱말부터 잘라 judge 로 다시 본다. git 서브커맨드 자리(git rm)·--cached 가 붙은 rm·find 의 -exec 류 바로 뒤 rm 중 위치 인자가 전부 {} 인 것(find 분기가 판정)·
#        머리(예약어·래퍼를 벗긴 첫 낱말)가 PRINTING 인 세그먼트는 제외.
#   G-D2 셸 -c 본문 재판정: sh·bash·zsh·dash·ksh 의 -*c* 옵션 뒤 스크립트 문자열을 같은 규칙으로 다시 판정(중첩 한도 있음).
#   G-D3 git -c clean.* + clean: 설정으로 requireForce 를 끌 수 있으니 -f 없이도 ask(-n·--dry-run 이면 통과).
#   G-D4 git stash 는 허용 목록(STASH_SAFE) 밖 서브커맨드·옵션이면 ask · git checkout 은 CHECKOUT_NEW 옵션 없이
#        위치 인자(리다이렉트 낱말·그 대상 제외)가 2개 이상(트리 + 경로)이면 ask.
# 관문에서 예외가 나면 "판정 불가"로 ask 한다 — 위 판정의 hit 는 이미 출력·종료됐으므로 관문 예외가 지우지 못한다.
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
LAUNCH = {"rm", "git", "find"}
RESERVED = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "time"}
PRINTING = {"echo", "printf"}
GIT_VALOPTS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace")
MAX_DEPTH = 2

def git_sub_at(a, g):
    """a[g] 가 git 일 때 서브커맨드 자리의 인덱스(git_sub 와 같은 전역옵션 규칙)."""
    i = g + 1
    while i < len(a):
        if a[i] in GIT_VALOPTS: i += 2; continue
        if a[i].startswith("-"): i += 1; continue
        return i
    return None

def clean_cfg(a):
    """a[0] = git. -c clean.* 를 주고 clean 을 부르면(드라이런 제외) 사유."""
    cfg = [a[i + 1] for i in range(1, len(a) - 1) if a[i] == "-c"] + [x[2:] for x in a[1:] if x.startswith("-c") and len(x) > 2]
    sub, rest = git_sub(a)
    if sub == "clean" and any(re.match(r"(?i)clean\.", v) for v in cfg):
        opts = rest[:rest.index("--")] if "--" in rest else rest
        if not ("n" in shorts(opts) or any(len(x) >= 3 and "--dry-run".startswith(x) for x in opts if x.startswith("--"))):
            return "git -c clean.* clean " + " ".join(rest[:3])
    return None

STASH_SAFE = {"list", "show", "pop", "apply", "branch", "create", "store"}
CHECKOUT_NEW = {"-b", "-B", "--orphan", "--detach"}

def only_braces(args):
    """find -exec 의 rm 인자(종결자 ; 또는 + 전까지)에서 옵션을 뺀 위치 인자가 1개 이상이고 전부 {} 인가."""
    end = next((k for k, x in enumerate(args) if x in (";", "+")), len(args))
    pos = [x for x in args[:end] if not x.startswith("-")]
    return bool(pos) and all(x == "{}" for x in pos)

def no_redirects(rest):
    """리다이렉트 낱말(2>/dev/null·>x·<x)과, 대상이 떨어진 리다이렉트(> x·2> x)의 대상 낱말을 뺀다."""
    out, skip = [], False
    for x in rest:
        if skip: skip = False; continue
        if re.match(r"^\d*[<>]", x):
            skip = bool(re.fullmatch(r"\d*[<>]+&?", x)); continue
        out.append(x)
    return out

def stash_checkout(a):
    """a[0] = git. stash 는 허용 목록 밖 전부, checkout 은 새 브랜치·분리 없이 위치 인자 2개 이상이면 사유."""
    sub, rest = git_sub(a)
    rest = no_redirects(rest)
    if sub == "stash" and (not rest or rest[0] not in STASH_SAFE):  # 리다이렉트만 남았던 것 = 맨 git stash
        return "git stash " + " ".join(rest[:2])
    if sub == "checkout" and not any(x in CHECKOUT_NEW for x in rest) \
            and len([x for x in rest if not x.startswith("-")]) >= 2:
        return "git checkout " + " ".join(rest[:3])
    return None

def shell_script(a, i):
    """a[i] 가 셸일 때 -c 의 스크립트 문자열(없으면 None). -o/+o 는 값을 받는다."""
    j, saw_c = i + 1, False
    while j < len(a):
        x = a[j]
        if x in ("-o", "+o"): j += 2; continue
        if re.fullmatch(r"[-+][A-Za-z]+", x):
            saw_c = saw_c or (x[0] == "-" and "c" in x[1:]); j += 1; continue
        return x if saw_c else None
    return None

def gate_seg(a, depth):
    a = [FIND_PUNCT.get(x, x) for x in a]
    h = strip_prefix(a[next((k for k, x in enumerate(a) if x not in RESERVED), len(a)):])
    printing = bool(h) and os.path.basename(h[0]) in PRINTING  # echo·printf 의 인자는 실행되지 않는다(G-D1 만 건너뜀)
    for i, x in enumerate(a):
        base = os.path.basename(x)
        if base == "git":
            r = clean_cfg(a[i:]) or stash_checkout(a[i:])
            if r: return r
        if i > 0 and not printing and base in LAUNCH and not (base == "rm" and "--cached" in a[i + 1:]) \
                and not (base == "rm" and a[i - 1] in FIND_EXEC and any(os.path.basename(y) == "find" for y in a[:i - 1])
                         and only_braces(a[i + 1:])) \
                and not any(os.path.basename(a[g]) == "git" and git_sub_at(a, g) == i for g in range(i)):
            r = judge(a[i:])
            if r: return r
        if base in SHELLS:
            s = shell_script(a, i)
            if s is not None:
                r = scan_text(s, depth + 1)
                if r: return r
    return None

def scan_text(text, depth):
    if depth > MAX_DEPTH:
        return "판정 불가(셸 래퍼 중첩)" if re.search(r"rm|git|find", text) else None
    try:
        ss = list(segments(text))
    except ValueError:
        ss = []
        for line in text.replace("\\\n", " ").split("\n"):
            try:
                ss.extend(segments(line))
            except ValueError:
                if re.search(r"(^|[^A-Za-z0-9_.-])(rm|git)([^A-Za-z0-9_-]|$)", line):
                    return "판정 불가(셸 -c 본문의 닫히지 않은 따옴표 등)"
    for s in ss:
        r = (judge(s) if depth else None) or gate_seg(s, depth)
        if r: return r
    return None

try:
    r = None
    for seg in segs:
        r = gate_seg(seg, 0)
        if r: break
except Exception:
    r = "판정 불가(추가 관문 오류)"
if r:
    print(r.strip())
PY
)
prc=$?
# 판정기가 비정상 종료(rc≠0)했는데 hit 가 비었으면 판정 불가로 ask — 통과로 떨어뜨리지 않는다.
[ -n "$hit" ] || { [ "$prc" -eq 0 ] && exit 0; hit="판정 불가(판정기 비정상 종료 rc=$prc)"; }

case "$hit" in
  "git branch "*) ask "[파괴명령] ${hit} — 병합되지 않은 커밋이 있어도 브랜치를 지운다(reflog 로만 복구 가능). 의도한 것이면 승인." ;;
esac
dirty=$(git -C "${cwd:-.}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ask "[파괴명령] ${hit} — 워킹트리 변경을 되돌릴 수 없게 지울 수 있다(현재 미커밋 변경 ${dirty:-?}건, 병행 세션 변경 포함일 수 있음). 의도한 것이면 승인."
