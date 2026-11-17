#!/usr/bin/env bash
# cmdform.py(허용 형태 판정기) 계약 테스트 — 커밋 형태(judge_commit 직접 호출) + 운영 DB 가드(prod-db-guard.sh 실물 경유).
# 실행: bash .claude/hooks/lib/cmdform.test.sh   (python3·jq·git 필요 — 없으면 실행하지 않고 rc 2)
# 격리: mktemp 아래에 임시 레포(G·그 worktree W·남의 레포 O)와 훅 사본(prod-db-guard.sh + lib/)을 만든다.
#   훅 사본은 포트 무관 허용 축(ALLOWED_DB_HOSTS_ANYPORT_REGEX)에 시험용 dev 호스트 D 를 넣은 것이다(문서용 IP — RFC 5737).
#   실레포·실 설정·실 DB 는 건드리지 않는다(접속 명령은 판정만 하고 실행하지 않는다). 비밀번호는 더미(DUMMY)뿐이다.
# 구성: ①설계 v2 시제품 케이스(커밋·DB) ②1차·반증 합성 케이스(cmdform.db-composite.jsonl) ③반증 보강(F1·터널·메시지 파일·
#   GATE_LAYER 문맥은 commit-gate-form.test.sh) ④판정기 실패 계약(시간 초과·예외·인자·인코딩·깊은 중첩).
# 반증 예고(깨질 이름을 먼저 적는다):
#   - pipe_inert 의 out_redirs_doc_only 검사를 빼면 F1a·F1b·F1c·F1h 4건이 allow 로 샌다(F1d 는 tee 가 데이터 실행어가 아니라 남는다).
#   - ssh_tunnel 판정을 빼면 TN1~TN5·TN8·TN11·TN12 와 합성 D18·D19·D20 이 allow 로 샌다.
#   - judge_db 의 python 판정을 첫 실행어 한정(resolve_exe)으로 되돌리면 LR1~LR6 이 python-with-db-words 를 잃는다
#     (허용 목록 규칙 db-words-with-unlisted-exe 가 대신 잡아 판정은 deny 로 남는다 — 두 규칙을 함께 빼야 빨강).
#   - _heredoc_delim 순수형 검사를 빼면 N2a·N2b·DB N2 H1·H3·H4 가 allow 로 샌다.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
for _t in python3 jq git; do
  command -v "$_t" >/dev/null 2>&1 || { echo "전제 도구 없음($_t) — 테스트를 실행하지 않았다"; exit 2; }
done
[ -f "$HERE/cmdform.py" ] && [ -f "$HERE/../prod-db-guard.sh" ] || { echo "판정기·훅 없음 — 실행하지 않았다"; exit 2; }
exec python3 -I - "$HERE" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys, tempfile, time
HERE = sys.argv[1]
T = tempfile.mkdtemp(prefix='cmdform-test.')
try:
    HK = os.path.join(T, 'hooks'); os.makedirs(os.path.join(HK, 'lib'))
    for f in ('cmdform.py', 'git-cmd.sh'):
        shutil.copy(os.path.join(HERE, f), os.path.join(HK, 'lib', f))
    P = '203.0.113.71'; D = '198.51.100.50'
    s = open(os.path.join(HERE, '..', 'prod-db-guard.sh'), encoding='utf-8').read()
    s2 = re.sub(r"^ALLOWED_DB_HOSTS_ANYPORT_REGEX='[^']*'", "ALLOWED_DB_HOSTS_ANYPORT_REGEX='%s'" % re.escape(D).replace('\\.', '\\.'), s, count=1, flags=re.M)
    assert s2 != s or "ALLOWED_DB_HOSTS_ANYPORT_REGEX='%s'" % re.escape(D) in s, '포트 무관 축 대입 줄을 못 찾았다'
    HOOK = os.path.join(HK, 'prod-db-guard.sh'); open(HOOK, 'w', encoding='utf-8').write(s2)
    spec = importlib.util.spec_from_file_location('cf', os.path.join(HK, 'lib', 'cmdform.py'))
    cf = importlib.util.module_from_spec(spec); spec.loader.exec_module(cf)

    G = os.path.join(T, 'g1'); O = os.path.join(T, 'other'); W = os.path.join(T, 'wt1')
    genv = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    for k in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'): genv.pop(k, None)
    def sh(*a):
        subprocess.run(a, check=True, capture_output=True, env=genv)
    for r in (G, O):
        sh('git', 'init', '-q', r); sh('git', '-C', r, 'config', 'user.email', 't@example.invalid'); sh('git', '-C', r, 'config', 'user.name', 't')
        sh('git', '-C', r, 'config', 'commit.gpgsign', 'false')
        open(os.path.join(r, 'f'), 'w').write('x'); sh('git', '-C', r, 'add', 'f'); sh('git', '-C', r, 'commit', '-qm', 's')
    sh('git', '-C', G, 'worktree', 'add', '-q', W, '-b', 'wt1'); os.makedirs(os.path.join(G, 'sub'))
    os.environ['CLAUDE_PROJECT_DIR'] = G
    for k in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'): os.environ.pop(k, None)
    PYC = "import pymysql; pymysql.connect(host='%s')" % P

    C = []  # (기대, 모드, 이름, 명령)
    def c(e, m, n, s): C.append((e, m, n, s))
    # ── ① 커밋: 정상 형태(ALLOW) ──
    c('ALLOW', 'commit', 'A1 단독 -m', 'git commit -m x')
    c('ALLOW', 'commit', 'A2 -F - 히어독(본문 git add·cd 문구, N6 P5)', "git commit -q -F - <<'EOF'\nfeat: x\n(cd 줄) git add later\nEOF")
    c('ALLOW', 'commit', 'A3 -m "$(cat <<EOF)" (N6 P4)', "git commit -m \"$(cat <<'EOF'\nmsg git add x\nEOF\n)\"")
    c('ALLOW', 'commit', 'A4 ALLOW 접두', 'ALLOW_TEST_COUNT_DROP=1 git commit -m x')
    c('ALLOW', 'commit', 'A5 git status && commit(메시지 안 && ;)', "git status && git commit -m 'a && b; c'")
    c('ALLOW', 'commit', 'A6 실사용형(cd 자기레포 · 앞뒤 읽기)', "cd %s && git diff --cached --stat | tail -1 && git commit -q -F - <<'EOF'\nmsg\nEOF\ngit log --oneline -2; git status --short | grep -v '^??'" % G)
    c('ALLOW', 'commit', 'A7 -F 파일 2>&1 | tail ; log', 'git commit -F /tmp/msg.txt 2>&1 | tail -4; git log --oneline -1; git status --short')
    c('ALLOW', 'commit', 'A8 뒤 echo "commit exit=$?"', "git commit -q -F - <<'EOF'\nm\nEOF\necho \"commit exit=$?\"; git log -1 --format='%h %s'")
    c('ALLOW', 'commit', 'A9 cd "$CLAUDE_PROJECT_DIR"', 'cd "$CLAUDE_PROJECT_DIR" && git commit -m x')
    c('ALLOW', 'commit', 'A10 branch --show-current && diff | cat && commit', "git branch --show-current && git diff --cached --name-status | cat && git commit -q -F - <<'EOF'\nm\nEOF")
    c('ALLOW', 'commit', 'A11 printf | git commit -F -', "printf '%s\\n' 'fix: a' '' 'body' | git commit -F -")
    c('ALLOW', 'commit', 'A12 --amend --no-edit', 'git commit --amend --no-edit')
    c('ALLOW', 'commit', 'A13 -qm', 'git commit -qm "msg"')
    c('ALLOW', 'commit', 'A14 <<EOF(맨 구분자, 확장 없음)', 'git commit -F - <<EOF\nplain msg\nEOF')
    c('ALLOW', 'commit', 'A15 cd 하위디렉터리(같은 레포)', 'cd %s/sub 2>/dev/null; git commit -m x' % G)
    # ── 비커밋(NONE) — N13 ──
    c('NONE', 'commit', 'N13a git log --grep=commit', 'git log --grep=commit')
    c('NONE', 'commit', 'N13b grep "git commit" docs', 'grep -rn "git commit" docs/')
    c('NONE', 'commit', 'N13c echo 문구', 'echo "remember to git commit"')
    c('DENY', 'commit', 'N13d gh pr create --body(오차단 감수)', 'gh pr create --body "use git commit"')
    c('NONE', 'commit', 'N13e 문서 히어독 본문', "cat >> notes.md <<'EOF'\ngit add a && git commit\nEOF")
    c('NONE', 'commit', 'N13f 비커밋 일반', 'ls -la && git status')
    # ── 공격(DENY) ──
    c('DENY', 'commit', 'S1 add && commit', 'git add draft.sql && git commit -m x')
    c('DENY', 'commit', 'S2a git -C wt commit', 'git -C %s commit -m x' % W)
    c('DENY', 'commit', 'S2b cd wt && commit', 'cd %s && git commit -m x' % W)
    c('DENY', 'commit', 'S3a commit && git -C other log', 'git commit -m x && git -C %s log' % O)
    c('DENY', 'commit', 'S3b cd other && cd g1 && commit', 'cd %s && cd %s && git commit -m x' % (O, G))
    c('DENY', 'commit', 'N1a false && cd O; commit', 'false && cd %s; git commit -m x' % O)
    c('DENY', 'commit', 'N1b cd O & commit', 'cd %s & git commit -m x' % O)
    c('DENY', 'commit', 'N1c cd O | : ; commit', 'cd %s | : ; git commit -m x' % O)
    c('DENY', 'commit', 'N1d true || cd O; commit', 'true || cd %s; git commit -m x' % O)
    c('DENY', 'commit', 'N2a <<E\\OF 종료어 숨김', "git commit -q -F - <<E\\OF\nmsg\nEOF\ncd %s\ngit commit -qm y" % W)
    c('DENY', 'commit', 'N2b <<"E"OF', 'git commit -q -F - <<"E"OF\nmsg\nEOF\ngit add x\ngit commit -qm y')
    c('DENY', 'commit', 'N3a 경로 인자', 'git commit -m x T.java')
    c('DENY', 'commit', 'N3b -i 경로', 'git commit -i T.java -m x')
    c('DENY', 'commit', 'N3c -am', 'git commit -am x')
    c('DENY', 'commit', 'N3d git "add" && commit', 'git "add" draft.sql && git commit -m x')
    c('DENY', 'commit', 'N3e git ad\\d && commit', 'git ad\\d draft.sql && git commit -m x')
    c('DENY', 'commit', 'N3f -c alias.a=add', 'git -c alias.a=add a draft.sql && git commit -m x')
    c('DENY', 'commit', 'N3g ./stage.sh && commit', './stage.sh && git commit -m x')
    c('DENY', 'commit', 'N3h cherry-pick -n && commit', 'git cherry-pick -n abc && git commit -m x')
    c('DENY', 'commit', 'N3i merge --squash && commit', 'git merge --squash b && git commit -m x')
    c('DENY', 'commit', 'N3j add && git "commit"(A9)', 'git add x && git "commit" -m y')
    c('DENY', 'commit', 'N3k git -c alias.ci=commit ci', 'git -c alias.ci=commit ci -m x')
    c('DENY', 'commit', 'N4a builtin cd', 'builtin cd %s && git commit -m x' % W)
    c('DENY', 'commit', 'N4b eval cd', 'eval cd %s; git commit -m x' % W)
    c('DENY', 'commit', 'N4c export GIT_DIR', 'export GIT_DIR=%s/.git GIT_WORK_TREE=%s; git commit -m x' % (O, O))
    c('DENY', 'commit', 'N4d GIT_INDEX_FILE 접두', 'GIT_INDEX_FILE=/tmp/i git commit -m x')
    c('DENY', 'commit', 'N5 -C O commit; commit', 'git -C %s commit -m a; git commit -m b' % O)
    c('DENY', 'commit', 'N6a timeout 60 git commit(오차단 감수)', 'timeout 60 git commit -m x')
    c('DENY', 'commit', 'N6b stash list && commit(오차단 감수)', 'git stash list && git commit -m x')
    c('DENY', 'commit', 'N6c restore --staged && commit(분리 안내)', 'git restore --staged x && git commit -m x')
    c('DENY', 'commit', 'X1 ANSI-C co$\'mm\'it', "git co$'mm'it -m x")
    c('DENY', 'commit', 'X2 변수 조립 X=commit', 'X=commit; git $X -m y')
    c('DENY', 'commit', 'X3 sh -c', 'sh -c "git commit -m x"')
    c('DENY', 'commit', 'X4 echo | sh', 'echo git commit -m x | sh')
    c('DENY', 'commit', 'X5 훅 건너뛰기 옵션', 'git commit -m x --no-' + 'verify')
    c('DENY', 'commit', 'X6 -m "$(git add -A; …)"', 'git commit -m "$(git add -A; echo x)"')
    c('DENY', 'commit', 'X7 <<EOF 본문 $(…) 확장', 'git commit -F - <<EOF\n$(git add x)\nEOF')
    c('DENY', 'commit', 'X8 commit; git push', 'git commit -m x; git pu' + 'sh')
    c('DENY', 'commit', 'X9 (git commit) 서브셸', '(git commit -m x)')
    c('DENY', 'commit', 'X10 커밋 2회', 'git commit -m x\ncd %s\ngit commit -m y' % O)
    c('DENY', 'commit', 'X11 commit | sh', 'git commit -m x | sh')
    c('DENY', 'commit', 'X12 python 히어독 본문 git commit', "python3 - <<'PY'\nimport os; os.system('git commit -m x')\nPY")
    c('DENY', 'commit', 'X13 git com\\mit', 'git com\\mit -m x')
    c('DENY', 'commit', 'X14 GIT_DIR=… 접두', 'GIT_DIR=%s/.git git commit -m x' % O)
    c('DENY', 'commit', 'X15 commit-tree', 'git commit-tree HEAD^{tree} -m x')
    c('DENY', 'commit', 'X16 -C HEAD 재사용(불허 옵션)', 'git commit -C HEAD')
    c('DENY', 'commit', 'X17 -- 경로', 'git commit -m x -- a.java')
    c('DENY', 'commit', 'X18 cd 상대경로 다른 레포', 'cd ../other && git commit -m x')
    # ── ① DB(시제품 51행 — prod-db-guard.sh 사본 경유) ──
    c('DENY', 'db', 'D1 인라인 python 운영', 'python3 -c "%s"' % PYC)
    c('DENY', 'db', 'D2 python3 - 히어독', "python3 - <<'PY'\n%s\nPY" % PYC)
    c('DENY', 'db', 'D5 cat <<EOF | python3', 'cat <<EOF | python3\n%s\nEOF' % PYC)
    c('DENY', 'db', 'D6 .py 로 쓰고 실행', "cat <<'EOF' > c.py\n%s\nEOF\npython3 c.py" % PYC)
    c('ALLOW', 'db', 'A1 문서 히어독 안 접속 서술', "cat >> 설계.md <<'EOF'\nMariaDB: python3 -c \"%s\"\nEOF" % PYC)
    c('DENY', 'db', 'Y11 dev/로컬 인라인 python(계약 변경)', "python3 -c \"import pymysql; pymysql.connect(host='localhost', port=3306)\"")
    c('ALLOW', 'db', 'Y17 python -m json.tool && grep mariadb', 'python3 -m json.tool a.json && grep -n mariadb core/pom.xml')
    c('ALLOW', 'db', 'K1 스킬 스크립트 파일 실행', 'python3 "$CLAUDE_PROJECT_DIR/.claude/skills/dev-ddl-apply/scripts/apply_ddl.py" draft.sql')
    c('ALLOW', 'db', 'K2 스킬 --table', 'python3 .claude/skills/dev-ddl-apply/scripts/apply_ddl.py --table tn_x')
    c('DENY', 'db', 'K3 스킬 모듈 import 인라인(기존도 deny)', "python3 - <<'EOF' 2>&1 | grep -vi password\nimport sys; sys.path.insert(0,'.claude/skills/dev-ddl-apply/scripts'); import apply_ddl, pymysql\nc=pymysql.connect(**apply_ddl.load_conn_info())\nEOF")
    c('ALLOW', 'db', 'G1 grep 패턴에 python -c pymysql', "grep -rnE 'python3 -c .*pymysql' docs/")
    c('DENY', 'db', 'N9 D1 삼항 미끼', "python3 -c \"import pymysql;pymysql.connect(host='%s' if 0 else '%s')\"" % (D, P))
    c('DENY', 'db', 'N7 D33 별칭 n 낱말', "python3 -c \"import pymysql;from pymysql import constants, connect as c;c('%s')\"" % P)
    c('DENY', 'db', 'N10 D9 sshtunnel', "python3 -c \"from sshtunnel import SSHTunnelForwarder as F;F(('b',22)).start()\"")
    c('DENY', 'db', 'N10 D10 socat & mysql', 'socat TCP-LISTEN:3306,fork TCP:%s:7306 & sleep 1; mysql -h 127.0.0.1 -P 3306' % P)
    c('DENY', 'db', 'N10 D11 kubectl pf & mysql', 'kubectl port-forward svc/x 3306:3306 & mysql -h 127.0.0.1')
    c('DENY', 'db', 'N10 D12 ssh -fN && mysql', 'ssh -fN prod-tunnel && mysql -h 127.0.0.1 -P 3306')
    c('DENY', 'db', 'N10 D18 ssh -L 단독(결정 3 — 단독 터널 deny 승격)', 'ssh -fN -L [::1]:3306:%s:7306 bastion' % P)
    c('DENY', 'db', 'N11 D28 subprocess mysql', "python3 -c \"import subprocess;subprocess.run(['mysql','-h','%s'])\"" % P)
    c('DENY', 'db', 'N12 D13 -Bh 묶음', "mysql -h 127.0.0.1 -Bh%s -P3306 -e 'select 1'" % P)
    c('DENY', 'db', 'N12 D14 -Nh', "mysql -h 127.0.0.1 -Nh %s -e 'select 1'" % P)
    c('DENY', 'db', 'S7 mycli --ssh-host', 'mycli --ssh-host prod-bastion -h localhost')
    c('DENY', 'db', 'S7 mysqlsh --ssh=', 'mysqlsh --ssh=ops@b --uri root@localhost:3306')
    c('DENY', 'db', 'S8 -S 소켓', 'mysql -h localhost -S /tmp/prod.sock')
    c('ALLOW', 'db', 'S8 계약 --protocol=tcp -S', 'mysql -h localhost --protocol=tcp -S x prod')
    c('DENY', 'db', 'S8 --hos= 약어', 'mysql -h 127.0.0.1 --hos=prod-db.example')
    c('DENY', 'db', 'D31 --defaults-group-suffix', "mysql --defaults-group-suffix=_prod -e 'select 1'")
    c('DENY', 'db', 'D29 export MYSQL_HOST; mysql', 'export MYSQL_HOST=%s; mysql -P 3306' % P)
    c('ALLOW', 'db', 'D24 mysql -h localhost(정상)', "mysql -h localhost -u root -e 'select 1'")
    c('ALLOW', 'db', 'L1 mysql localhost | head', "mysql -h localhost -e 'select 1' | head")
    c('DENY', 'db', 'N2 H1 커밋 히어독 E\\OF 뒤 mysql', 'git commit -F - <<E\\OF\nmsg\nEOF\nmysql -h %s -P7306' % P)
    c('DENY', 'db', 'N2 H3 <<"E"OF 뒤 python', 'cat > notes.md <<"E"OF\nmsg\nEOF\npython3 -c "%s"' % PYC)
    c('DENY', 'db', 'N2 H4 <<E"OF"', 'cat > notes.md <<E"OF"\nmsg\nEOF\nmysql -h %s' % P)
    c('ALLOW', 'db', 'N8 FP1 grep "ssh -L 3306"', 'grep -rn "ssh -L 3306" docs/')
    c('ALLOW', 'db', 'N8 FP2 커밋 메시지 ssh -L', 'git commit -m "docs: ssh -L 3306:db:3306 금지"')
    c('ALLOW', 'db', 'N8 FP4 커밋 히어독 ssh -L', "git commit -F - <<'EOF'\nfix: block ssh -L 3306\nEOF")
    c('ALLOW', 'db', 'FP5 grep pymysql.connect( && python3 --version', 'grep -rn "pymysql.connect(" src/ && python3 --version')
    c('DENY', 'db', 'FP11 dev mysql.connector 인라인(계약 변경)', "python3 -c \"import mysql.connector as mc;mc.connect(host='%s')\"" % D)
    c('DENY', 'db', 'X1 bash <<EOF mysql', 'bash <<EOF\nmysql -h %s\nEOF' % P)
    c('DENY', 'db', 'X2 ssh host mysql', 'ssh prod mysql -h localhost')
    c('DENY', 'db', 'X3 $(which python3) -c', '$(which python3) -c "%s"' % PYC)
    c('DENY', 'db', 'X4 sh -c "python3 -c …"', "sh -c 'python3 -c \"%s\"'" % PYC)
    c('DENY', 'db', 'X5 env python3', 'env python3 -c "%s"' % PYC)
    c('ALLOW', 'db', 'X6 mvn -Dmysql.host', 'mvn -q compile -Dmysql.host=PRODHOST')
    c('ALLOW', 'db', 'X7 lsof | grep mysql', 'lsof -i :3306 | grep mysql')
    c('ALLOW', 'db', 'X8 find | xargs grep -l mysql', "find . -name '*.xml' | xargs grep -l mysql")
    c('DENY', 'db', 'X9 pip 를 python -m 으로(오차단 감수)', 'python3 -m pip show pymysql')
    c('ALLOW', 'db', 'X10 pip3 show pymysql', 'pip3 show pymysql')
    c('DENY', 'db', 'R1 .py 로 쓰고 for…do python3 실행(코퍼스 회귀)', "cat > t.py <<'EOF'\nimport pymysql\nEOF\nfor m in a b; do python3 t.py $m\ndone")
    c('DENY', 'db', 'R2 함수 정의가 인자를 eval', "f(){ eval \"$1\"; }; f 'python3 -c \"import pymysql\"'")
    c('DENY', 'commit', 'R3 함수 정의 + commit 낱말', "f(){ eval \"$1\"; }; f 'git commit -m x'")
    c('NONE', 'commit', 'R4 파일명 commit-review.js', "sed -n 8,30p .claude/workflows/commit-review.js")
    c('NONE', 'commit', 'R5 스크립트 인자 속 commit(파일 실행)', 'bash .claude/hooks/mark-review.sh --skip-reason "docs only commit"')
    c('DENY', 'commit', 'R6 if/then 안 커밋', 'if true; then git commit -m x; fi')
    c('DENY', 'db', 'R7 if mysql 운영', 'if mysql -h %s -e "select 1"; then echo ok; fi' % P)
    N_PROTO = len(C)
    # ── ③ 반증 보강 — F1(데이터 실행어 → 실행될 만한 파일 → 실행) ──
    PYF = 'import pymysql\\npymysql.connect(host="%s",port=7306,password="DUMMY")\\n' % P
    c('DENY', 'db', 'F1a printf 커넥터 > /tmp/x.py && python3 /tmp/x.py', "printf '%s' > /tmp/x.py && python3 /tmp/x.py" % PYF)
    c('DENY', 'db', 'F1b echo 커넥터 > x.py && python3 x.py', "echo 'import pymysql; pymysql.connect(host=\"%s\")' > x.py && python3 x.py" % P)
    c('DENY', 'db', 'F1c printf >> x.py ; python3 x.py', "printf '%s' >> x.py; python3 x.py" % PYF)
    c('DENY', 'db', 'F1d printf | tee x.py && python3 x.py', "printf '%s' | tee x.py && python3 x.py" % PYF)
    c('DENY', 'db', 'F1e printf > notes.md && python3 tool.py(같은 호출에 실행 = 문서 면제 꺼짐, 리뷰 수리로 계약 변경)', "printf '%s' > notes.md && python3 tool.py" % PYF)
    c('ALLOW', 'db', 'F1f printf >/dev/null && python3 t.py', "printf '%s' >/dev/null && python3 t.py" % PYF)
    c('ALLOW', 'db', 'F1g printf > x.py 만(실행 없음)', "printf '%s' > x.py" % PYF)
    c('DENY', 'db', 'F1h printf > "$OUT"(변수 대상) && python3 "$OUT"', "printf '%s' > \"$OUT\" && python3 \"$OUT\"" % PYF)
    # ── ③ 단독 ssh·autossh 터널(결정 3) ──
    c('DENY', 'db', 'TN1 ssh -fNL', 'ssh -fNL 3306:%s:7306 bastion' % P)
    c('DENY', 'db', 'TN2 ssh -L(백그라운드·-N 없음)', 'ssh -L 3306:%s:7306 bastion sleep 600' % P)
    c('DENY', 'db', 'TN3 ssh -f -o "LocalForward …"', 'ssh -f -o "LocalForward 3306 %s:7306" bastion sleep 60' % P)
    c('DENY', 'db', 'TN4 ssh -oLocalForward=', 'ssh -f -oLocalForward=3306:%s:7306 bastion sleep 60' % P)
    c('DENY', 'db', 'TN5 autossh -M 0 -f -N -L', 'autossh -M 0 -f -N -L 3306:%s:7306 bastion' % P)
    c('ALLOW', 'db', 'TN6 ssh 원격 명령(터널 아님)', 'ssh bastion uptime')
    c('ALLOW', 'db', 'TN7 ssh -i 키 -p 포트 원격 명령', 'ssh -i ~/.ssh/k -p 2222 host ls')
    c('DENY', 'db', 'TN8 bash <<EOF 안 ssh -fNL', 'bash <<EOF\nssh -fNL 3306:%s:7306 bastion\nEOF' % P)
    c('ALLOW', 'db', 'TN9 커밋 메시지 속 ssh -N 문구', 'git commit -m "ssh -N 터널 금지"')
    c('ALLOW', 'db', 'TN10 ssh -G(설정 출력)', 'ssh -G bastion')
    c('DENY', 'db', 'TN11 env 래퍼 ssh -NL', 'env ssh -NL 3306:%s:7306 bastion' % P)
    c('DENY', 'db', 'TN12 호스트 뒤 옵션(ssh host -L …)', 'ssh bastion -L 3306:%s:7306 -N' % P)
    c('ALLOW', 'db', 'TN13 호스트 뒤 원격 명령의 -L 은 원격 인자', 'ssh bastion ls -L /tmp')
    # ── ③ 같은 호출에서 메시지 파일 작성 + 커밋 = 불허(결정 2) ──
    c('DENY', 'commit', 'MF1 cat > $M 히어독 + git commit -F $M', "M=/tmp/m.txt; cat > $M <<'EOF'\nmsg\nEOF\ngit commit -F $M")
    c('DENY', 'commit', 'MF2 printf > 파일 && git commit -F 파일', "printf 'msg' > /tmp/m.txt && git commit -F /tmp/m.txt")
    c('ALLOW', 'commit', 'MF3 앞 호출에서 쓴 파일 -F', 'git commit -F /tmp/m.txt')
    c('DENY', 'commit', 'MF4 tee 로 쓰고 커밋', "printf 'msg' | tee /tmp/m.txt && git commit -F /tmp/m.txt")
    c('DENY', 'commit', 'G1 층 A 합성 꼴(ALLOW_X=1 ; git commit)은 PreToolUse 판정이면 deny', 'ALLOW_TEST_COUNT_DROP=1 ; git commit')
    # ── ③ A티어 리뷰 CONFIRMED 3건(2026-11-11) — 첫 실행어 한정·같은 호출 실행 무시·'-' 낱말을 값으로 삼킴 ──
    PYP = "import pymysql; pymysql.connect(host='%s', password='DUMMY')" % P
    c('DENY', 'db', 'LR1 uv run python -c 커넥터', 'uv run python -c "%s"' % PYP)
    c('DENY', 'db', 'LR2 poetry run python3 -c 커넥터', 'poetry run python3 -c "%s"' % PYP)
    c('DENY', 'db', 'LR3 pipenv run python -c 커넥터', 'pipenv run python -c "%s"' % PYP)
    c('DENY', 'db', 'LR4 conda run -n x python -c 커넥터', 'conda run -n x python -c "%s"' % PYP)
    c('DENY', 'db', 'LR5 find -exec python3 -c 커넥터', "find . -exec python3 -c 'import pymysql' \\;")
    c('DENY', 'db', 'LR6 docker exec c python -c 커넥터', 'docker exec c python -c "%s"' % PYP)
    c('DENY', 'db', 'LR7 uv run mysql 운영(런처 경유 CLI)', 'uv run mysql -h %s -e "select 1"' % P)
    c('DENY', 'db', 'LR8 docker exec c mysql 운영', 'docker exec c mysql -h %s' % P)
    c('DENY', 'db', 'LR9 모르는 실행어 + 커넥터 낱말', 'myrunner --code "%s"' % PYP)
    c('ALLOW', 'db', 'LA1 uv run pytest(커넥터 낱말 없음)', 'uv run pytest -q')
    c('ALLOW', 'db', 'LA2 poetry run python manage.py migrate', 'poetry run python manage.py migrate')
    c('ALLOW', 'db', 'LA3 uv run python -m json.tool', 'uv run python -m json.tool a.json')
    c('ALLOW', 'db', 'LA4 docker exec c ls', 'docker exec c ls /app')
    c('ALLOW', 'db', 'LA5 find -exec grep(DB 낱말 없음)', "find . -name '*.py' -exec grep -l foo {} \\;")
    c('DENY', 'db', 'WE1 printf 커넥터 > .txt && python3 .txt', "printf 'import pymysql; pymysql.connect(host=\"%s\")' > /tmp/q.txt && python3 /tmp/q.txt" % P)
    c('DENY', 'db', 'WE2 echo 커넥터 > .log; python3 < .log', "echo 'import pymysql' > /tmp/a.log; python3 < /tmp/a.log")
    c('DENY', 'db', 'WE3 cat > .txt 히어독 커넥터 → python3 .txt', "cat > /tmp/a.txt <<'EOF'\n%s\nEOF\npython3 /tmp/a.txt" % PYP)
    c('DENY', 'db', 'WE4 printf mysql 운영 > .txt && bash .txt', "printf 'mysql -h %s' > /tmp/s.txt && bash /tmp/s.txt" % P)
    c('DENY', 'db', 'WE5 printf | tee .md && python3 .md', "printf 'import pymysql' | tee /tmp/q.md && python3 /tmp/q.md")
    c('ALLOW', 'db', 'WA1 커넥터 문구를 문서에만 씀(실행 없음)', "printf 'pymysql 은 쓰지 마라' > notes.md")
    c('ALLOW', 'db', 'WA2 DB 낱말 없는 쓰기 + python 실행', "printf 'hello' > a.txt && python3 t.py")
    c('DENY', 'db', 'PW1 mysqlsh --password(값 없음) --ssh=', 'mysqlsh -h localhost -u root --password --ssh=user@jump.prod')
    c('DENY', 'db', 'PW2 mycli --password --ssh-host', 'mycli -h localhost --password --ssh-host jump.prod db')
    c('DENY', 'db', 'PW3 -u 뒤 --socket(값으로 삼키지 않음)', 'mysql -h localhost -u --socket=/tmp/prod.sock')
    c('DENY', 'db', 'PW4 ssh -o 뒤 -L(값으로 삼키지 않음)', 'ssh -o -L3306:%s:7306 bastion' % P)
    c('ALLOW', 'db', 'PA1 mysql 로컬 --password(프롬프트) -e', "mysql -h localhost -u root --password -e 'select 1'")
    c('ALLOW', 'db', 'PA2 mysql 로컬 --password=더미 -e', "mysql -h localhost --password=DUMMY -e 'select 1'")
    # 같은 생성기 전수 스캔에서 나온 형태 — 런처 경유 터널·러너
    c('DENY', 'db', 'LR10 uv run ssh -fNL(런처 경유 터널)', 'uv run ssh -fNL 3306:%s:7306 bastion' % P)
    c('DENY', 'db', 'LR11 docker exec c ssh -L', 'docker exec c ssh -L 3306:%s:7306 bastion' % P)
    c('ALLOW', 'db', 'LA6 uv run ssh 원격 명령(터널 아님)', 'uv run ssh bastion uptime')
    c('DENY', 'db', 'WE6 printf mysql 운영 > .txt && uv run bash .txt', "printf 'mysql -h %s' > /tmp/s.txt && uv run bash /tmp/s.txt" % P)
    c('DENY', 'commit', 'CL1 uv run git commit', 'uv run git commit -m x')
    c('DENY', 'commit', 'CL2 env git commit', 'env git commit -m x')
    c('DENY', 'commit', 'CL3 command git commit', 'command git commit -m x')
    c('DENY', 'commit', 'CL4 find -exec git commit', "find . -exec git commit -m x \\;")

    def run_hook(cmd):
        r = subprocess.run(['bash', HOOK], input=json.dumps({'tool_input': {'command': cmd}, 'cwd': T}), capture_output=True, text=True, timeout=60)
        return 'DENY' if '"deny"' in r.stdout else 'ALLOW'
    ok = 0; rows = []
    for (e, m, n, s) in C:
        if m == 'commit':
            d, why = cf.judge_commit(s, G)
        else:
            d0, why = cf.judge_db(s)
            d = run_hook(s)
            if d != d0: why = (why + ' ' if why else '') + '[CLI 층 판정=' + d + ']'
        good = (d == e); ok += good
        rows.append('%s\t%s\t기대=%s\t실제=%s\t%s' % ('ok  ' if good else 'FAIL', m, e, d + ((' (' + why + ')') if why else ''), n))
    print('== ①시제품 %d행 + ③반증 보강 %d행 ==' % (N_PROTO, len(C) - N_PROTO))
    print('\n'.join(rows))
    run = len(C)

    # ── ② 1차·반증 합성(db_composite — 기대 = 설계 v2 + 결정 3) ──
    comp = [json.loads(l) for l in open(os.path.join(HERE, 'cmdform.db-composite.jsonl'), encoding='utf-8')]
    print('== ②합성 %d행 ==' % len(comp))
    for r in comp:
        d = run_hook(r['cmd']).lower()
        good = d == r['expect']; ok += good; run += 1
        print('%s\t기대=%s\t실제=%s\t%s%s' % ('ok  ' if good else 'FAIL', r['expect'], d, r['name'], (' — ' + r['note']) if r['note'] else ''))

    # ── ④ 판정기 실패 계약 ──
    print('== ④판정기 실패 계약 ==')
    def chk(name, cond):
        global ok, run
        run += 1; ok += bool(cond); print('%s\t%s' % ('ok  ' if cond else 'FAIL', name))
    orig = cf.judge_db
    try:
        cf.judge_db = lambda cmd: time.sleep(5) or ('ALLOW', '')
        t0 = time.time(); out, rc = cf.main(['cmdform.py', 'db'], b'mysql', limit=1)
        chk('E1 내부 상한 초과 → DENY rc=3 (%.1fs)' % (time.time() - t0), out.startswith('DENY') and rc == 3 and time.time() - t0 < 4)
        def boom(cmd): raise RuntimeError('x')
        cf.judge_db = boom
        out, rc = cf.main(['cmdform.py', 'db'], b'mysql')
        chk('E2 판정 예외 → DENY rc=3', out.startswith('DENY') and rc == 3)
    finally:
        cf.judge_db = orig
    out, rc = cf.main(['cmdform.py', 'bogus'], b'x')
    chk('E3 모르는 모드 → DENY rc=2', out.startswith('DENY') and rc == 2)
    out, rc = cf.main(['cmdform.py', 'db'], b'mysql \xff\xfe')
    chk('E4 UTF-8 아님 → DENY rc=3', out.startswith('DENY') and rc == 3)
    deep = 'git commit -m ' + '"$(' * 3000 + 'x' + ')"' * 3000
    r = subprocess.run(['python3', '-I', os.path.join(HK, 'lib', 'cmdform.py'), 'commit', G], input=deep, capture_output=True, text=True, timeout=30)
    chk('E5 깊은 $( 중첩(재귀 한도) → rc≠0 또는 DENY (rc=%d)' % r.returncode, r.returncode != 0 or r.stdout.startswith('DENY'))
    print()
    print('Tests run: %d, Passed: %d' % (run, ok))
    sys.exit(0 if run == ok and run > 0 else 1)
finally:
    subprocess.run(['git', '-C', os.path.join(T, 'g1'), 'worktree', 'prune'], capture_output=True)
    shutil.rmtree(T, ignore_errors=True)
PY
