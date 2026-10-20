# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 이 창 몫으로 맡아 둔 팀핑 연락이 있는지 셸에서 바로 본다(훅들이 `.` 로 불러 쓴다).
#   node 를 띄우지 않으려고 파일 이름만 본다: ~/.config/teamping/inbox/<창>.<세션>.pending.json
#   세션 id 는 훅 입력(JSON)의 "session_id" 값이다. 모양(영문·숫자·_-)이 아니면 「없다」로 본다.
# ─────────────────────────────────────────────────────────────────────────────

# 훅 입력에서 세션 id 후보를 뽑는다(같은 키가 여러 번 나오면 모두).
teamping_inbox_sids() {
  printf '%s' "$1" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]{1,80}"' 2>/dev/null \
    | sed -E 's/.*"([A-Za-z0-9_-]{1,80})"$/\1/' | sort -u
}

# 이 창 몫으로 맡아 둔 줄이 있으면 0.
teamping_inbox_has_pending() {
  local d="${HOME:-}/.config/teamping/inbox" sid
  [ -d "$d" ] || return 1
  for sid in $(teamping_inbox_sids "$1"); do
    compgen -G "$d/*.$sid.pending.json" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 창을 닫을 때 — 이 창 몫으로 맡아 둔 줄과 기다리는 훅의 차례 표시를 지운다.
teamping_inbox_forget() {
  local d="${HOME:-}/.config/teamping/inbox" sid f
  [ -d "$d" ] || return 0
  for sid in $(teamping_inbox_sids "$1"); do
    for f in "$d"/*."$sid".pending.json "$d"/*."$sid".wait; do
      [ -f "$f" ] && [ ! -L "$f" ] && rm -f "$f"
    done
  done
  return 0
}
