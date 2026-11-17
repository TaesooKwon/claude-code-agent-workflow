#!/usr/bin/env bash
# PreToolUse(Bash · 운영 DB MCP) 전역 훅 — 워킹트리·운영 DB 를 건드리는 호출에 사용자 확인(permissionDecision "ask")을 강제한다.
#   settings 의 permissions.ask 는 auto 모드에서 확인창을 띄우지 않았다(2026-10-10 실측 1회) → 훅이 직접 ask 를 반환한다.
#   대상: git checkout -- / . / -f · git restore(인덱스만 되돌리는 --staged/-S 단독 외 전부) · git reset --hard/--merge/--keep(위치 무관) ·
#         git switch -f / --discard-changes · git stash(무인자·push·drop·clear) ·
#         rm -r/-R(실행어 basename 기준 — /bin/rm 포함. 대상이 전부 임시 디렉터리면 제외, 단 대상에 { * ? [ $ ` 가 있으면 제외 없음) ·
#         mcp____PROJECT__-real-db 전 도구.
#   사유에 미커밋 변경 수를 싣는다(무엇이 사라질 수 있는지 보고 판단하게).
# 분할: 히어독 본문은 lib git_strip_heredoc 규칙(문서 싱크만 걷음 — 아래 인라인 사본, 킷 lib 와 드리프트 테스트)으로 걷은 뒤,
#   따옴표 밖 줄바꿈을 `;` 로 바꾸고 따옴표 밖 낱말 머리의 `#` 주석을 줄 끝까지 걷은 뒤 세그먼트를 나누고
#   (shlex posix + punctuation_chars, shlex 자체 주석 처리는 끔 — 낱말 중간 `#` 은 주석이 아니다) 세그먼트마다 판정한다.
#   git 전역옵션(-C x·-c k=v·--git-dir=…)과 실행 래퍼(command·sudo·nohup·time·exec·env)는 벗기고 본다.
# shlex ValueError(닫히지 않은 따옴표 등 — 걷지 않은 히어독 본문의 영문 아포스트로피 포함)면 줄 단위로 다시 판정하고,
#   혼자서도 파싱이 안 되는 줄에 rm·git 낱말이 있으면 판정 불가로 ask 다(앞 줄은 실행될 수 있다).
# ponytail: 값을 받는 래퍼 옵션(sudo -u·env -u 등) 뒤의 명령은 벗기지 못해 판정되지 않는다 / 업그레이드 = 래퍼별 값 옵션 허용 목록 + 모르는 옵션은 ask.
# ponytail: 명령 텍스트 파싱이라 $(…)·eval·별칭·변수 조립 형태는 샌다 / 업그레이드 = git 래퍼 또는 파일시스템 스냅샷(git stash create) 선기록.
# ponytail: 따옴표 없는 문서 히어독(cat > a.md <<EOF) 본문의 $(…) 는 걷혀 판정되지 않고, git commit -F - 히어독 본문 줄은
#   명령으로 판정돼 ask 가 뜰 수 있다 / 업그레이드 = 히어독 토큰 인용 여부로 걷기 판정 + -F - 본문 걷기(prod-db-guard 와 같은 규칙).
# ponytail: 킷 사본은 운영 DB MCP 서버명을 __PROJECT__-real-db 플레이스홀더로 둔다(실명 비반출) — 설치 후 case 분기·settings matcher 를 실서버명으로 바꾸지 않으면 MCP ask 는 무발화 / 업그레이드 = 서버명 목록을 환경변수·설정 파일로 분리해 라이브·킷 로직 동일화.
# jq·python3 부재는 조용히 통과 — 레포 deny 규칙이 rm -rf·reset --hard·clean -f 를 따로 막는다.
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  mcp____PROJECT__-real-db__*)
    ask "[운영DB] ${tool} — 운영 DB MCP 호출이다. 조회 목적·대상이 맞는지 확인 후 승인." ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
# 싼 선필터 — 부분 문자열 git·rm 이 없으면 python 을 띄우지 않는다(/bin/rm·\rm·"rm" 도 걸리게 경계 없이 본다).
printf '%s' "$cmd" | grep -qE 'git|rm' || exit 0

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
      qn = 0; qi = 1
    }
    {
      if (qi <= qn) {                                   # 히어독 본문 안 — 순서대로 소비한다
        tl = $0; if (QD[qi]) sub(/^\t+/, "", tl)
        if (tl == QT[qi]) { if (!QS[qi]) print; qi++; next }
        if (!QS[qi]) print
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
        t = substr(d, p, L); sub(/^<<-?[[:space:]]*/, "", t); gsub(/["'"'"'\\]/, "", t)
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
      print
    }'
}

scan=$(git_strip_heredoc "$cmd")

hit=$(CMD="$scan" HCWD="${cwd:-$PWD}" TMPD="${TMPDIR:-/tmp}" python3 -I - <<'PY' 2>/dev/null
import os, re, shlex
cmd = os.environ["CMD"]
hcwd = os.environ.get("HCWD") or "/"  # 상대 경로는 훅 프로세스가 아니라 도구 호출의 cwd 기준
tmp_roots = tuple(p.rstrip("/") + "/" for p in (os.environ.get("TMPD", "/tmp"), "/tmp", "/private/tmp", "/var/folders"))
GLOBISH = set("{*?[$" + chr(96))  # chr(96) = 백틱 — $( ) 안 히어독에 문자 그대로 두면 bash 파서가 짝을 찾는다
WRAPPERS = {"command", "sudo", "nohup", "time", "exec", "env"}

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

def segments(s):
    lex = shlex.shlex(newlines_to_semis(s), posix=True, punctuation_chars=";&|()")
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
        break
PY
)
[ -n "$hit" ] || exit 0

dirty=$(git -C "${cwd:-.}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ask "[파괴명령] ${hit} — 워킹트리 변경을 되돌릴 수 없게 지울 수 있다(현재 미커밋 변경 ${dirty:-?}건, 병행 세션 변경 포함일 수 있음). 의도한 것이면 승인."
