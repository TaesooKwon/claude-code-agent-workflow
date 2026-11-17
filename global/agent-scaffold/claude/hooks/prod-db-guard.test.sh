#!/usr/bin/env bash
# prod-db-guard.sh 계약 테스트 — 히어독 판정(lib 허용 목록)과 접속 탐지의 접합부를 stdin JSON 으로 태운다.
# 실행: bash .claude/hooks/prod-db-guard.test.sh
# 호스트 판정 자체(허용 2축·포트 게이트)는 훅 본문 몫이라 여기선 "운영으로 간주되는 호스트" 한 가지로만 본다.
# 반증 예고: 종전 인라인 awk 판(2026-09-18 이전)으로 돌리면 D3(here-string 다음 줄)·D4(인용 안 << 다음 줄)·
#   D5(파이프로 python)·D6(스크립트로 쓰고 실행)의 4건이 allow 로 새야 한다 — 종전 판은 앞 둘을 히어독 시작으로
#   오인해 다음 줄을 걷어냈고, 뒤 둘은 받는 명령이 cat 이라 본문을 걷어냈다. 그 외 건수면 케이스나 구현이 어긋난 것.
#   D6 은 본문이 남아야만 잡힌다(`python3 c.py` 줄에는 커넥터 문자열이 없다) — 파일 실행 천장의 "같은 호출" 부분만 닫는다.
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/prod-db-guard.sh"
[ -f "$HOOK" ] || { echo "훅 없음: $HOOK"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "전제 도구 없음(jq) — 테스트를 실행하지 않았다"; exit 2; }

run=0; passed=0
PROD=prod-db.example.invalid
_case() { # $1=deny|allow $2=설명 $3=명령
  local out got
  out=$(jq -n --arg c "$3" '{tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"deny"'; then got=deny; else got=allow; fi
  run=$((run + 1))
  if [ "$got" = "$1" ]; then passed=$((passed + 1)); printf 'ok    %-44s [%s]\n' "$2" "$got"
  else printf 'FAIL  %-44s 기대=%s 실제=%s\n' "$2" "$1" "$got"; fi
}
PYC="import pymysql; pymysql.connect(host='$PROD')"

_case deny  "D1 인라인 python -c 운영 접속"        "python3 -c \"$PYC\""
_case deny  "D2 python3 - 히어독 본문 접속"          "$(printf "python3 - <<'PY'\n%s\nPY" "$PYC")"
_case deny  "D3 here-string 다음 줄의 접속"         "$(printf 'tr a-z A-Z <<<x\npython3 -c "%s"' "$PYC")"
_case deny  "D4 인용 안 << 다음 줄의 접속"          "$(printf 'echo "see <<NOTE"\npython3 -c "%s"' "$PYC")"
_case deny  "D5 cat <<EOF | python3"               "$(printf 'cat <<EOF | python3\n%s\nEOF' "$PYC")"
_case deny  "D6 스크립트로 쓰고 실행(python3 c.py)"  "$(printf "cat <<'EOF' > c.py\n%s\nEOF\npython3 c.py" "$PYC")"
_case deny  "D7 <<\\EOF 문서 뒤 줄의 접속(R4)"      "$(printf 'cat > a.md <<\\EOF\n본문\nEOF\npython3 -c "%s"' "$PYC")"
_case deny  "D8 ( cat <<EOF … ) | python3(R4)"      "$(printf '( cat <<EOF\n%s\nEOF\n) | python3' "$PYC")"
_case allow "A1 문서에 접속 서술을 덧붙임(실측 오탐)" "$(printf "cat >> 설계.md <<'EOF'\nMariaDB 접속: python3 -c \"%s\"\nEOF" "$PYC")"
_case allow "A2 코드 검색(grep)"                    "grep -rn pymysql scripts/"
_case allow "A3 무관 명령"                          'ls -la'

# mysql/mysqldump 실행어 자리(2026-10-08) — permissions.deny 패턴이 못 막을 수 있는 형태를 훅이 2차로 잡는다.
# 반증 예고: 훅의 DB_EXEC_NAMES 에서 mysql 을 빼면 M1~M5·M7·M15 가 allow 로 새야 한다(M6 은 기존 CLI 규칙이 잡는다).
_case deny  "M1 인자 없는 맨 mysql"                 'mysql'
_case deny  "M2 절대경로 운영 호스트"               "/opt/homebrew/bin/mysql -h $PROD -u r"
_case deny  "M3 env 대입 접두"                      "env MYSQL_PWD=x mysql -h $PROD"
_case deny  "M4 command 접두"                       "command mysql -h $PROD"
_case deny  "M5 cd x && mysql -h 운영"              "cd /tmp && mysql -h $PROD -e 'select 1'"
_case deny  "M6 mysqldump 운영"                     "mysqldump -h $PROD appdb"
_case deny  "M7 파이프 뒤 mysql"                    "cat q.sql | mysql -h $PROD"
_case allow "M8 mysql -h 127.0.0.1(허용 목록)"      'mysql -h 127.0.0.1 -u root'
_case allow "M9 mysqldump -h localhost(허용 목록)"  'mysqldump -h localhost appdb'
_case allow "M10 grep -r mysql ."                   'grep -r mysql .'
_case allow "M11 brew info mysql"                   'brew info mysql'
_case allow "M12 ls 경로 속 mysql"                  'ls /opt/homebrew/opt/mysql'
_case allow "M13 문서 히어독 본문 속 mysql"          "$(printf "cat >> notes.md <<'EOF'\nmysql -h %s\nEOF" "$PROD")"
_case allow "M14 echo 라벨 속 mysql"                'echo "mysql 접속 안내"'
_case deny  "M15 bash 로 넘기는 히어독 본문 속 mysql" "$(printf "bash <<'EOF'\nmysql -h %s\nEOF" "$PROD")"

# DB CLI 허용 목록 재설계(2026-10-08) — 반증자 케이스(cases.txt·cases2.txt, dev 호스트 전용 2건 제외) + 계약 케이스.
# 반증 예고: ①기본=접속을 기본=허용으로 뒤집으면 deny 케이스 대부분이 allow 로 샌다 ②정규화가 따옴표 내용을 지우면
#   R'"mysql"'·R''mysql''·m''ysql·"mysqldump" 등 따옴표 케이스가 샌다.
while IFS=$'\t' read -r _want _c; do
  [ -n "$_want" ] || continue
  _case "$_want" "R ${_c//PRODHOST/prod}" "${_c//PRODHOST/$PROD}"
done <<'DBCASES'
deny	mysql
deny	mysql -h PRODHOST -u root
deny	/usr/local/bin/mysql -h PRODHOST
deny	env MYSQL_PWD=x mysql -h PRODHOST
deny	command mysql -h PRODHOST
deny	cd x && mysql -h PRODHOST
deny	./mysql -h PRODHOST
deny	~/bin/mysql -h PRODHOST
deny	MYSQL -h PRODHOST
deny	echo 'select 1' | xargs mysql -h PRODHOST
deny	xargs mysql -h PRODHOST < f
deny	$(which mysql) -h PRODHOST
deny	`which mysql` -h PRODHOST
deny	\mysql -h PRODHOST
deny	mysql	-h	PRODHOST
deny	exec -a foo mysql -h PRODHOST
deny	nice -n 5 mysql -h PRODHOST
deny	timeout 5 mysql -h PRODHOST
deny	bash -c 'mysql -h PRODHOST'
deny	sh -c "mysql -h PRODHOST"
deny	mysql --host=PRODHOST
deny	mysql -hPRODHOST
deny	mysql --defaults-file=/tmp/prod.cnf
deny	mysql --defaults-file=/tmp/prod.cnf -h localhost
deny	mysql --login-path=prod -h localhost
deny	mysql -h 127.0.0.1 -P 33306
deny	mysql -h 127.0.0.1 --port 33306
deny	mysql -h localhost.evil.com
deny	mysql -h localhost -e "select 1" ; mysql -h PRODHOST
deny	mysql -u root -h localhost --host PRODHOST
deny	sudo -u x mysql -h PRODHOST
deny	"mysql" -h PRODHOST
deny	m=mysql; $m -h PRODHOST
deny	mysql -h 10.0.0.5
deny	mysql -h localhost -h PRODHOST
deny	mysql -h localhost:33306
deny	mysql -h "PRODHOST"
deny	if true; then mysql -h PRODHOST; fi
deny	time mysql -h PRODHOST
deny	mysql < dump.sql
deny	mysql -h localhost -e "select * from x where a='#'" -h PRODHOST
deny	ssh prod mysql -h localhost
deny	mysqlsh --uri root@PRODHOST
deny	m''ysql -h PRODHOST
deny	'mysql' -h PRODHOST
deny	my\sql -h PRODHOST
deny	mysql -h localhost '#' -h PRODHOST
deny	mysql -h PRODHOST # -h localhost
deny	mysql -h     PRODHOST --user=root@localhost
deny	mysql --host      PRODHOST
deny	mysql -h 127.0.0.1 -P 3306 -P 33306
deny	env -u FOO mysql -h PRODHOST
deny	env -i mysql -h PRODHOST
deny	nice mysql -h PRODHOST
deny	{ mysql -h PRODHOST; }
deny	(mysql -h PRODHOST)
deny	MYSQL_HOST=PRODHOST mysql -u root
deny	mysqldump -h PRODHOST db
deny	"mysqldump" -h PRODHOST db
deny	mysqldump
deny	mysql -h localhost -e "system mysql -h PRODHOST"
deny	echo "x" ; mysql
deny	mysql -h localhost -e "select 1 from t where c='#'" -h 10.1.1.1
deny	foo mysql -h PRODHOST
deny	MYSQL_HOST=PRODHOST mysql -h localhost
deny	mysql -h localhost -e "select @PRODHOST"
allow	mysql -h localhost
allow	mysql -h localhost --protocol=tcp -S x prod
allow	mysql -u root -pXX -h localhost prod_db
allow	mysql -e "x" -h PRODHOST -h localhost
allow	mysql -h 'localhost' -P3306
allow	mysql -h127.0.0.1 -P3306
allow	mysql -h 127.0.0.1 -P 33306 -P 3306
allow	mysql -u root -h localhost -P 3306 -e "select 1"
allow	grep -rn "mysql -h" docs/
allow	grep -rn mysql docs/
allow	git log --grep mysql
allow	echo mysql
allow	find . -name '*mysql*'
allow	brew services list | grep mysql
allow	brew info mysql
allow	cat /opt/homebrew/etc/my.cnf
allow	which mysql
allow	type mysql
allow	ls /usr/local/bin/mysql
allow	mvn -q compile -Dmysql.host=PRODHOST
allow	man mysql
allow	pgrep -fl mysql
allow	lsof -i :3306 | grep mysql
allow	grep -c mysqldump x.txt
allow	ps aux | grep mysqld
allow	grep -rn mysqldump docs/
allow	git log --grep mysqldump
allow	brew info mariadb
allow	grep -rn "mariadb -h" .
allow	echo mysql -h prod
allow	mysql --help
allow	mysql --version
allow	mysql -V
allow	grep -rn mariadb-dump .
DBCASES
_case deny  "R2 파이썬 히어독 속 문자열 mysql -h 운영(보수적 차단)" "$(printf "python3 - <<'PY'\nprint(\"mysql -h %s\")\nPY" "$PROD")"
_case allow "R3 문서 히어독 본문 속 mysqldump 줄" "$(printf "cat >> notes.md <<'EOF2'\nmysqldump -h %s db\nEOF2" "$PROD")"

# 빠른 경로(2026-10-08) — 백슬래시·따옴표를 지운 사본에 DB 낱말이 없으면 정밀 판정을 건너뛴다.
# 반증 예고: 빠른 경로 조건을 "항상 건너뜀"으로 바꾸면 F1 과 위 deny 케이스가 전부 allow 로 샌다.
_case deny  "F1 따옴표로 쪼갠 낱말은 빠른 경로를 지나 정밀 판정" "m''ysql -h $PROD"
_long=""; for _i in $(seq 1 40); do _long="${_long:+$_long && }grep -rn \"pattern$_i\" src/main/java | head -3"; done
_case allow "F2 DB 낱말 없는 긴 명령(빠른 경로 통과)" "$_long"

# 의뢰 13(2026-10-08) — 계열 접두 DB 낱말 · 투명 래퍼를 벗긴 뒤 재판정 · 커밋 메시지 히어독.
# 반증 예고: ①접두 대조를 완전일치(옛 목록)로 되돌리면 P1~P5 가 allow 로 샌다 ②래퍼 재판정을 빼면 W1·W2 가 deny 로 막힌다.
_case deny  "P1 mysqlcheck -h 운영"                 "mysqlcheck -h $PROD db"
_case deny  "P2 mysqlpump -h 운영"                  "mysqlpump -h $PROD db"
_case deny  "P3 mysqlshow -h 운영"                  "mysqlshow -h $PROD"
_case deny  "P4 mysqlbinlog -h 운영"                "mysqlbinlog -h $PROD --read-from-remote-server x"
_case deny  "P5 mysql_upgrade -h 운영"              "mysql_upgrade -h $PROD"
_case allow "W1 find | xargs grep -l mysql"          "find . -name '*.xml' | xargs grep -l mysql"
_case allow "W2 timeout 30 grep -rn mysql"           'timeout 30 grep -rn mysql src'
_case deny  "W3 timeout 30 mysql -h 운영(벗긴 뒤 DB)" "timeout 30 mysql -h $PROD"
_case deny  "W4 xargs -I{} sh -c (애매 — 기존 판정 유지)" "echo x | xargs -I{} sh -c \"mysql -h {}\""
_case deny  "W5 xargs 미확정 옵션(-P 4) 뒤 grep — 벗기지 않음" "find . | xargs -P 4 grep -l mysql"
_case allow "C1 git commit -F - 히어독 본문 속 mysql" "$(printf "git commit -F - <<'EOF'\nfix: mysql -h %s 접속 가드 보강\nEOF" "$PROD")"
_case deny  "C2 커밋 히어독이 끝난 다음 줄의 접속은 판정" "$(printf "git commit -F - <<'EOF'\nfix: 메시지\nEOF\nmysql -h %s" "$PROD")"
# 2026-11-05 사냥 probe 회귀 — 파이썬 실행어 경계·정규화 사본·커넥터 확장
_case deny  "Y1 python3<<'PY'(공백 없는 히어독)"    "$(printf "python3<<'PY'\n%s\nPY" "$PYC")"
_case deny  "Y2 \"python3\" - 히어독"                "$(printf "\"python3\" - <<'PY'\n%s\nPY" "$PYC")"
_case deny  "Y3 \\python3 -c"                        "\\python3 -c \"$PYC\""
_case deny  "Y4 py''thon3 -c(쪼갠 인용 — 정규화 사본)" "py''thon3 -c \"$PYC\""
_case deny  "Y5 import MySQLdb 대소문자(mysqldb)"    "python3 -c \"import mysqldb; mysqldb.connect(host='$PROD')\""
_case deny  "Y6 import mariadb"                      "python3 -c \"import mariadb; mariadb.connect(host='$PROD')\""
_case deny  "Y7 aiomysql"                            "python3 -c \"import aiomysql; aiomysql.connect(host='$PROD')\""
_case deny  "Y8 asyncmy"                             "python3 -c \"import asyncmy; asyncmy.connect(host='$PROD')\""
_case deny  "Y9 (python3 -c …) 서브셸"               "(python3 -c \"$PYC\")"
_case allow "Y10 python3<<'PY' 커넥터 없음"          "$(printf "python3<<'PY'\nprint(1)\nPY")"
# 킷 가드 v2(2026-11-11) — 인라인 python 의 DB 접속은 호스트와 무관하게 차단(정본 = DB MCP·스킬 스크립트 파일 실행). Y11·Y15·P3·P4 는 계약 변경.
_case deny  "Y11 python3 -c localhost(인라인 python = 호스트 무관 차단)"  "python3 -c \"import pymysql; pymysql.connect(host='localhost', port=3306)\""
_case allow "Y12 pythonic 낱말(실행어 아님)"         "echo pythonic pymysql"
# 2026-11-05 층 B 리뷰(rvB attack#6·fp#6) — SQLAlchemy URL 드라이버명 · URL 사용자 정보 · 맨 mariadb 낱말
_case deny  "Y13 mysql+mysqlconnector:// URL"         "python3 -c \"import sqlalchemy as s; s.create_engine('mysql+mysqlconnector://u:p@$PROD/db').connect()\""
_case deny  "Y14 plain mysql:// URL"                   "python3 -c \"import sqlalchemy as s; s.create_engine('mysql://u:p@$PROD/db').connect()\""
_case deny  "Y15 localhost URL(인라인 python = 호스트 무관 차단)" "python3 -c \"import sqlalchemy as s; s.create_engine('mysql+pymysql://u:p@localhost/db').connect()\""
_case deny  "Y16 from mariadb import"                  "python3 -c \"from mariadb import connect; connect(host='$PROD')\""
_case allow "Y17 python 실행 && grep mariadb(오탐 대조)" "python3 -m json.tool a.json && grep -n mariadb {{MODULE_CORE}}/pom.xml"
# 2026-11-05 층 B 델타 리뷰 — URL 갈래가 JDBC 문자열에 걸리던 오탐
_case allow "Y18 python 실행 && grep jdbc:mariadb://(오탐 대조)" "python3 -m json.tool a.json && grep -rn \"jdbc:mariadb://\" {{MODULE_CORE}}/src/main/resources"
_case deny  "Y19 따옴표 안 mariadb:// URL 은 그대로 접속"     "python3 -c \"import sqlalchemy as s; s.create_engine('mariadb://u:p@$PROD/db').connect()\""

# 파이썬 경로 포트 판정(종전 회귀) — v2 에선 인라인 python 이 호스트·포트와 무관하게 막히므로 아래 넷 모두 차단이 기대값이다.
_case deny  "P1 python 표준 포트 뒤 비표준 포트 접속"   "python3 -c \"import pymysql; pymysql.connect(host='127.0.0.1', port=3306); pymysql.connect(host='127.0.0.1', port=33306)\""
_case deny  "P2 python host:3306 뒤 port=33306"          "python3 -c \"import pymysql; c=pymysql.connect(host='localhost:3306'); d=pymysql.connect(host='localhost', port=33306)\""
_case deny  "P3 python 두 접속 모두 표준 포트(인라인 python = 호스트 무관 차단)" "python3 -c \"import pymysql; pymysql.connect(host='127.0.0.1', port=3306); pymysql.connect(host='localhost', port=3316)\""
# P4 의 호스트 = 훅의 포트 무관 축 대입 줄 첫 갈래(`\.` → `.`). 빈 값(킷 기본)이거나 리터럴 호스트가 아니면 건너뛴다.
_any=$(sed -n "s/^ALLOWED_DB_HOSTS_ANYPORT_REGEX='\(.*\)'.*/\1/p" "$HOOK" | head -1)
_anyh=$(printf '%s' "${_any%%|*}" | sed 's/\\\././g')
if [ -n "$_anyh" ] && printf '%s' "$_anyh" | grep -Eqx '[A-Za-z0-9.-]+'; then
  _case deny  "P4 python 포트 무관 축 호스트 비표준(인라인 python = 호스트 무관 차단)" "python3 -c \"import pymysql; pymysql.connect(host='$_anyh', port=13306)\""
else
  echo "skip  P4 포트 무관 축 비어 있음(또는 리터럴 아님) — 판정 대상 없음"
fi

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -eq "$passed" ] || exit 1
