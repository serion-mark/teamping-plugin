#!/usr/bin/env python3
"""Codex apply_patch lock adapter. Python >=3.11, macOS/Linux. Errors never block an edit.

No raw command/body/tool response is persisted or transmitted. Credentials are
read from the existing Codex MCP connection and never passed to a child process.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
try:
    import tomllib
except ImportError:
    tomllib = None  # Python 3.9/3.10: explain missing runtime without a traceback.
import urllib.error
import urllib.parse
import urllib.request

LIMIT = 1_048_576
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
MESSAGES = {
    "ko": {"shell": "팀핑: 셸 명령에 apply_patch/applypatch가 포함되어 있습니다. 이 경로의 편집은 자동 잠금을 확인하지 못합니다. MCP claim_file로 먼저 조율해 주세요.",
           "remote": "팀핑: Environment ID 가 있는 패치입니다. 원격 환경일 수 있어 잠금을 확인하지 못했을 수 있습니다(로컬 경로 기준으로 확인함).",
           "runtime": "팀핑: 잠금 확인에는 Python 3.11 이상이 필요합니다. python3 실행 환경을 확인해 주세요.",
           "unchecked": "팀핑: 경로 {n}개는 잠금을 확인하지 못했습니다.",
           "missing": "팀핑: 연결 토큰을 찾지 못해 이번 편집은 잠금을 확인하지 못했습니다.",
           "hook_missing": "팀핑: 이 레포엔 자동 잠금이 아직 없어요 — 『이 레포 팀핑 자동 잠금 켜줘』라고 요청해 주세요.",
           "hook_revoked": "팀핑: 자동 잠금 열쇠가 끊겼거나 멈췄어요 — 다시 켜 주세요."},
    "en": {"shell": "Teamping: this shell command contains apply_patch/applypatch. Automatic locks are not checked for this edit route. Coordinate with MCP claim_file first.",
           "remote": "Teamping: this patch names an Environment ID. It may target a remote environment, so locks may not have been checked (checked against local paths).",
           "runtime": "Teamping: lock checks require Python 3.11+. Check the python3 runtime.",
           "unchecked": "Teamping: locks could not be checked for {n} path(s).",
           "missing": "Teamping: no connection token found; locks were not checked for this edit.",
           "hook_missing": "Teamping: automatic locks are not set up for this repository. Ask to enable Teamping automatic locks here.",
           "hook_revoked": "Teamping: the automatic-lock key was revoked or paused. Enable it again."},
}
HOOK_NOTICE = None


def read_toml(path):
    with path.open("rb") as stream:
        raw = stream.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise ValueError("config size")
    return tomllib.loads(raw.decode())


def git(cwd, *args):
    env = {k: v for k, v in os.environ.items() if k not in
           {'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_CEILING_DIRECTORIES'}}
    env.update(LC_ALL='C', LANGUAGE='C')
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True,
                            timeout=.25, check=True, env=env)
    raw = result.stdout[:-1] if result.stdout.endswith(b'\n') else result.stdout
    return raw.decode('utf-8', 'strict')


def repo(cwd):
    root = Path(git(cwd, "rev-parse", "--show-toplevel")).resolve()
    try:
        remote = git(root, "remote", "get-url", "origin")
    except subprocess.CalledProcessError:
        remote = root.name
    if "://" in remote:
        url = urllib.parse.urlsplit(remote)
        host = url.hostname or ""
        if not host:
            raise ValueError("remote host")
        netloc = host + (":" + str(url.port) if url.port else "")
        remote = urllib.parse.urlunsplit((url.scheme, netloc, url.path, "", ""))
    elif "@" in remote:
        remote = remote.split("@", 1)[1]
    if not remote or any(ord(c) < 32 for c in remote):
        raise ValueError("remote")
    return root, remote


# The deadline is a BaseException (see Deadline), so no `except OSError` —
# ours or the standard library's (os.path.lexists/exists/realpath swallow
# OSError) — can catch it. Path helpers may therefore treat every OSError
# (missing, loop, name too long, permission) as "not this path".
MISSING = OSError
LISTINGS = {}
ROOT_IDS = {}


def same_dir(path, root):
    """True when path is root, tolerating aliases (case-insensitive names, firmlinks) by file identity.
    One stat per call: root's identity is looked up once per hook run."""
    if path == root:
        return True
    try:
        key = str(root)
        if key not in ROOT_IDS:
            st = os.stat(root)
            ROOT_IDS[key] = (st.st_dev, st.st_ino)
        st = os.stat(path)
        return (st.st_dev, st.st_ino) == ROOT_IDS[key]
    except MISSING:
        return False


def listing(directory):
    """One directory listing per hook run (a patch may name many files in one large folder)."""
    key = str(directory)
    if key not in LISTINGS:
        entries = os.listdir(directory)
        LISTINGS[key] = (entries, set(entries))
    return LISTINGS[key]


def canonical_case(root, relative):
    """Spell existing components as the filesystem does, so SUB/n.txt and sub/n.txt share one lock
    on case-insensitive filesystems. Components that do not exist yet keep the given spelling."""
    current, parts = root, []
    for part in relative.parts:
        name = part
        try:
            # Nothing to respell for a component that does not exist yet (skip the listing).
            if os.path.lexists(current / part):
                entries, names = listing(current)
                if part not in names:
                    name = next((e for e in entries if e.casefold() == part.casefold()
                                 and os.path.samefile(current / e, current / part)), part)
        except MISSING:
            pass
        parts.append(name)
        current = current / name
    return Path(*parts) if parts else relative


def in_git_tree(path):
    """Whether path sits inside some Git work tree (stat only, no subprocess)."""
    for ancestor in (path, *path.parents):
        try:
            if (ancestor / ".git").exists():
                return True
        except MISSING:
            continue
    return False


def under_root(path, root):
    """path relative to root, or None. Aliased spellings of root (case, firmlinks) still count."""
    try:
        return canonical_case(root, path.relative_to(root))
    except ValueError:
        pass
    for ancestor in path.parents:
        if same_dir(ancestor, root):
            return canonical_case(root, path.relative_to(ancestor))
    return None


def connection(root, cwd, lexical_cwd=None):
    """Use user MCP settings only; project overrides disable automatic lookup.

    Project trust is owned by Codex and cannot be inferred by reading a file.
    Never let repository content select an environment secret or destination.
    """
    global HOOK_NOTICE
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    name = os.environ.get("TEAMPING_MCP_SERVER", "teamping")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", name):
        return None
    config = read_toml(home / "config.toml").get("mcp_servers", {}).get(name, {})
    if not isinstance(config, dict):
        return None
    # Codex trust belongs to the host. Check overrides on both the physical
    # directory chain and a lexical chain that reaches this same Git root.
    # Never walk past the repo into user-level ~/.codex configuration.
    directories = set()
    for start in (cwd, lexical_cwd):
        if start is None:
            continue
        chain = []
        reached = False
        for cursor in (start, *start.parents):
            chain.append(cursor)
            if same_dir(cursor, root):
                directories.update(chain)
                reached = True
                break
        # The physical chain must reach the Git root; otherwise overrides cannot
        # be ruled out, so send nothing and let the edit proceed.
        if start is cwd and not reached:
            return None
    for cursor in directories:
        path = cursor / ".codex/config.toml"
        if path.exists() and name in read_toml(path).get("mcp_servers", {}):
            return None
    if config.get("enabled") is False:
        return None
    config_url = config.get("url", "")
    if not isinstance(config_url, str):
        return None
    url = urllib.parse.urlsplit(config_url)
    local = url.hostname in {"127.0.0.1", "localhost", "::1"}
    if url.scheme != "https" and not (url.scheme == "http" and local and os.environ.get("TEAMPING_ALLOW_LOCAL_TEST") == "1"):
        return None
    if url.username or url.password or url.query or url.fragment or not url.hostname:
        return None
    if not url.path.rstrip("/").endswith("/mcp"):
        return None
    base = urllib.parse.urlunsplit((url.scheme, url.netloc, url.path.rstrip("/")[:-4], "", ""))
    token = ""
    bearer_configured = ('bearer_token_env_var' in config or
        any(k.lower() == 'authorization' for k in config.get('http_headers', {})) or
        any(k.lower() == 'authorization' for k in config.get('env_http_headers', {})))
    env_name = config.get("bearer_token_env_var")
    if isinstance(env_name, str):
        token = os.environ.get(env_name, "")
    else:
        headers = config.get("http_headers", {})
        env_headers = config.get("env_http_headers", {})
        auth = next((v for k, v in headers.items() if k.lower() == "authorization"), "")
        auth_env = next((v for k, v in env_headers.items() if k.lower() == "authorization"), None)
        if auth_env is not None:
            auth = os.environ.get(auth_env, "")
        if isinstance(auth, str) and auth.startswith("Bearer "):
            token = auth[7:]
    valid_bearer = isinstance(token, str) and bool(token) and len(token) <= 8192 and all(33 <= ord(c) <= 126 for c in token)
    try:
        from hook_key import Credential, file_connection
    except Exception:
        # A partial plugin install must not disable an existing Bearer path.
        return (base, token, name) if valid_bearer else None
    fallback = lambda: file_connection(cwd, config_url, name)
    if valid_bearer:
        return base, Credential(token, fallback=fallback), name
    found = fallback()
    if found:
        dest, key, server = found
        return dest, Credential(key, file_key=True), server
    if not bearer_configured:
        HOOK_NOTICE = 'hook_missing'
    return None


def patch_lines(command):
    if not isinstance(command, str):
        return []
    lines = [line.removesuffix("\r") for line in command.strip().split("\n")]
    if len(lines) >= 4 and lines[0] in {"<<EOF", "<<'EOF'", '<<"EOF"'} and lines[-1].endswith("EOF"):
        lines = lines[1:-1]
    return lines


def remote_patch(command):
    lines = patch_lines(command)
    return len(lines) >= 3 and lines[0].strip() == "*** Begin Patch" and lines[1].strip().startswith("*** Environment ID:")


def candidates_hit(candidates, root):
    return any(under_root(c, root) is not None for c in candidates)


def patch_paths(command, cwd, root):
    """Only actual patch headers, never added/context body text, become paths."""
    if not isinstance(command, str):
        return [], 1
    lines = patch_lines(command)
    whitespace = "\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"
    if len(lines) < 2 or lines[0].strip(whitespace) != "*** Begin Patch" or lines[-1].strip(whitespace) != "*** End Patch":
        return [], 1
    found, unchecked, headers = [], 0, 0
    mode = None
    for line in lines[1:-1]:
        # Update context lines begin with a space: never trim their leading edge.
        # Codex trims both edges only outside an Update hunk.
        header = line.rstrip(whitespace) if mode == "Update File" else line.strip(whitespace)
        match = re.fullmatch(r"\*\*\* (Add File|Update File|Delete File|Move to): (.+)", header)
        if not match:
            continue
        operation, raw = match.groups()
        headers += 1
        if operation != "Move to":
            mode = operation
        # apply_patch trims trailing Unicode whitespace, but preserves leading path space.
        raw = raw.rstrip("\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000")
        if "\\" in raw or re.match(r"^[A-Za-z]:", raw) or any(ord(c) < 32 for c in raw):
            unchecked += 1
            continue
        lexical = Path(os.path.abspath(cwd / raw))
        try:
            target = lexical.resolve()
        except (OSError, RuntimeError):
            unchecked += 1  # Python 3.11/3.12 report symlink loops as RuntimeError.
            continue
        candidates = [lexical, target]
        if under_root(target, root) is None:
            # Removing a leaf symlink affects its directory entry, not its target.
            if operation == "Delete File":
                candidates = [lexical.parent.resolve() / lexical.name]
            else:
                candidates = []
        before = len(found)
        for candidate in dict.fromkeys(candidates):
            relative = under_root(candidate, root)
            if relative is None:
                continue
            rel = relative.as_posix()
            if rel == "." or len(rel.encode("utf-16-le")) // 2 > 512:
                unchecked += 1
            elif rel not in found:
                found.append(rel)
        if len(found) == before and not candidates_hit(candidates, root):
            # Nothing inside this repo. Never drop silently when the file lives in
            # another Git work tree (a link cwd may point there while the host edits
            # a file here); plain files outside any repo (e.g. /tmp) need no lock.
            if in_git_tree(lexical.parent) or in_git_tree(target.parent):
                unchecked += 1
    return found[:200], unchecked + max(0, len(found) - 200) + int(headers == 0)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(base, token, door, body, locale, timeout=1.1, success_only=False, _secrets=None):
    global HOOK_NOTICE
    if door not in {'sessionstart', 'pretooluse', 'observe', 'precommit', 'sessionend', 'inbox'}:
        return {}
    secrets_seen = tuple(_secrets or ()) + (str(token),)
    data = json.dumps(body, ensure_ascii=False).encode()
    if len(data.decode()) > 110_592:
        return {}
    request = urllib.request.Request(base + "/api/hooks/" + door, data=data,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token,
                 "Accept-Language": locale}, method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        response = opener.open(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error  # Read decision, not HTTP status; redirects are not followed.
    if response.status == 401:
        response.close()
        fallback = getattr(token, 'fallback', None)
        found = fallback() if fallback is not None else None
        if found:
            from hook_key import Credential
            dest, key, _ = found
            return post(dest, Credential(key, file_key=True), door, body, locale, timeout, success_only, secrets_seen)
        if getattr(token, 'file_key', False):
            HOOK_NOTICE = 'hook_revoked'
        return {}
    if response.status == 403 and getattr(token, 'file_key', False):
        HOOK_NOTICE = 'hook_revoked'
        # Never retry a scope denial. Preserve an existing deny decision,
        # however, so an HTTP status change cannot silently bypass a lock.
    with response:
        if success_only and response.status != 200:
            return {}
        raw = response.read(LIMIT + 1)
    if len(raw) > LIMIT or any(secret.encode() in raw for secret in secrets_seen):
        return {}
    result = json.loads(raw)
    def echoes_secret(value):
        if isinstance(value, str):
            return any(secret in value for secret in secrets_seen)
        if isinstance(value, dict):
            return any(echoes_secret(k) or echoes_secret(v) for k, v in value.items())
        if isinstance(value, list):
            return any(echoes_secret(v) for v in value)
        return False
    return result if isinstance(result, dict) and not echoes_secret(result) else {}


def notice_once(session, why, message):
    """Only a hash-named empty marker; no secret, path or server text is stored."""
    home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    directory = home / "teamping-hook-notices"
    try:
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            return message  # Cannot deduplicate safely; showing the notice is safer.
        name = hashlib.sha256((session + "\0" + why).encode()).hexdigest()
        try:
            fd = os.open(directory / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            return None
        os.close(fd)
    except OSError:
        return message  # Read-only/full notice storage must never hide auth status.
    return message


def with_notice(event, output):
    """Only local fixed notices; never copy server auth error bodies to the UI."""
    if HOOK_NOTICE is None or not isinstance(event, dict):
        return output
    session = event.get('session_id')
    if not isinstance(session, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', session):
        return output
    lang = 'en' if os.environ.get('TEAMPING_LANG') == 'en' else 'ko'
    text = notice_once(session, HOOK_NOTICE, MESSAGES[lang][HOOK_NOTICE])
    if text:
        output = dict(output or {})
        output['systemMessage'] = text
    return output


def handle(event):
    level = os.environ.get("TEAMPING_LEVEL", "lv2" if os.environ.get("PLUGIN_ROOT") else "lv1")
    if level not in {"lv2", "lv3"} or not isinstance(event, dict):
        return None
    kind = event.get("hook_event_name")
    tool = event.get("tool_name")
    if kind not in {"SessionStart", "SessionEnd", "PreToolUse", "PostToolUse"}:
        return None
    # Only a fresh start is supported for now; resumed sessions are not re-announced.
    if kind == "SessionStart" and event.get("source") != "startup":
        return None
    if kind == "PreToolUse" and tool not in {"apply_patch", "Bash"}:
        return None
    session = event.get("session_id")
    if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", session):
        return None
    locale = "en" if os.environ.get("TEAMPING_LANG") == "en" else "ko"
    inp = event.get("tool_input")
    inp = inp if isinstance(inp, dict) else {}
    command = inp.get("command")
    if kind == "PreToolUse" and tool == "Bash":
        # A conservative literal detector, not a shell interpreter. Never send
        # shell text or guess paths/workdir/cd for this unsupported edit route.
        if isinstance(command, str) and re.search(r"(?<![A-Za-z0-9_])apply_?patch(?![A-Za-z0-9_])", command):
            message = notice_once(session, "shell-patch", MESSAGES[locale]["shell"])
            return {"systemMessage": message, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": message}} if message else None
        return None
    # An Environment ID may name the local environment too (Codex picks any turn
    # environment), so still lock local paths and warn instead of skipping.
    remote = tool == "apply_patch" and remote_patch(command)
    if tomllib is None:
        if kind in {"SessionStart", "PreToolUse"}:
            message = notice_once(session, "python-runtime", MESSAGES[locale]["runtime"])
            return {"systemMessage": message} if message else None
        return None
    # Preserve the host's lexical cwd for path joining (link/.. != target/..).
    # Resolve separately for Git/config lookup; never use that resolved cwd to
    # choose which file the patch edits.
    cwd = Path(event["cwd"])
    if not cwd.is_absolute():
        return None
    physical_cwd = cwd.resolve(strict=True)
    root, repo_key = repo(physical_cwd)
    creds = connection(root, physical_cwd, cwd)
    if creds is None:
        if kind == "PreToolUse" and HOOK_NOTICE is None:
            message = notice_once(session, "no-token", MESSAGES[locale]["missing"])
            return {"systemMessage": message} if message else None
        return None
    base, token, server_name = creds
    body = {"session_id": session, "agent": "codex", "repo_key": repo_key}
    paths, unchecked = patch_paths(inp.get("command"), cwd, root) if tool == "apply_patch" else ([], 0)
    if kind == "SessionStart":
        if isinstance(event.get("session_title"), str):
            body["session_title"] = event["session_title"][:200]
        post(base, token, "sessionstart", body, locale)
    elif kind == "SessionEnd":
        body["sent_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        post(base, token, "sessionend", body, locale)
    elif kind == "PreToolUse":
        result = post(base, token, "pretooluse", dict(body, tool_name="apply_patch", file_paths=paths, locale=locale), locale) if paths else {}
        output = {}
        if result.get("decision") == "deny" and isinstance(result.get("reason"), str):
            output["hookSpecificOutput"] = {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": result["reason"]}
        elif isinstance(result.get("notice"), str) and result["notice"]:
            message = notice_once(session, str(result.get("why", "allow")), result["notice"])
            if message:
                output["systemMessage"] = message
        truncated = result.get("truncated", 0)
        unchecked += truncated if isinstance(truncated, int) and not isinstance(truncated, bool) and truncated > 0 else 0
        if unchecked:
            output["systemMessage"] = (output.get("systemMessage", "") + "\n" + MESSAGES[locale]["unchecked"].format(n=unchecked)).strip()
        if remote:
            output["systemMessage"] = (output.get("systemMessage", "") + "\n" + MESSAGES[locale]["remote"]).strip()
        return output or None
    elif kind == "PostToolUse":
        child = bool(event.get("agent_id"))
        claim = re.fullmatch(r"mcp__" + re.escape(server_name) + r"__(claim_work|claim_file)", tool or "")
        if not isinstance(tool, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,180}", tool):
            return None
        observe = dict(body, tool_name=tool, changed=paths)
        if claim:
            candidate = inp.get("manifestId")
            if not isinstance(candidate, str) or not UUID.fullmatch(candidate):
                return None
            observe["claimed_manifest_id"] = candidate
        # Observe every tool so read receipts and ordinary-tool delivery work.
        # Only IDs and existing metadata leave this process, never raw results.
        state = None
        acks = []
        message_id = None
        try:
            from inbox_state import State, emit_context, posted_id
            message_id = posted_id(tool, event.get("tool_response"), server_name)
            if not child:
                state = State(root, base, token, session)
                acks = state.acks()
        except Exception:
            state = None  # Inbox failure must not disable the existing observation/pin.
        if not child:
            observe["inbox_ack"] = acks
        elif isinstance(event["agent_id"], str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", event["agent_id"]):
            observe["subagent_id"] = event["agent_id"]
        if message_id:
            observe["posted_message_id"] = message_id
        result = post(base, token, "observe", observe, locale, success_only=True)
        if state is not None:
            try:
                state.receive(acks, result, "inbox", locale, emit=lambda lines: emit_context("PostToolUse", lines))
            except Exception:
                pass
        return None
    return None


class Deadline(BaseException):
    """The 1.7s budget. BaseException on purpose: TimeoutError is an OSError
    and the standard library swallows OSError in path checks."""


def timeout(signum, frame):
    raise Deadline()


def main():
    # Include parsing, config/git, DNS, HTTP body read, and output in one budget.
    signal.signal(signal.SIGALRM, timeout)
    signal.setitimer(signal.ITIMER_REAL, 1.7)
    event = None
    try:
        if len(sys.argv) != 1:
            return
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            return
        event = json.loads(raw)
        output = with_notice(event, handle(event))
        if output:
            print(json.dumps(output, ensure_ascii=False))
    except (Exception, Deadline):
        # A known auth failure still gets its fixed notice when body reading
        # fails or consumes the deadline. Never print the failed response.
        signal.setitimer(signal.ITIMER_REAL, 0)
        try:
            output = with_notice(event, None)
            if output:
                print(json.dumps(output, ensure_ascii=False))
        except (Exception, Deadline):
            pass  # Recovery errors must not block the edit either.
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    # Last line of defence: a deadline landing inside main's except/finally window
    # must still end with exit 0 and no traceback (the host shows non-zero exits as errors).
    try:
        main()
    except BaseException:
        pass
