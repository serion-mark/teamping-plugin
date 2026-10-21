#!/usr/bin/env python3
"""Synchronous input/Stop inbox. No detached processes and no idle wake claim."""
import json
import os
from pathlib import Path
import re
import signal
import sys
import lock as adapter


def handle(event):
    level = os.environ.get('TEAMPING_LEVEL', 'lv2' if os.environ.get('PLUGIN_ROOT') else 'lv1')
    if level not in {'lv2', 'lv3'} or adapter.tomllib is None or not isinstance(event, dict):
        return None
    kind = event.get('hook_event_name')
    if kind not in {'Stop', 'UserPromptSubmit'} or event.get('agent_id'):
        return None
    session = event.get('session_id')
    cwd = event.get('cwd')
    if not isinstance(session, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', session) or not isinstance(cwd, str):
        return None
    cwd = Path(cwd)
    if not cwd.is_absolute():
        return None
    physical = cwd.resolve(strict=True)
    root, repo_key = adapter.repo(physical)
    creds = adapter.connection(root, physical, cwd)
    if creds is None:
        return None
    base, token, _ = creds
    # Import inside main's error and time-limit guard: templates can be
    # missing or damaged in an incomplete plugin installation.
    from inbox_state import State, emit_context
    state = State(root, base, token, session)
    lang = 'en' if os.environ.get('TEAMPING_LANG') == 'en' else 'ko'
    # Stop already continued once: flush receipts but never hold/restart again.
    show = not (kind == 'Stop' and event.get('stop_hook_active') is True)
    # Never long-poll at turn end. Ignore the retired WAIT_S setting, even if
    # malformed: one non-waiting lookup must not delay every completed turn.
    acks = state.acks()
    body = {'session_id': session, 'agent': 'codex', 'repo_key': repo_key,
            'inbox_ack': acks, 'wait_s': 0}
    if isinstance(event.get('session_title'), str):
        body['session_title'] = event['session_title'][:200]
    response = adapter.post(base, token, 'inbox', body, lang, timeout=1.1, success_only=True)
    state.receive(acks, response, 'items', lang, show=show, emit=lambda lines: emit_context(kind, lines))
    return None


def main():
    signal.signal(signal.SIGALRM, adapter.timeout)
    signal.setitimer(signal.ITIMER_REAL, 1.7)
    try:
        if len(sys.argv) != 1:
            return
        raw = sys.stdin.buffer.read(adapter.LIMIT + 1)
        if len(raw) > adapter.LIMIT:
            return
        event = json.loads(raw)
        result = adapter.with_notice(event, handle(event))
        if result:
            print(json.dumps(result, ensure_ascii=False))
    except (Exception, adapter.Deadline):
        pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    try:
        main()
    except BaseException:
        pass
