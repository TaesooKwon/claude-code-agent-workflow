#!/usr/bin/env python3
"""세션 토큰 사용량 집계 — docs/agent_history.md 의 [USAGE] 블록용.

Claude Code 는 세션마다 트랜스크립트를 다음 경로에 JSONL 로 남긴다:
  ~/.claude/projects/<프로젝트슬러그>/<세션ID>.jsonl
각 assistant 턴의 `message.usage` 에 토큰 4종이 들어 있어 이를 합산한다.
서브에이전트(Task) 턴은 `isSidechain: true` 로 구분되므로 메인/서브를 나눠 센다.

사용:
  python3 .claude/scripts/token_usage.py                 # 최신 세션
  python3 .claude/scripts/token_usage.py --session <ID>  # 특정 세션
  python3 .claude/scripts/token_usage.py --since <ISO8601>  # 그 시각 이후 턴만
  python3 .claude/scripts/token_usage.py --md            # 이력에 붙일 마크다운 한 줄

⚠️ 한계(수치를 근거로 쓸 때 함께 밝힐 것):
  - `cache_read_input_tokens` 는 과금 단가가 다르므로 4종을 단순 합산한 "총합"은
    비용이 아니라 **처리량** 지표다. 비용 추정이 목적이면 종류별로 봐야 한다.
    (참고 상대단가 = 입력 1 · 캐시생성 1.25 · 캐시읽기 0.1 · 출력 5)
  - ⚠️**한 API 응답이 content block 수만큼 JSONL 레코드로 쪼개지고 각 레코드가
    같은 `usage` 를 그대로 들고 있다**. 레코드마다 더하면 thinking+tool_use 턴이
    2~3배로 부풀려진다(실측 2026-08-24: 41.5M ← 실제 26.1M, +59%).
    ⇒ `requestId` 로 중복을 제거하고 센다.
  - 트랜스크립트는 세션 단위라, /clear 로 갈린 앞 세션은 별도 파일에 있다.
  - 이 스크립트가 도는 시점까지만 집계된다(집계 이후의 턴은 당연히 빠진다).
"""
import argparse
import glob
import json
import os
import sys

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
SLUG = "{{ENCODED_CWD}}"

FIELDS = (
    "input_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "output_tokens",
)


def transcript_path(session_id=None):
    d = os.path.join(PROJECTS_DIR, SLUG)
    if session_id:
        p = os.path.join(d, session_id + ".jsonl")
        if not os.path.exists(p):
            sys.exit("트랜스크립트 없음: " + p)
        return p
    files = glob.glob(os.path.join(d, "*.jsonl"))
    if not files:
        sys.exit("트랜스크립트 없음: " + d)
    return max(files, key=os.path.getmtime)


def subagent_paths(main_path):
    """서브에이전트(Task) 턴은 메인 JSONL 이 아니라 <세션ID>/subagents/ 아래에 따로 쌓인다.

    ⚠️ 두 층이 있다 — 둘 다 읽어야 한다:
      - `subagents/agent-*.jsonl`                        = Task 로 띄운 서브에이전트
      - `subagents/workflows/wf_*/agent-*.jsonl`         = Workflow 가 띄운 에이전트
    메인 파일만 읽고 `isSidechain` 플래그로 세면 서브가 통째로 0 이 되고(실측 2026-08-24:
    E2E 위임 누락), `subagents/*.jsonl` 만 읽으면 워크플로 몫이 빠진다(실측: 리뷰 워크플로
    11에이전트가 누락돼 서브 합계가 절반 이하로 보였다). 재귀로 훑되 `journal.jsonl` 은
    에이전트 전사가 아니라 워크플로 진행 기록이므로 제외한다.
    """
    root = os.path.join(main_path[: -len(".jsonl")], "subagents")
    found = glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)
    return sorted(p for p in found if os.path.basename(p) != "journal.jsonl")


def scan(path, since=None):
    """한 트랜스크립트 파일의 사용량·턴수·툴콜수·구간을 집계한다.

    ⚠️ `usage` 는 같은 API 응답의 모든 content block 레코드에 복제돼 있으므로
    `requestId`(없으면 `message.id`) 로 1회만 센다. 안 그러면 총합이 부풀려진다.
    단 `output_tokens` 만은 레코드마다 다를 수 있어 그 요청의 최댓값을 채택한다.
    """
    acc = dict.fromkeys(FIELDS, 0)
    turns = 0
    tool_uses = 0
    first_ts = last_ts = None
    counted = {}  # req_id -> 지금까지 센 output_tokens

    with open(path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue

            ts = rec.get("timestamp")
            if since and ts and ts < since:
                continue

            msg = rec.get("message") or {}
            if isinstance(msg.get("content"), list):
                for block in msg["content"]:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_uses += 1

            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue

            req_id = rec.get("requestId") or msg.get("id")
            out = int(usage.get("output_tokens") or 0)
            if req_id is not None:
                if req_id in counted:
                    # 같은 요청의 앞 레코드는 스트리밍 중간값의 output_tokens 를 들고 있을 수 있다 —
                    # 최댓값으로 보정한다(실측 2026-10-09: 첫 레코드만 세서 output 이 75k ← 실제 187k).
                    if out > counted[req_id]:
                        acc["output_tokens"] += out - counted[req_id]
                        counted[req_id] = out
                    continue
                counted[req_id] = out

            for f in FIELDS:
                acc[f] += int(usage.get(f) or 0)
            turns += 1

            if ts:
                first_ts = ts if first_ts is None else min(first_ts, ts)
                last_ts = ts if last_ts is None else max(last_ts, ts)

    return acc, turns, tool_uses, first_ts, last_ts


def collect(path, since=None):
    main, main_turns, main_tools, first_ts, last_ts = scan(path, since)

    side = dict.fromkeys(FIELDS, 0)
    side_turns = 0
    side_tools = 0
    for sub in subagent_paths(path):
        acc, t, tu, f_ts, l_ts = scan(sub, since)
        for f in FIELDS:
            side[f] += acc[f]
        side_turns += t
        side_tools += tu
        if f_ts:
            first_ts = f_ts if first_ts is None else min(first_ts, f_ts)
            last_ts = l_ts if last_ts is None else max(last_ts, l_ts)

    turns = {"main": main_turns, "side": side_turns}
    return main, side, turns, main_tools + side_tools, first_ts, last_ts


def fmt(n):
    return "{:,}".format(n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session")
    ap.add_argument("--since", help="ISO8601 (예: 2026-08-24T07:30:00.000Z) 이후 턴만")
    ap.add_argument("--md", action="store_true", help="이력용 마크다운으로 출력")
    args = ap.parse_args()

    path = transcript_path(args.session)
    m, s, turns, tool_uses, first_ts, last_ts = collect(path, args.since)

    tot = {f: m[f] + s[f] for f in FIELDS}
    grand = sum(tot.values())

    if args.md:
        print(
            "- **토큰 사용량**: 총 {grand} "
            "(입력 {inp} · 캐시생성 {cc} · 캐시읽기 {cr} · 출력 {out}) / "
            "메인 {mt}턴 + 서브에이전트 {st}턴 · 툴콜 {tu}회. "
            "※ 캐시읽기는 단가가 달라 이 합계는 비용이 아니라 처리량 지표다.".format(
                grand=fmt(grand),
                inp=fmt(tot["input_tokens"]),
                cc=fmt(tot["cache_creation_input_tokens"]),
                cr=fmt(tot["cache_read_input_tokens"]),
                out=fmt(tot["output_tokens"]),
                mt=turns["main"],
                st=turns["side"],
                tu=tool_uses,
            )
        )
        return

    print("트랜스크립트: " + path)
    if first_ts:
        print("구간: {} ~ {}".format(first_ts, last_ts))
    print("")
    hdr = "{:<16}{:>14}{:>14}{:>14}".format("항목", "메인", "서브에이전트", "합계")
    print(hdr)
    print("-" * len(hdr))
    label = {
        "input_tokens": "입력",
        "cache_creation_input_tokens": "캐시생성",
        "cache_read_input_tokens": "캐시읽기",
        "output_tokens": "출력",
    }
    for f in FIELDS:
        print("{:<16}{:>14}{:>14}{:>14}".format(label[f], fmt(m[f]), fmt(s[f]), fmt(tot[f])))
    print("-" * len(hdr))
    print("{:<16}{:>14}{:>14}{:>14}".format("총합", fmt(sum(m.values())), fmt(sum(s.values())), fmt(grand)))
    print("")
    print("API 요청(턴): 메인 {} / 서브에이전트 {} · 툴콜 {}회".format(turns["main"], turns["side"], tool_uses))
    print("※ 캐시읽기는 단가가 달라 총합은 비용이 아니라 처리량 지표다.")


if __name__ == "__main__":
    main()
