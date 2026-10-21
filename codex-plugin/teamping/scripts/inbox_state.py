"""Bounded, private per-connection inbox receipts. Never store message bodies."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import unicodedata

TEMPLATES = json.loads(Path(__file__).with_name('inbox-templates.json').read_text())
UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z', re.I)
FALLBACK = {
    'ko': '📨 팀핑 — 이 세션에 연락이 하나 왔지만 이 플러그인 판이 그 문장을 알아보지 못했습니다. get_my_work 나 list_channel_messages 로 확인하세요.',
    'en': "📨 Teamping — something arrived for this session, but this plugin version couldn't read the notice. Check with get_my_work or list_channel_messages.",
}
KEYS = ('inbox_reply_channel', 'inbox_reply_thread', 'inbox_card_response',
        'inbox_card_confirmed', 'inbox_card_unconfirmed', 'inbox_assign_request', 'inbox_direct')
ID_PAT = r'(?:[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}|\?)'


def patterns():
    items, more = [], []
    for lang, ts in TEMPLATES.items():
        for key in (*KEYS, 'inbox_receipt', 'inbox_more'):
            text = ts[key] + (ts['inbox_tail'] if key in KEYS else '')
            pat = re.escape(text).replace(re.escape('{who}'), r'(?P<who>.+?)')
            pat = pat.replace(re.escape('{ref}'), ID_PAT).replace(re.escape('{thread}'), ID_PAT)
            pat = pat.replace(re.escape('{n}'), '[0-9]{1,6}')
            (more if key == 'inbox_more' else items).append((lang, re.compile(pat + r'\Z')))
    return items, more


ITEM_PATTERNS, MORE_PATTERNS = patterns()


def safe_name(name, lang):
    if name in (TEMPLATES[lang]['lock_someone'], TEMPLATES[lang]['deleted_user']):
        return True
    if not name.startswith('「') or not name.endswith('」') or not 1 <= len(name[1:-1]) <= 24:
        return False
    return all(c in " .-_'" or unicodedata.category(c)[0] in 'LNM' for c in name[1:-1])


def valid_line(text, more=False):
    if not isinstance(text, str) or not text or len(text) > 2000:
        return False
    for lang, pat in MORE_PATTERNS if more else ITEM_PATTERNS:
        match = pat.fullmatch(text)
        if match and ('who' not in match.groupdict() or safe_name(match['who'], lang)):
            return True
    return False


def fixed_line(text, lang):
    # Strict matching: never remove delimiters/control characters to make an
    # untrusted sentence look valid. Unknown/empty lines become a fixed notice.
    return text if valid_line(text) else FALLBACK[lang] + TEMPLATES[lang]['inbox_tail']


class State:
    def __init__(self, root, base, token, session):
        home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
        self.directory = home / 'teamping-inbox'
        # Raw credentials are never persisted. Rotation/server/repo/session
        # changes must not reuse another recipient's acknowledgements.
        digest = hashlib.sha256(json.dumps([str(root), base, token, session]).encode()).hexdigest()
        self.key = digest

    @contextlib.contextmanager
    def locked(self):
        try:
            self.directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('unsafe state directory')
        dfd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(dfd)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError('unsafe opened state directory')
            fd = os.open(self.key + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            try:
                self.check_file(fd)
                # No stale lock recovery or deletion: flock releases on process
                # death, and a second process skips the notice instead of blocking a tool.
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                yield dfd
            finally:
                os.close(fd)
        finally:
            os.close(dfd)

    @staticmethod
    def check_file(fd):
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600:
            raise ValueError('unsafe state file')

    def read(self, dfd):
        try:
            fd = os.open(self.key + '.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        except FileNotFoundError:
            return {'seen': {}, 'ack': []}
        with os.fdopen(fd, 'r') as stream:
            self.check_file(stream.fileno())
            raw = stream.read(131073)
            if len(raw) > 131072:
                raise ValueError('state limit')
            data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError('bad state')
        seen = data.get('seen', {})
        ack = data.get('ack', [])
        if not isinstance(seen, dict) or not isinstance(ack, list):
            raise ValueError('bad state')
        now = time.time()
        return {
            'seen': {k.lower(): v for k, v in seen.items() if UUID.fullmatch(k) and type(v) in (int, float) and 0 <= now - v < 8 * 86400},
            'ack': list(dict.fromkeys(x.lower() for x in ack if isinstance(x, str) and UUID.fullmatch(x)))[:32],
        }

    def write(self, dfd, data):
        data['seen'] = dict(sorted(data['seen'].items(), key=lambda x: x[1], reverse=True)[:500])
        data['ack'] = list(dict.fromkeys(data['ack']))[:32]
        # A random, exclusive file, then atomic rename inside the checked dir.
        name = self.key + '.' + os.urandom(8).hex() + '.tmp'
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(data, out, ensure_ascii=False)
            os.replace(name, self.key + '.json', src_dir_fd=dfd, dst_dir_fd=dfd)
        finally:
            try:
                os.unlink(name, dir_fd=dfd)
            except FileNotFoundError:
                pass

    def acks(self):
        try:
            (self.directory / (self.key + '.json')).lstat()
        except FileNotFoundError:
            return []  # A silent session must not create receipt files.
        with self.locked() as dfd:
            return self.read(dfd)['ack']

    def receive(self, sent, response, field, lang, show=True, emit=None):
        # A missing/malformed/error response cannot confirm receipt of our ack.
        if not isinstance(response, dict) or response.get('ok') is not True:
            return []
        items = response.get(field, [])
        if not isinstance(items, list):
            return []
        if not items and not sent:
            return []
        with self.locked() as dfd:
            st = self.read(dfd)
            st['ack'] = [x for x in st['ack'] if x not in sent]
            lines, more = [], None
            now = time.time()
            for item in items[:20]:
                if not isinstance(item, dict):
                    continue
                key = item.get('id')
                text = item.get('line')
                if key == 'more':
                    if valid_line(text, more=True):
                        more = text
                    continue
                if not isinstance(key, str) or not UUID.fullmatch(key):
                    continue
                key = key.lower()
                if key in st['seen']:
                    if key not in st['ack']:
                        st['ack'].append(key)
                    continue
                if not show or len(lines) >= 5 or len(st['ack']) >= 32:
                    continue  # Not displayed: leave on server; never acknowledge.
                lines.append(fixed_line(text, lang))
                st['seen'][key] = now
                st['ack'].append(key)
            lines = list(dict.fromkeys(lines)) + ([more] if lines and more else [])
            # Keep the process lock through emission: another hook must not
            # display the same row concurrently. Never persist 'delivered' if
            # serialization/stdout/flush fails or the deadline fires first.
            if lines and emit is not None:
                emit(lines)
            self.write(dfd, st)
            return lines


def context(event, lines):
    if not lines:
        return None
    text = '\n'.join(lines)
    if event == 'Stop':
        return {'decision': 'block', 'reason': text}
    return {'hookSpecificOutput': {'hookEventName': event, 'additionalContext': text}}


def emit_context(event, lines):
    print(json.dumps(context(event, lines), ensure_ascii=False), flush=True)


def posted_id(tool, response, server):
    if tool not in {f'mcp__{server}__post_channel_message', f'mcp__{server}__post_thread_message'}:
        return None
    if isinstance(response, str):
        if len(response) > 1048576:
            return None
        try:
            response = json.loads(response)
        except ValueError:
            response = {'content': [{'type': 'text', 'text': response}]}
    if not isinstance(response, dict) or response.get('isError'):
        return None
    blocks = response.get('content', [])
    if not isinstance(blocks, list):
        return None
    for block in blocks[:5]:
        if not isinstance(block, dict) or block.get('type') != 'text':
            continue
        text = block.get('text')
        if not isinstance(text, str):
            continue
        tail = r'(?: → thread ([0-9a-fA-F-]{36}))?' if tool.endswith('__post_thread_message') else ''
        match = re.match(r'^✅ [^\n]{1,100} \(id ([0-9a-fA-F-]{36})\)' + tail + r'(?:\n|$)', text)
        if match and match.lastindex == 2 and match[2] and not UUID.fullmatch(match[2]):
            continue
        if match and UUID.fullmatch(match[1]):
            return match[1]
    return None
