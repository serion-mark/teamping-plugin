"""Private, one-use pre/post metadata for native apply_patch; never read file bodies."""
import contextlib
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import stat
import time

LIMIT = 524288
MAX_AGE = 600
MAX_FILES = 256
NAME = re.compile(r'[0-9a-f]{64}(?:\.[0-9a-f]{16})?\.(?:json|tmp|take)\Z')


def candidate_path(root, relative):
    if (not isinstance(relative, str) or not relative or '\\' in relative
            or any(ord(c) < 32 for c in relative) or len(relative.encode('utf-16-le')) > 1024):
        raise ValueError('invalid relative path')
    parts = relative.split('/')
    if any(p in ('', '.', '..') for p in parts) or re.match(r'^[A-Za-z]:', relative):
        raise ValueError('invalid relative path')
    path = root / relative
    # Re-check parents at both ends: a symlink may have changed since pretool.
    # lstat the leaf, so deleting a link never follows its outside target.
    parent = path.parent.resolve().relative_to(root)
    return path, parent


def stamp(root, relative, root_fd=None):
    path, parent = candidate_path(root, relative)
    fd = (os.dup(root_fd) if root_fd is not None else
          os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    try:
        for part in parent.parts:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        value = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    finally:
        os.close(fd)
    if not (stat.S_ISREG(value.st_mode) or stat.S_ISLNK(value.st_mode)):
        raise ValueError('not a file')
    return [value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns]


def root_id(info):
    return [info.st_dev, info.st_ino]


class EditState:
    def __init__(self, root, base, token, repo_key, event):
        call = event.get('tool_use_id')
        if not isinstance(call, str) or not 1 <= len(call) <= 256:
            raise ValueError('no tool call id')
        self.root = root
        self.matched = False
        self.unpaired = []
        self.directory = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'teamping-edit-state'
        # Bind to this connection, folder, session, subagent, and exact invocation.
        identity = [str(root), base, str(token), repo_key, event.get('session_id'), event.get('agent_id'), call]
        self.key = hashlib.sha256(json.dumps(identity).encode()).hexdigest()

    @contextlib.contextmanager
    def opened(self, create=False):
        if create:
            try:
                self.directory.mkdir(mode=0o700)
            except FileExistsError:
                pass
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('unsafe state directory')
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError('unsafe opened directory')
            if create:
                # Brief bounded contention is normal across parallel tool calls.
                # The outer hook's 1.7s deadline still takes precedence.
                until = time.monotonic() + .15
                while True:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= until:
                            raise
                        time.sleep(.002)
            yield fd
        finally:
            os.close(fd)

    @staticmethod
    def checked(fd):
        value = os.fstat(fd)
        if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid()
                or value.st_nlink != 1 or stat.S_IMODE(value.st_mode) != 0o600):
            raise ValueError('unsafe state file')

    def capture(self, paths):
        before = {}
        root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            identity = root_id(os.fstat(root_fd))
            for relative in paths[:200]:
                try:
                    before[relative] = stamp(self.root, relative, root_fd)
                except (OSError, ValueError, RuntimeError):
                    continue
            if root_id(self.root.lstat()) != identity:
                return
        finally:
            os.close(root_fd)
        if not before:
            return
        body = json.dumps({'at': time.time(), 'root': identity, 'paths': before}).encode()
        if len(body) > LIMIT:
            return
        with self.opened(create=True) as dfd:
            # Aborted/denied-by-another-hook invocations expire; never recurse.
            with os.scandir(dfd) as entries:
                names = [e.name for e in itertools.islice(entries, MAX_FILES + 1)]
            for name in names:
                if NAME.fullmatch(name):
                    try:
                        info = os.stat(name, dir_fd=dfd, follow_symlinks=False)
                        if time.time() - info.st_mtime > MAX_AGE:
                            os.unlink(name, dir_fd=dfd)
                    except FileNotFoundError:
                        # A concurrent Post may have consumed this snapshot.
                        pass
            try:
                os.stat(self.key + '.json', dir_fd=dfd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                # A replayed Pre must preserve the first before-image.
                return
            with os.scandir(dfd) as entries:
                if len(list(itertools.islice(entries, MAX_FILES + 1))) >= MAX_FILES:
                    return
            temp = self.key + '.' + os.urandom(8).hex() + '.tmp'
            fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(body)
                os.replace(temp, self.key + '.json', src_dir_fd=dfd, dst_dir_fd=dfd)
            finally:
                try:
                    os.unlink(temp, dir_fd=dfd)
                except FileNotFoundError:
                    pass

    def changed(self, paths):
        self.matched = False
        self.unpaired = []
        try:
            with self.opened() as dfd:
                taken = self.key + '.' + os.urandom(8).hex() + '.take'
                # Atomic claim: duplicate PostToolUse calls cannot replay a snapshot.
                os.rename(self.key + '.json', taken, src_dir_fd=dfd, dst_dir_fd=dfd)
                try:
                    fd = os.open(taken, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
                    with os.fdopen(fd, 'rb') as stream:
                        self.checked(stream.fileno())
                        raw = stream.read(LIMIT + 1)
                    if len(raw) > LIMIT:
                        return []
                    body = json.loads(raw)
                finally:
                    os.unlink(taken, dir_fd=dfd)
        except FileNotFoundError:
            return []
        if not isinstance(body, dict) or type(body.get('at')) not in (int, float):
            return []
        if not 0 <= time.time() - body['at'] < MAX_AGE or not isinstance(body.get('paths'), dict):
            return []
        self.matched = True
        changed = []
        try:
            root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError:
            return []  # A vanished/unreadable root is a boundary failure, not missing metadata.
        try:
            identity = root_id(os.fstat(root_fd))
            if body.get('root') != identity:
                return []
            for relative in paths[:200]:
                try:
                    candidate_path(self.root, relative)
                except (OSError, ValueError, RuntimeError):
                    continue
                if relative not in body['paths']:
                    self.unpaired.append(relative)
                    continue
                before = body['paths'][relative]
                if before is not None and (not isinstance(before, list) or len(before) != 6 or any(type(x) is not int for x in before)):
                    self.unpaired.append(relative)
                    continue
                try:
                    after = stamp(self.root, relative, root_fd)
                except (OSError, ValueError, RuntimeError):
                    # Read/stat failure may still leave a validated tool path.
                    # Recheck the parent boundary before retaining that candidate.
                    try:
                        candidate_path(self.root, relative)
                        self.unpaired.append(relative)
                    except (OSError, ValueError, RuntimeError):
                        pass
                    continue
                if before != after:
                    changed.append(relative)
            try:
                current = root_id(self.root.lstat())
            except OSError:
                current = None
            if current != identity:
                self.unpaired = []
                return []
        finally:
            os.close(root_fd)
        return changed
