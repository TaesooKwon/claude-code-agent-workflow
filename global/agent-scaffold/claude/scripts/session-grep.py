#!/usr/bin/env python3
"""지난 Claude Code 세션 원문(jsonl)을 키워드로 검색한다 — 읽기 전용·로컬 전용·네트워크 0.

사용 예:
  python3 .claude/scripts/session-grep.py prod_init_20261103
  python3 .claude/scripts/session-grep.py tn_sample ALTER --since 2026-10-01 --role all
  python3 .claude/scripts/session-grep.py 과목개설기간 --sessions

출력 스니펫은 비밀값을 항상 가린다(끄는 옵션 없음). 방식 = 의심 지시어가 나오면 그 뒤를 논리 줄 끝까지 통째로 가린다
(과잉 가림 허용 — 노출은 되돌릴 수 없다): 비밀 낱말(password·secret·token·pwd·authorization·비밀번호 등) · 짧은 키(pw·pass)
뒤 구분자 · DB/접속 명령(mysql·redis-cli·sshpass·docker login·curl) 이름 · URL 자격(scheme://user:pw@).
남은 줄에는 토큰 접두·긴 hex/base64 모양도 가린다. 테스트 = session-grep.test.py.
ponytail: 지시어 없는 산문 속 비밀값·다음 줄로 넘어간 값(YAML 블록)·목록 밖 명령(psql 등)은 못 가린다 / 업그레이드 = 엔트로피 판정.
복제본(레포 .claude/scripts · ~/.claude/agent-scaffold · 킷 global/agent-scaffold)은 자동 대조 밖 — 고치면 함께 맞춘다.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
PROJECTS_ROOT = os.path.expanduser('~/.claude/projects')


def default_dir():
    """현재 레포(git toplevel, 실패하면 cwd)의 Claude Code 세션 폴더 경로를 계산한다."""
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True,
                             timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        top = ''
    top = top or os.getcwd()
    # Claude Code 폴더명 규칙: 영숫자 외 문자를 각각 '-' 로(/·.·_ 실측 대조).
    # ponytail: 비 ASCII(한글) 경로·아주 긴 경로의 폴더명은 실물 대조 못 함 / 어긋나면 --dir 로 지정
    return os.path.join(PROJECTS_ROOT, re.sub(r'[^A-Za-z0-9]', '-', top))

# 논리 줄 = 실제 줄바꿈 기준, 백슬래시 줄 이음(LF·CRLF)은 같은 줄. tool_use 입력은 json.dumps 판이라 줄바꿈이 리터럴 \n 로 들어온다.
LINE_SPLIT = re.compile(r'(?<!\\)(?<!\\\r)\n')
# 앞 경계 = 앞 글자가 영숫자가 아님(`_`·`.` 뒤 포함 — SMS_PW·x_ghp_… 도 잡는다), 또는 json 판의 리터럴 \n·\t·\r(앞 글자가 n·t·r 이라 \b 가 성립하지 않는다).
# SHORT_KEY 첫 대안·CMD·SHAPES 가 이 상수를 함께 쓴다 — 규칙마다 따로 적으면 축이 어긋난다
# (SHORT_KEY 의 camelCase·대문자 연속 대안은 의도적으로 다른 경계).
JB = r'(?:(?<![A-Za-z0-9])|(?<=\\[ntr]))'
# 긴 지시어 = 부분문자열(대소문자 무시) — PGPASSWORD·SECRET_KEY 같은 붙임 키까지. secretary·tokenizer 같은 과잉 가림은 수용.
LONG_WORD = re.compile(r'(?i)password|passwd|passphrase|secret|token|api[_-]?key|apikey|credential|authorization'
                       r'|private[_-]?key|bearer|sshpass|pwd|_auth(?![a-z0-9])|비밀번호|암호|패스워드')
# 짧은 지시어(pw·pass) = 뒤 구분자가 있고, 앞이 낱말 경계·camelCase(adminPw·smsPass)·대문자 연속(SMSPW)일 때만
# (소문자끼리 붙은 bypass·compass·passive 는 보존 · 대문자 BYPASS= 는 과잉 가림 수용).
SHORT_KEY = re.compile(r'(?:' + JB + r'(?i:pw|pass)|(?<=[a-z0-9])(?:Pw|PW|Pass|PASS)|(?<=[A-Z])(?:PW|PASS))'
                       r'(?![A-Za-z0-9])\\?["\']?[ \t]{0,40}(?:=>|[:=])')
# 접속 명령은 이름 뒤를 줄 끝까지 가린다 — 자격 플래그 목록(-p·-u·-U·--proxy-user …)을 쫓지 않는다(과잉 가림 수용).
CMD = re.compile(r'(?i)' + JB + r'(?:mysql\w*|mariadb\w*|sshpass|redis-cli|docker(?:\s|\\n|\\){1,20}login|curl)\b')
URL_CRED = re.compile(r'://[^\s/@]{0,64}:\S{0,300}@')
SHAPES = [
    re.compile(JB + r'(?:sk|ghp|gho|ghs|xox[abp])[-_][A-Za-z0-9_\-]{8,}'),
    re.compile(JB + r'[0-9a-fA-F]{32,}\b'),
    re.compile(r'[A-Za-z0-9+/]{40,}={0,2}'),
]


def _cut(line):
    """가리기 시작할 위치(없으면 None) — 지시어·접속 명령·URL 자격 중 가장 앞."""
    cands = []
    m = LONG_WORD.search(line)
    if m:
        cands.append(m.end())
    m = SHORT_KEY.search(line)
    if m:
        cands.append(m.end())
    m = CMD.search(line)
    if m:
        cands.append(m.end())
    m = URL_CRED.search(line)
    if m:
        cands.append(m.start() + 3)
    return min(cands) if cands else None


def mask(text):
    out = []
    for line in LINE_SPLIT.split(text):
        cut = _cut(line)
        if cut is not None:
            line = line[:cut] + ' ***'
        for pat in SHAPES:
            line = pat.sub('***', line)
        out.append(line)
    return '\n'.join(out)


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def parse_date(s, name):
    try:
        return datetime.strptime(s, '%Y-%m-%d').replace(tzinfo=KST)
    except ValueError:
        fail('잘못된 날짜 형식입니다: %s (YYYY-MM-DD)' % name)


def iter_texts(rec, roles):
    """레코드에서 (role, text) 를 뽑는다. 모르는 모양은 조용히 건너뛴다."""
    t = rec.get('type')
    msg = rec.get('message') if isinstance(rec.get('message'), dict) else None
    if t not in ('user', 'assistant') or msg is None:
        return
    content = msg.get('content')
    if isinstance(content, str):
        if t in roles:
            yield t, content
        return
    if not isinstance(content, list):
        return
    for part in content:
        if not isinstance(part, dict):
            continue
        pt = part.get('type')
        if pt == 'text' and t in roles:
            yield t, str(part.get('text', ''))
        elif pt == 'tool_use' and 'tool' in roles:
            yield 'tool', json.dumps(part.get('input', {}), ensure_ascii=False)
        elif pt == 'tool_result' and 'tool' in roles:
            c = part.get('content')
            if isinstance(c, list):
                c = ' '.join(str(x.get('text', '')) for x in c if isinstance(x, dict))
            yield 'tool', str(c or '')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('terms', nargs='+', help='검색어(여러 개면 AND)')
    ap.add_argument('--dir', help='jsonl 디렉터리(기본 = 현재 레포의 세션 폴더)')
    ap.add_argument('--regex', action='store_true', help='검색어를 정규식으로')
    ap.add_argument('-i', action='store_true', help='대소문자 무시(기본값이라 생략 가능)')
    ap.add_argument('--case', action='store_true', help='대소문자 구분(기본 = 무시)')
    ap.add_argument('--since')
    ap.add_argument('--until')
    ap.add_argument('--role', default='text', choices=['text', 'user', 'assistant', 'tool', 'all'],
                    help='text = user+assistant 본문(기본) / tool = 도구 입력·결과만 / all = 전부')
    ap.add_argument('--max', type=int, default=20, help='표시 건수 상한(집계는 전부 센다)')
    ap.add_argument('--context', type=int, default=150, help='일치 앞뒤 글자 수')
    ap.add_argument('--sessions', action='store_true', help='세션별 건수·첫 사용자 메시지만')
    a = ap.parse_args()

    roles = {'text': {'user', 'assistant'}, 'user': {'user'}, 'assistant': {'assistant'},
             'tool': {'tool'}, 'all': {'user', 'assistant', 'tool'}}[a.role]
    flags = 0 if a.case else re.IGNORECASE
    try:
        pats = [re.compile(t if a.regex else re.escape(t), flags) for t in a.terms]
    except re.error:
        fail('잘못된 정규식입니다.')
    since = parse_date(a.since, '--since') if a.since else None
    until = parse_date(a.until, '--until') + timedelta(days=1) if a.until else None
    if a.dir is None:
        a.dir = default_dir()
        if not os.path.isdir(a.dir):
            fail('현재 레포의 세션 폴더가 없습니다: %s (--dir 로 지정하세요)' % a.dir)
    elif not os.path.isdir(a.dir):
        fail('디렉터리가 없습니다: %s' % a.dir)

    # ponytail: 매 실행 전수 선형 스캔(인덱스 없음) / 느려지면 파일 mtime 으로 --since 사전 필터 또는 SQLite FTS 캐시
    files = sorted(glob.glob(os.path.join(a.dir, '*.jsonl')))
    total, shown, skipped = 0, 0, 0
    sessions = {}
    firsts = {}
    for path in files:
        try:
            fh = open(path, 'r', encoding='utf-8', errors='replace')
        except OSError:
            skipped += 1
            continue
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    skipped += 1  # 깨진 줄·쓰는 중인 마지막 줄
                    continue
                if not isinstance(rec, dict):
                    skipped += 1
                    continue
                ts = rec.get('timestamp')
                try:
                    dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone(KST) if ts else None
                except (ValueError, AttributeError):
                    dt = None
                if dt and ((since and dt < since) or (until and dt >= until)):
                    continue
                sid = str(rec.get('sessionId') or os.path.basename(path))[:8]
                for role, text in iter_texts(rec, roles | {'user'} if a.sessions else roles):
                    if a.sessions and role == 'user' and sid not in firsts and text.strip() and not text.startswith('<'):
                        firsts[sid] = text
                    if role not in roles:
                        continue
                    m = pats[0].search(text)
                    if not m or not all(p.search(text) for p in pats[1:]):
                        continue
                    total += 1
                    s = sessions.setdefault(sid, {'n': 0, 'dt': dt})
                    s['n'] += 1
                    if a.sessions:
                        continue
                    if shown < a.max:
                        # 자르기 전에 전문을 가린다 — 창 경계에 걸린 키=값·긴 토큰의 일부가 새지 않게
                        masked = mask(text)
                        mm = pats[0].search(masked) or m
                        lo, hi = max(0, mm.start() - a.context), mm.end() + a.context
                        snip = ' '.join(masked[lo:hi].split())
                        when = dt.strftime('%Y-%m-%d %H:%M') if dt else '????-??-?? ??:??'
                        print('%s | %s | %-9s | %s' % (when, sid, role, snip))
                        shown += 1
    if a.sessions:
        for sid, s in sorted(sessions.items(), key=lambda kv: kv[1]['dt'] or datetime.min.replace(tzinfo=KST)):
            when = s['dt'].strftime('%Y-%m-%d %H:%M') if s['dt'] else '?'
            first = mask(' '.join(firsts.get(sid, '').split()))[:100]
            print('%s | %s | %4d건 | %s' % (when, sid, s['n'], first))
    print('총 %d건 / 세션 %d개 / 스캔 파일 %d개 / 건너뛴 줄 %d (표시 %d)' %
          (total, len(sessions), len(files), skipped, len(sessions) if a.sessions else shown))


if __name__ == '__main__':
    main()
