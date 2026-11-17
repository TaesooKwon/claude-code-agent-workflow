#!/usr/bin/env python3
"""session-grep.py 마스킹 테스트 — 합성 입력만 쓴다(실제 세션 원문을 읽지 않는다).

  python3 .claude/scripts/session-grep.test.py

보는 것: ①양성 = 비밀 원값('S3cr')이 결과에 남지 않는다 ②json.dumps 판(tool_use 입력 모양)도 같다
③음성 = 지시어가 없는 줄은 원문 그대로 ④1MB 반복 입력이 각 2초 안에 끝난다.
"""
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('session_grep', os.path.join(HERE, 'session-grep.py'))
sg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sg)

SECRET = 'S3cr'
POSITIVE = [
    'Authorization: Bearer S3cr.abc', 'Authorization: Token S3cr', 'Authorization: Digest response="S3cr"',
    '{\\"password\\":\\"S3cr et\\"}', 'password="a b S3cr"', 'password="unclosed S3cr', 'password=pa;S3cr',
    'PGPASSWORD=S3cr', 'SECRET_KEY=S3cr', 'AWS_SECRET_ACCESS_KEY=S3cr', 'DB_PASSWORD_PROD=S3cr',
    'PASSWORD          =   S3cr', 'password => "S3cr"', '<password>S3cr</password>',
    "mysql -uroot -p'S3cr c' db", 'mysql -uroot -p"S3cr c" db', 'mysql -h db.local \\\n  -pS3cr dbname',
    'mysql -h db.local \\\n-pS3cr dbname',
    'curl -uuser:S3cr https://x', 'curl --user=u:S3cr https://x', 'curl -s https://x -u u:S3cr',
    'redis://:S3cr@host:6379', 'mysql://u:p@S3cr@host/db', 'https://u:ab/S3cr@host',
    'sshpass -p S3cr ssh host', 'SSHPASS=S3cr sshpass -e ssh host', 'docker login -u me -p S3cr reg',
    'redis-cli -a S3cr ping', 'redis-cli --pass S3cr', 'REDISCLI_AUTH=S3cr redis-cli',
    'SMS_PW=S3cr', 'DB_PASS=S3cr', 'pass: S3cr', '{"pw":"S3cr"}', 'passphrase=S3cr', 'MYSQL_PWD: S3cr',
    '비밀번호: S3cr', '암호=S3cr',
    # 명령이 줄 중간(줄바꿈·탭 뒤)에 오는 경우 — json 판에선 앞 글자가 리터럴 \n·\t 의 n·t 가 된다
    'cd /x\nmysql -uroot -pS3cr db', 'echo\nredis-cli -a S3cr', 'a &&\tcurl -u u:S3cr x', 'cd /x\n\tdocker login -p S3cr r',
    # 붙임 키(camelCase·대문자 연속·소문자 붙임 pwd)
    'cfg:\n\tpw = S3cr', 'a\tpass: S3cr', 'x\npass: S3cr', 'mysql db "-pS3cr"', "mysql db '-pS3cr'",
    'curl -U u:S3cr https://x', 'curl --proxy-user u:S3cr https://x', 'mysql db (-pS3cr)',
    'mysql -u root \\\r\n -pS3cr', 'docker  \\\nlogin -p S3cr', 'x\rpass: S3cr', 'mysql db\r-pS3cr', 'x\rghp_S3cr0000000000',
    'jdbc.dbPwd = S3cr', 'DBPWD=S3cr', 'userpwd=S3cr', 'adminPw: S3cr', 'smsPass=S3cr', 'SMSPW=S3cr', 'mysqldump --password S3cr db', 'x ' * 50 + 'mysql ' + 'y ' * 300 + '-pS3cr',
]
NEGATIVE = [
    'mvn -pl CMS-Core -am test', 'ssh -p 22 host', 'passed=3', 'bypass=true', 'compass=x',
    'tests pass now', 'a.passive = 1', '수업개설 마법사 저장 경로를 확인했다', 'Pass rate 12 of 12',
]
fails = 0
run = 0


def check(name, ok, detail=''):
    global fails, run
    run += 1
    if not ok:
        fails += 1
        print('FAIL %s %s' % (name, detail))


for s in POSITIVE:
    check('양성', SECRET not in sg.mask(s), repr(sg.mask(s))[:160])
    js = json.dumps({'command': s}, ensure_ascii=False)
    check('양성(json)', SECRET not in sg.mask(js), repr(sg.mask(js))[:160])
# 모양 규칙(토큰 접두·hex) — 줄바꿈 뒤에 오면 json 판에선 앞 글자가 리터럴 \n 의 n 이 된다
for tok in ['ghp_' + 'Ab1' * 12, '0123456789abcdef' * 2]:
    for s in ['x ' + tok, 'x\n' + tok, 'x\t' + tok]:
        for v in (s, json.dumps({'command': s}, ensure_ascii=False)):
            check('모양', tok not in sg.mask(v), repr(sg.mask(v))[:160])
for s in NEGATIVE:
    check('음성', sg.mask(s) == s, repr(sg.mask(s))[:160])

for unit in ['secret', 'token-', 'a.', 'mysql ', 'curl -u', 'http://u:', 'pass ', 'a' * 64 + ' ']:
    big = unit * (1_000_000 // len(unit))
    t = time.time()
    sg.mask(big)
    sg.mask(big.replace(' ', '\n'))
    dt = time.time() - t
    check('성능 %r' % unit, dt < 2.0, '%.2fs' % dt)

print('Tests run: %d, passed: %d, failed: %d' % (run, run - fails, fails))
sys.exit(1 if fails or run == 0 else 0)
