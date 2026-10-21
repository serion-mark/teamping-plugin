#!/usr/bin/env python3
"""Receive a hook-scoped key through browser consent; never print credentials."""
import sys
if sys.version_info < (3, 11):
    print('TEAMPING_HOOKKEY_STOP no_python')
    raise SystemExit(2)
import base64
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
try:
    # The kit uses python -I: load only the installed sibling, never cwd/PYTHONPATH.
    helper = Path(__file__).resolve(strict=True).with_name('hook_key.py')
    spec = importlib.util.spec_from_file_location('teamping_hook_key', helper)
    keys = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(keys)
except Exception:
    print('TEAMPING_HOOKKEY_STOP exchange_failed')
    raise SystemExit(2)

LIMIT = 65536
WAIT = 540
GO_WAIT = 30
REASONS = {'bad_input', 'remote', 'no_python', 'no_repo', 'no_device', 'no_git',
           'server_off', 'hook_off', 'rate_limited', 'cancelled', 'timeout',
           'exchange_failed', 'exchange_lost', 'identity_mismatch', 'server_mismatch', 'locked', 'write_failed', 'flow_rejected'}
TEXT = {
    'ko': {'label': '동의 화면의 『이 열쇠의 이름』에 레포 이름을 적어 두면 나중에 고르기 쉽습니다.',
           'mismatch': '서버가 옛 판일 수 있어요 — 마이페이지 『연결 열쇠』에서 방금 생긴 열쇠를 끊어 주세요.'},
    'en': {'label': 'Name this repository in the consent screen key label so you can identify it later.',
           'mismatch': 'The server may be outdated. Revoke the newly created key in My page / Connection keys.'},
}


class Stop(Exception):
    def __init__(self, reason):
        self.reason = reason


class Expired(BaseException):
    pass


def expire(*args):
    raise Expired()


def arguments(argv):
    names = {'--origin', '--user', '--org', '--ch', '--dev'}
    if len(argv) != 10 or set(argv[::2]) != names:
        raise Stop('bad_input')
    v = {k[2:]: value for k, value in zip(argv[::2], argv[1::2])}
    if not keys.valid_origin(v['origin']) or v['dev'] not in {'mac', 'linux'}:
        raise Stop('bad_input')
    if any(not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', v[k]) for k in ('user', 'org')):
        raise Stop('bad_input')
    if v['ch'] and not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', v['ch']):
        raise Stop('bad_input')
    return v


def browser_command(dev):
    env = os.environ
    if any(env.get(k) for k in ('SSH_CONNECTION', 'SSH_TTY', 'SSH_CLIENT', 'WSL_DISTRO_NAME',
                                'REMOTE_CONTAINERS', 'REMOTE_CONTAINERS_IPC')) or env.get('CODESPACES') == 'true':
        raise Stop('remote')
    if Path('/.dockerenv').exists():
        raise Stop('remote')
    for file, pattern in [('/proc/version', 'microsoft'), ('/proc/1/cgroup', 'docker|kubepods|containerd')]:
        try:
            if re.search(pattern, Path(file).read_text()[:65536], re.I):
                raise Stop('remote')
        except OSError:
            pass
    if any(x in env.get('BROWSER', '') for x in ('vscode-server', 'browser.sh', 'helpers/browser')):
        raise Stop('remote')
    if dev == 'linux' and not (env.get('DISPLAY') or env.get('WAYLAND_DISPLAY')):
        raise Stop('remote')
    command = shutil.which('open' if dev == 'mac' else 'xdg-open')
    if command is None:
        raise Stop('remote')
    return command


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(url, fields=None, on_status=None):
    """Retain known HTTP status even when the body is lost after issuance."""
    data = urllib.parse.urlencode(fields).encode('ascii') if fields is not None else None
    req = urllib.request.Request(url, data=data, method='POST' if fields is not None else 'GET',
                                 headers={'Content-Type':'application/x-www-form-urlencoded', 'Accept':'application/json'})
    status = 0
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            response = opener.open(req, timeout=5 if fields is None else 30)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            status = response.status
            if on_status is not None:
                on_status(status)
            data = response.read(LIMIT + 1)
            return status, data if len(data) <= LIMIT else None
    except (TimeoutError, urllib.error.URLError) as error:
        if isinstance(error, urllib.error.URLError) and not isinstance(error.reason, TimeoutError):
            return status, None
        if fields is None:
            return status, None
        if fields is not None and status not in (0, 200):
            return status, None
        raise Stop('exchange_lost' if fields is not None and status == 200 else 'timeout') from None
    except Exception:
        return status, None


def probe(origin):
    status, _ = request(origin + '/kit/connect?purpose=hook')
    word = {404:'server_off', 503:'hook_off', 429:'rate_limited', 400:None}.get(status, 'server_off')
    if word:
        raise Stop(word)


class Receiver(HTTPServer):
    allow_reuse_address = False

    def get_request(self):
        sock, addr = super().get_request()
        sock.settimeout(1)
        return sock, addr

    def handle_error(self, *args):
        self.noise += 1  # Never log callback URLs, receipt codes, or state.


class Handler(BaseHTTPRequestHandler):
    server_version = 'Teamping'
    sys_version = ''

    def log_message(self, *args):
        pass

    def reply(self, status, location=None):
        body = b'<meta name="referrer" content="no-referrer"><script>history.replaceState(null,"","/done")</script>Teamping'
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; frame-ancestors 'none'")
        self.send_header('Connection', 'close')
        if location:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(body)

    def bad(self, *args, **kwargs):
        self.server.noise += 1
        self.reply(400)

    send_error = bad
    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = bad

    def do_GET(self):
        box = self.server
        if self.headers.get_all('Host') != [box.host] or len(self.path) > 2048:
            return self.bad()
        try:
            u = urllib.parse.urlsplit(self.path)
            if u.scheme or u.netloc or u.fragment:
                return self.bad()
            q = urllib.parse.parse_qs(u.query, keep_blank_values=True, max_num_fields=5)
            if any(len(v) != 1 for v in q.values()):
                return self.bad()
            q = {k:v[0] for k,v in q.items()}
        except ValueError:
            return self.bad()
        if u.path == '/go':
            if box.go or set(q) != {'n'} or not hmac.compare_digest(q['n'].encode(), box.nonce.encode()):
                return self.bad()
            box.go = True
            return self.reply(302, box.auth)
        if u.path != '/callback' or not box.go or not hmac.compare_digest(q.get('state','').encode(),box.state.encode()):
            return self.bad()
        if set(q) == {'state','code'} and re.fullmatch(r'teamping_kac_[0-9a-f]{64}',q['code']):
            box.result = q['code']
        elif q.get('error') == 'access_denied' and set(q) <= {'error','reason','state'}:
            box.result = False
        else:
            return self.bad()
        self.reply(200)


def receive_code(v, command):
    verifier = secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(__import__('hashlib').sha256(verifier.encode()).digest()).decode().rstrip('=')
    try:
        box = Receiver(('127.0.0.1',0),Handler)
    except OSError:
        raise Stop('remote') from None
    try:
        box.timeout = .2
        box.noise,box.go,box.result = 0,False,None
        box.host = '127.0.0.1:' + str(box.server_port)
        box.state,box.nonce = secrets.token_urlsafe(32),secrets.token_urlsafe(24)
        fields = {'port':str(box.server_port),'state':box.state,'challenge':challenge,
                  'org':v['org'],'dev':v['dev'],'purpose':'hook'}
        if v['ch']:
            fields['ch'] = v['ch']
        box.auth = v['origin']+'/kit/connect?'+urllib.parse.urlencode(fields)
        # Identical flow registration is idempotent. The browser repeats this
        # URL to receive its own cookie; this check never forwards that cookie.
        status, _ = request(box.auth)
        if status != 200:
            raise Stop('flow_rejected')
        lang = 'en' if os.environ.get('TEAMPING_LANG') == 'en' else 'ko'
        print(TEXT[lang]['label'],flush=True)
        with tempfile.TemporaryDirectory(prefix='teamping-hook-consent-') as temp:
            page = Path(temp)/'open.html'
            fd = os.open(page,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            with os.fdopen(fd,'w') as f:
                f.write('<meta name="referrer" content="no-referrer"><meta http-equiv="refresh" content="0;url=http://'+box.host+'/go?n='+box.nonce+'">')
            try:
                proc = subprocess.Popen([command,str(page)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            except OSError:
                raise Stop('remote') from None
            start = time.monotonic()
            while box.result is None:
                if time.monotonic()-start > WAIT:
                    raise Stop('timeout')
                if not box.go and (time.monotonic()-start > GO_WAIT or proc.poll() not in (None,0)):
                    raise Stop('remote')
                if box.noise >= 20:
                    raise Stop('cancelled')
                box.handle_request()
        if box.result is False:
            raise Stop('cancelled')
        return box.result,verifier,box.server_port
    finally:
        box.server_close()


def receive(v):
    command = browser_command(v['dev'])
    try:
        repo = keys.repo_identity(Path.cwd())
    except FileNotFoundError:
        raise Stop('no_git') from None
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        raise Stop('no_repo') from None
    try:
        raw = keys.raw_device(v['dev'])
        if raw is None:
            raise Stop('no_device')
        device = keys.hook_device_value(keys.kit_device_of(v['user'],os.getuid(),raw),repo)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        raise Stop('no_device') from None
    probe(v['origin'])
    store = keys.KeyStore(repo)
    try:
        with store.locked() as dfd:
            try:
                old = store.read_at(dfd)
            except (OSError, ValueError):
                old = None
            code,verifier,port = receive_code(v,command)
            issued = [False]
            response_status = [0]
            def remember_status(value):
                response_status[0] = value
                issued[0] = value == 200
            try:
                status,raw = request(v['origin']+'/kit/connect/token',{'code':code,'code_verifier':verifier,
                                    'port':str(port),'device':device,'expect_user_id':v['user'],
                                    'expect_org_id':v['org'],'purpose':'hook'},on_status=remember_status)
                try:
                    answer = json.loads(raw) if raw is not None else None
                except (ValueError,UnicodeError):
                    answer = None
                if status != 200:
                    if isinstance(answer,dict) and answer.get('reason') == 'identity_mismatch':
                        raise Stop('identity_mismatch')
                    raise Stop('exchange_failed')
                if raw is None:
                    raise Stop('exchange_lost')
                if not isinstance(answer,dict) or answer.get('purpose') != 'hook' or answer.get('scopes') != ['hook']:
                    raise Stop('server_mismatch')
                fields = {'v':'1','server':v['origin'],'key':answer.get('key'),'key_id':answer.get('token_id'),
                          'org':answer.get('org_id'),'channel':answer.get('channel_id'),'repo':repo}
                try:
                    keys.format_hook_key_file(fields)
                except (ValueError,TypeError,KeyError,UnicodeError):
                    raise Stop('server_mismatch') from None
                if fields['org'] != v['org'] or answer.get('user_id') != v['user']:
                    raise Stop('server_mismatch')
                moved = int(bool(old and (old['org'] != fields['org'] or old['channel'] != fields['channel'])))
                store.write_at(dfd,fields)
                if store.read()['key_id'] != fields['key_id']:
                    raise OSError('readback failed')
            except BaseException as error:
                if issued[0]:
                    store.remove_at(dfd)  # Only a known 200 may have revoked the old key.
                if isinstance(error, (Expired, TimeoutError)):
                    word = 'exchange_lost' if issued[0] else 'exchange_failed' if response_status[0] else 'timeout'
                    raise Stop(word) from None
                raise
            replaced = int(answer.get('replaced_old') == 1)
            print('TEAMPING_HOOKKEY_OK replaced_old='+str(replaced)+' moved='+str(moved)+' key='+fields['key_id'][:12])
    except keys.Locked:
        raise Stop('locked') from None
    except OSError:
        raise Stop('write_failed') from None
    except ValueError:
        raise Stop('write_failed') from None


def main(argv=None):
    signal.signal(signal.SIGALRM,expire)
    signal.setitimer(signal.ITIMER_REAL,WAIT+45)
    try:
        receive(arguments(sys.argv[1:] if argv is None else argv))
        return 0
    except Stop as e:
        reason = e.reason if e.reason in REASONS else 'exchange_failed'
    except (Expired,TimeoutError):
        reason = 'timeout'
    except KeyboardInterrupt:
        reason = 'cancelled'
    except BaseException:
        reason = 'exchange_failed'
    finally:
        signal.setitimer(signal.ITIMER_REAL,0)
    if reason == 'server_mismatch':
        lang = 'en' if os.environ.get('TEAMPING_LANG') == 'en' else 'ko'
        print(TEXT[lang]['mismatch'])
    print('TEAMPING_HOOKKEY_STOP '+reason)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
