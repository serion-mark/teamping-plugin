"""User-selected non-Git roots. Hook input cannot widen this private allowlist."""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import stat
import subprocess
import sys
import tempfile

LIMIT = 65536
ABSENT = object()
CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069\ud800-\udfff]')
SYSTEM_TREES = ('/System', '/Library', '/private', '/etc', '/usr', '/bin', '/sbin', '/opt', '/dev', '/cores')
SYSTEM_EXACT = ('/tmp', '/var', '/Applications', '/Volumes', '/Users', '/home', '/mnt', '/media', '/Users/Shared')
SYNC = r'Dropbox( ?\(.+\))?|Box|iCloud ?Drive|Google ?Drive|OneDrive([ -].+)?|Nextcloud|ownCloud|Sync|pCloud( Drive)?|MEGA|Creative Cloud Files|네이버 ?MYBOX'
PERSONAL = re.compile(r'(Desktop|Documents|Downloads|Pictures|Movies|Music|Public|Videos|'+SYNC+r'|문서|바탕 ?화면|다운로드|사진|음악|비디오|공개)', re.I)
SYNC_ROOT = re.compile('('+SYNC+')', re.I)


def disk(path):
    root = Path(path).resolve(strict=True)
    previous = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.chdir(root)
        return Path(os.getcwd())
    finally:
        os.fchdir(previous)
        os.close(previous)


def home_dir():
    override = os.environ.get('TEAMPING_FOLDERS_HOME')
    if override and Path(override).is_absolute():
        try:
            real = disk(override)
            if real != disk(tempfile.gettempdir()) and disk(tempfile.gettempdir()) in real.parents:
                return real
        except (OSError, ValueError, RuntimeError):
            pass
    try:
        return disk(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        raise ValueError('user home unavailable') from None


def git_marker(cwd):
    for ancestor in (cwd, *cwd.parents):
        try:
            (ancestor / '.git').lstat()
        except FileNotFoundError:
            continue
        return True
    return False


def not_a_repo(error):
    return (isinstance(error, subprocess.CalledProcessError)
            and isinstance(error.stderr, bytes) and b'not a git repository' in error.stderr.lower())


def git_decision(marker, state):
    if state == 'repo':
        return 'git'
    return 'registry' if state == 'none' or not marker else 'nothing'


def fallback_folder(cwd, error):
    state = 'none' if not_a_repo(error) else 'missing' if isinstance(error, FileNotFoundError) else 'unknown'
    if git_decision(git_marker(Path(cwd)), state) != 'registry':
        raise ValueError('git context unavailable')
    return selected_folder(cwd)


def git_state(cwd):
    env = {k:v for k,v in os.environ.items() if k not in
           {'GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','GIT_CEILING_DIRECTORIES'}}
    env.update(LC_ALL='C', LANGUAGE='C')
    try:
        value = subprocess.run(['git','-C',str(cwd),'rev-parse','--is-inside-work-tree'],
                               capture_output=True, check=True, timeout=1, env=env)
        return 'repo' if value.stdout.strip() == b'true' else 'none'
    except FileNotFoundError:
        return 'missing'
    except (OSError, subprocess.SubprocessError) as error:
        return 'none' if not_a_repo(error) else 'unknown'


def allowed_root(root, home):
    return forbidden_reason(str(root), str(home), str(disk(tempfile.gettempdir()))) is None and not os.path.ismount(root)


def forbidden_reason(path, home, tmp=None):
    if not isinstance(path, str) or not path.startswith('/'):
        return 'not-absolute'
    if CONTROL.search(path):
        return 'bad-name'
    if path == '/':
        return 'root'
    if home and path == home:
        return 'home'
    if home and home.startswith(path+'/'):
        return 'above-home'
    if home and path.startswith(home+'/'):
        parts = path[len(home)+1:].split('/')
        if parts[0].startswith('.') or parts[0] == 'Library':
            return 'private-data'
        if len(parts) == 1 and PERSONAL.fullmatch(parts[0]):
            return 'personal'
        if len(parts) == 2 and SYNC_ROOT.fullmatch(parts[0]) and PERSONAL.fullmatch(parts[1]):
            return 'personal'
        return None
    if re.fullmatch(r'/(Volumes|mnt)/[^/]+', path) or re.fullmatch(r'/media/[^/]+(/[^/]+)?', path):
        return 'mount-root'
    if path in SYSTEM_EXACT:
        return 'system'
    if tmp and (path == tmp or path.startswith(tmp+'/')):
        return 'system' if path == tmp else None
    if any(path == p or path.startswith(p+'/') for p in SYSTEM_TREES):
        return 'system'
    return None


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate field')
        result[key] = value
    return result


def validate(value, home=None):
    if (not isinstance(value, dict) or set(value) != {'v', 'folders'}
            or type(value['v']) not in (int,float) or value['v'] != 1 or not isinstance(value['folders'], list)
            or len(value['folders']) > 50):
        raise ValueError('invalid registry')
    ids, paths = set(), set()
    for row in value['folders']:
        if not isinstance(row, dict) or set(row) != {'id', 'path', 'label', 'added'}:
            raise ValueError('invalid folder')
        if not isinstance(row['id'], str) or not re.fullmatch(r'[0-9a-f]{32}', row['id']):
            raise ValueError('invalid folder id')
        path = row['path']
        if (not isinstance(path, str) or not path.startswith('/') or CONTROL.search(path)
                or not 1 <= len(path.encode('utf-8')) <= 1024
                or (len(path)>1 and path.endswith('/')) or any(p in ('.','..') for p in path.split('/'))
                or not isinstance(row['label'], str)
                or not 1 <= len(row['label']) <= 40 or CONTROL.search(row['label'])
                or not isinstance(row['added'], str)
                or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', row['added'], flags=re.ASCII)):
            raise ValueError('invalid folder fields')
        if row['id'] in ids or path in paths:
            raise ValueError('duplicate folder')
        ids.add(row['id'])
        paths.add(path)
    return value['folders']


def parse_registry(text):
    try:
        if not isinstance(text, str) or len(text.encode('utf-8')) > LIMIT:
            return None
        value = json.loads(text, object_pairs_hook=unique_object)
        validate(value)
        return value
    except (ValueError, UnicodeError):
        return None


def find_root(cwd, rows):
    matches = [row for row in rows if cwd == row['path'] or cwd.startswith(row['path'].rstrip('/')+'/')]
    return max(matches, key=lambda r:len(r['path'])) if matches else None


def repo_key_of_id(identity):
    return 'dir:'+identity[:16]



class NotListed(ValueError):
    """빼려는 폴더가 목록에 없거나 이름표가 여럿 — 조용히 성공하지 않는다."""


class InsideRegistered(ValueError):
    """등록 폴더의 하위만 따로 빼려 함."""


class Registry:
    def __init__(self):
        self.home = home_dir()

    @contextlib.contextmanager
    def directory(self, create=False):
        fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in ('.config', 'teamping'):
                if create:
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                info = os.fstat(fd)
                if create and part == 'teamping' and info.st_uid == os.getuid():
                    os.fchmod(fd, 0o700)
                    info = os.fstat(fd)
                if (info.st_uid != os.getuid() or
                        (stat.S_IMODE(info.st_mode) != 0o700 if part == 'teamping' else info.st_mode & 0o022)):
                    raise ValueError('unsafe registry directory')
            yield fd
        finally:
            os.close(fd)

    @staticmethod
    def checked(fd):
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError('unsafe registry file')

    def value_at(self, dfd, limit=LIMIT):
        try:
            fd = os.open('folders.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        except FileNotFoundError:
            return ABSENT, b''
        with os.fdopen(fd, 'rb') as stream:
            self.checked(stream.fileno())
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('registry too large')
        return json.loads(data.decode('utf-8', 'strict'), object_pairs_hook=unique_object), data

    def read_at(self, dfd):
        value, _ = self.value_at(dfd)
        return [] if value is ABSENT else validate(value, self.home)

    def verify_directory(self, dfd):
        # Re-open the visible private directory after a human confirmation.
        with self.directory() as current:
            before, after = os.fstat(dfd), os.fstat(current)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise ValueError('registry directory changed')

    def write_at(self, dfd, rows):
        self.verify_directory(dfd)
        body = json.dumps({'v': 1, 'folders': rows}, ensure_ascii=False).encode('utf-8')
        validate(json.loads(body), self.home)
        if len(body) > LIMIT:
            raise ValueError('registry too large')
        temp = 'folders.'+secrets.token_hex(8)+'.tmp'
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(out, 'wb') as stream:
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            self.verify_directory(dfd)
            os.replace(temp, 'folders.json', src_dir_fd=dfd, dst_dir_fd=dfd)
        finally:
            try:
                os.unlink(temp, dir_fd=dfd)
            except FileNotFoundError:
                pass

    def read(self):
        try:
            with self.directory() as dfd:
                return self.read_at(dfd)
        except (OSError, ValueError, RuntimeError):
            return []

    def update(self, action, path, label=None):
        root = None
        if action == 'add':
            root = disk(path)
            if not allowed_root(root, self.home):
                raise ValueError('unsafe project root')
            state = git_state(root)
            if state == 'repo' or git_decision(git_marker(root),state) != 'registry':
                raise ValueError('folder already uses Git or its Git context is unavailable')
        with self.directory(create=True) as dfd:
            fd = os.open('folders.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=dfd)
            try:
                self.checked(fd)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rows = self.read_at(dfd)
                if action == 'remove':
                    # 빼기는 목록에서 지우기만 한다 — 디스크를 읽지 않으니 금지 폴더 검사가 지킬 것이 없고,
                    # 등록 뒤 금지가 된 폴더(마운트 등)도 뺄 수 있어야 한다. 못 찾으면 조용히 성공하지 않는다.
                    named = [r for r in rows if r['label'] == str(path)] if not Path(path).exists() else []
                    if len(named) > 1:
                        raise NotListed('ambiguous label')
                    root = Path(named[0]['path']) if named else Path(path).resolve()
                existing = next((r for r in rows if r['path'] == str(root)), None)
                if action == 'add' and existing is None:
                    rows.append({'id': secrets.token_hex(16), 'path': str(root),
                                 'label': root.name if label is None else label,
                                 'added': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')})
                elif action == 'remove':
                    if existing is None and find_root(str(root), rows):
                        raise InsideRegistered(find_root(str(root), rows)['label'])
                    if existing is None:
                        raise NotListed('folder not listed')
                    rows = [r for r in rows if r['path'] != str(root)]
                self.write_at(dfd, rows)
                return rows
            finally:
                os.close(fd)

    def repair_plan(self, value):
        valid, bad, reasons, paths, ids = [], set(), {}, set(), set()
        for index, row in enumerate(value['folders']):
            reason = 'shape'
            try:
                validate({'v': 1, 'folders': [row]}, self.home)
                if not allowed_root(Path(row['path']), self.home):
                    reason = 'forbidden'
                    raise ValueError('forbidden root')
                reason = 'missing'
                info = Path(row['path']).lstat()
                if stat.S_ISLNK(info.st_mode):
                    reason = 'link'
                    raise ValueError('linked project directory')
                if not stat.S_ISDIR(info.st_mode):
                    raise ValueError('missing project directory')
                if disk(row['path']) != Path(row['path']):
                    reason = 'link'
                    raise ValueError('changed project spelling')
                if row['path'] in paths or row['id'] in ids:
                    reason = 'duplicate'
                    raise ValueError('duplicate or too many entries')
                if len(valid) >= 50:
                    reason = 'limit'
                    raise ValueError('too many entries')
                paths.add(row['path']);ids.add(row['id'])
                valid.append((index, row))
            except (OSError, ValueError, RuntimeError):
                bad.add(index)
                reasons[index] = reason
        return valid, bad, reasons

    def repair(self):
        # Recovery is a deliberate terminal action, never a hook side effect.
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            print('복구는 터미널에서 직접 확인해 주세요. / Repair needs confirmation in a terminal.')
            return None
        with self.directory() as dfd:
            value, original = self.value_at(dfd, 1048576)  # Verify owner/mode/link count before even a lock.
            if value is ABSENT:
                return []
            if (not isinstance(value, dict) or set(value) != {'v', 'folders'}
                    or type(value['v']) not in (int,float) or value['v'] != 1
                    or not isinstance(value['folders'], list)):
                raise ValueError('invalid top-level registry')
            fd = os.open('folders.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=dfd)
            try:
                self.checked(fd)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if self.value_at(dfd, 1048576)[1] != original:
                    raise ValueError('registry changed')
                valid, bad, reasons = self.repair_plan(value)
                if not bad:
                    if len(original) > LIMIT:
                        raise ValueError('oversized registry needs recreation')
                    return value['folders']
                preview = []
                for index in sorted(bad):
                    row = value['folders'][index]
                    item = {'index': index + 1, 'reason': reasons[index]}
                    if isinstance(row, dict):
                        for field, limit in [('path', 1024), ('label', 40)]:
                            if isinstance(row.get(field), str):
                                item[field] = row[field][:limit]
                    preview.append(item)
                # JSON escaping prevents terminal control characters from executing.
                print(json.dumps({'remove': preview, 'keep_count': len(value['folders'])-len(bad)}, ensure_ascii=True))
                try:
                    answer = input('이 항목만 제거할까요? / Remove only these entries? [y/N]: ')
                except (EOFError, KeyboardInterrupt):
                    return None
                if answer.strip().lower() != 'y':
                    return None
                if self.value_at(dfd, 1048576)[1] != original:
                    print('목록이 바뀌어 취소했습니다. 다시 확인하세요. / List changed; cancelled. Review again.')
                    return None
                self.verify_directory(dfd)
                if self.repair_plan(value)[1] != bad:
                    print('폴더 상태가 바뀌어 취소했습니다. / Folder state changed; cancelled.')
                    return None
                rows = [row for index, row in valid if index not in bad]
                for row in rows:
                    if not stat.S_ISDIR(Path(row['path']).lstat().st_mode):
                        raise ValueError('project changed during confirmation')
                self.write_at(dfd, rows)
                return rows
            finally:
                os.close(fd)


def selected_folder(cwd):
    physical = disk(cwd)
    registry = Registry()
    rows = [r for r in registry.read() if allowed_root(Path(r['path']),registry.home)]
    row = find_root(str(physical), rows)
    if row is None:
        raise ValueError('folder not registered')
    root = Path(row['path'])
    if disk(root) != root:
        raise ValueError('changed registered root')
    return root, repo_key_of_id(row['id'])


def plain_folder(cwd):
    return selected_folder(cwd)[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description='팀핑 기록 폴더 / Teamping recording folders')
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ('add', 'remove'):
        sub = commands.add_parser(name)
        sub.add_argument('path', nargs='?', default='.')
        if name == 'add':
            sub.add_argument('--label')
    commands.add_parser('list')
    commands.add_parser('repair')
    args = parser.parse_args(argv)
    registry = None
    try:
        registry = Registry()
        if args.action == 'repair':
            rows = registry.repair()
            if rows is None:
                return 1
        else:
            rows = registry.read() if args.action == 'list' else registry.update(args.action, args.path, getattr(args, 'label', None))
        print(json.dumps({'v': 1, 'folders': rows}, ensure_ascii=True))
        return 0
    except NotListed as error:
        if str(error) == 'ambiguous label':
            print('팀핑: 같은 이름표의 폴더가 여럿이라 고르지 않았습니다. 폴더 경로로 알려 주세요. / Teamping: several folders share that label; give the folder path.')
        else:
            print('팀핑: 이 폴더는 기록 목록에 없어요. 이름표로 쳤다면 폴더 경로로, 경로로 쳤다면 이름표로 다시 알려 주세요(list 로 목록을 볼 수 있어요). / '
                  'Teamping: this folder is not on the record list. If you typed a label, give the folder path; if a path, give the label (see list).')
        return 1
    except InsideRegistered as error:
        print('팀핑: 이 폴더는 등록된 폴더 안에 있어 따로 뺄 수 없어요. 그 폴더 전체를 빼려면 그 폴더로 remove 하세요. / '
              'Teamping: this folder is inside a registered folder and cannot be removed on its own; remove that folder instead.')
        return 1
    except (OSError, ValueError, RuntimeError):
        if registry is not None:
            try:
                with registry.directory():
                    pass
            except (OSError, ValueError, RuntimeError):
                print('목록 자리 ~/.config 또는 ~/.config/teamping의 소유자·권한·링크를 확인하세요. / Check owner, permissions and links at ~/.config or ~/.config/teamping.')
                return 2
        if args.action == 'repair':
            print('복구하지 않았습니다. 파일 권한·소유자·형식을 확인하고, 복구할 수 없으면 목록 파일을 지운 뒤 다시 등록하세요. / No repair made. Check permissions, owner and format; recreate the list if it cannot be repaired.')
        else:
            print('팀핑: 폴더 등록을 처리하지 못했습니다. / Teamping: could not update folder registration.')
        return 2
