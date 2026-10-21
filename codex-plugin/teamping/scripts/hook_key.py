"""Hook-key contract v1: local identity and private storage; no network or logging."""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import pwd
import re
import secrets
import stat
import subprocess

FILE_KEYS = ('v', 'server', 'key', 'key_id', 'org', 'channel', 'repo')
FIELDS = {
    'v': r'1', 'server': r'https://[a-z0-9-]+(?:\.[a-z0-9-]+)*(?::[1-9][0-9]{0,4})?',
    'key': r'teamping_[0-9a-f]{64}', 'key_id': r'tok_[0-9a-f-]{36}',
    'org': r'[A-Za-z0-9_-]{1,64}', 'channel': r'[A-Za-z0-9_-]{1,64}', 'repo': r'[0-9a-f]{16}',
}
CONFIG_URL = re.compile(r'https://([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)(?::([0-9]{1,5}))?/mcp/?')
SERVER_URL = re.compile(r'https://([a-z0-9-]+(?:\.[a-z0-9-]+)*)(?::([1-9][0-9]{0,4}))?')
GIT_ENV = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_CEILING_DIRECTORIES')


def sha(value):
    return hashlib.sha256(value.encode('utf-8', 'strict')).hexdigest()


def repo_key_of(disk):
    return sha('teamping-hook-repo:v1:' + disk)[:16]


def kit_device_of(user, uid, raw):
    return sha('teamping-kit-device:v1:' + user + ':' + str(uid) + ':' + raw)


def hook_device_value(device, repo):
    return sha('teamping-hook-device:v1:' + device + ':' + repo)


def port_ok(value):
    return value is None or 1 <= int(value) <= 65535


def valid_origin(value):
    if not isinstance(value, str):
        return False
    m = SERVER_URL.fullmatch(value)
    return bool(m and port_ok(m[2]))


def same_hook_server(config, server):
    if not isinstance(config, str) or not isinstance(server, str):
        return False
    a, b = CONFIG_URL.fullmatch(config), SERVER_URL.fullmatch(server)
    return bool(a and b and port_ok(a[2]) and port_ok(b[2]) and
                a[1].lower() == b[1] and int(a[2] or '443') == int(b[2] or '443'))


def parse_hook_key_file(data):
    if not isinstance(data, bytes) or len(data) > 4096 or not data.endswith(b'\n'):
        return None
    try:
        text = data.decode('utf-8', 'strict')
    except UnicodeError:
        return None
    if re.fullmatch(r'[\x21-\x7e\n]*', text) is None:
        return None
    fields = {}
    for line in text[:-1].split('\n'):
        m = re.fullmatch(r'([a-z_]+)=([\x21-\x3c\x3e-\x7e]{1,512})', line)
        if not m:
            return None
        key, value = m.groups()
        if key not in FIELDS or key in fields or not re.fullmatch(FIELDS[key], value):
            return None
        if key == 'server' and not valid_origin(value):
            return None
        fields[key] = value
    return fields if set(fields) == set(FILE_KEYS) else None


def format_hook_key_file(fields):
    data = ''.join(k + '=' + fields[k] + '\n' for k in FILE_KEYS).encode('utf-8', 'strict')
    if parse_hook_key_file(data) != fields:
        raise ValueError('invalid key fields')
    return data


def repo_identity(cwd):
    """Keep exact disk bytes, including final spaces; never use the legacy git helper."""
    env = {k: v for k, v in os.environ.items() if k not in GIT_ENV}
    env.update(LC_ALL='C', LANGUAGE='C')
    r = subprocess.run(['git', '-C', str(cwd), 'rev-parse', '--git-common-dir'],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       timeout=1, check=True, env=env)
    raw = r.stdout[:-1] if r.stdout.endswith(b'\n') else r.stdout
    common = Path(raw.decode('utf-8', 'strict'))
    if not common.is_absolute():
        common = Path(cwd) / common
    old = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.chdir(common)
        disk = os.getcwd()
    finally:
        os.fchdir(old)
        os.close(old)
    return repo_key_of(disk)


def raw_device(dev):
    if dev == 'mac':
        r = subprocess.run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=3, check=True)
        m = re.search(r'"IOPlatformUUID" = "([0-9A-F-]{36})"', r.stdout.decode('utf-8', 'strict'))
        value = m[1] if m else ''
        return value if re.fullmatch(r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}', value) else None
    for path in ('/etc/machine-id', '/var/lib/dbus/machine-id'):
        try:
            with open(path, 'rb') as stream:
                value = stream.read(256).decode('ascii').strip()
        except (OSError, UnicodeError):
            continue
        return value if re.fullmatch(r'[0-9a-f]{32}', value) else None
    return None


class Locked(Exception):
    pass


class KeyStore:
    def __init__(self, repo):
        if not re.fullmatch(FIELDS['repo'], repo):
            raise ValueError('invalid repo key')
        self.repo = repo
        self.home = Path(pwd.getpwuid(os.getuid()).pw_dir)

    @contextlib.contextmanager
    def directory(self, write=False):
        fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in ('.config', 'teamping', 'hookkey'):
                if write:
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                st = os.fstat(fd)
                if st.st_uid != os.getuid():
                    raise ValueError('foreign directory')
                if write and part == 'hookkey':
                    os.fchmod(fd, 0o700)
                mode = stat.S_IMODE(os.fstat(fd).st_mode)
                if (part == 'hookkey' and mode != 0o700) or (part != 'hookkey' and mode & 0o022):
                    raise ValueError('unsafe directory')
            yield fd
        finally:
            os.close(fd)

    @staticmethod
    def check_file(fd):
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or st.st_nlink != 1:
            raise ValueError('unsafe file')

    def read_at(self, dfd):
        fd = os.open(self.repo, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        try:
            self.check_file(fd)
            data = b''
            while len(data) < 4097:
                part = os.read(fd, 4097-len(data))
                if not part:
                    break
                data += part
        finally:
            os.close(fd)
        return parse_hook_key_file(data)

    def read(self):
        with self.directory() as dfd:
            return self.read_at(dfd)

    @contextlib.contextmanager
    def locked(self):
        old_umask = os.umask(0o077)
        try:
            with self._locked() as dfd:
                yield dfd
        finally:
            os.umask(old_umask)

    @contextlib.contextmanager
    def _locked(self):
        with self.directory(write=True) as dfd:
            fd = os.open(self.repo + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=dfd)
            try:
                self.check_file(fd)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise Locked() from None
                yield dfd
            finally:
                os.close(fd)

    def write_at(self, dfd, fields):
        data = format_hook_key_file(fields)
        if fields['repo'] != self.repo:
            raise ValueError('repo mismatch')
        name = '.' + self.repo + '.' + secrets.token_hex(12)
        try:
            fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
            with os.fdopen(fd, 'wb') as f:
                os.fchmod(f.fileno(), 0o600)
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(name, self.repo, src_dir_fd=dfd, dst_dir_fd=dfd)
            os.fsync(dfd)
        finally:
            try:
                os.unlink(name, dir_fd=dfd)
            except FileNotFoundError:
                pass
        if self.read_at(dfd) != fields:
            raise OSError('readback failed')

    def remove_at(self, dfd):
        try:
            os.unlink(self.repo, dir_fd=dfd)
        except FileNotFoundError:
            pass


def file_connection(cwd, config_url, name):
    try:
        repo = repo_identity(cwd)
        fields = KeyStore(repo).read()
        if fields and fields['repo'] == repo and same_hook_server(config_url, fields['server']):
            return fields['server'], fields['key'], name
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, UnicodeError):
        pass
    return None


class Credential(str):
    """Tuple-compatible credential; retry metadata lives only in this process."""
    def __new__(cls, token, fallback=None, file_key=False):
        obj = super().__new__(cls, token)
        obj.fallback = fallback
        obj.file_key = file_key
        return obj
