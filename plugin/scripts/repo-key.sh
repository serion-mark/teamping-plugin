# ─────────────────────────────────────────────────────────────────────────────
# 팀핑 플러그인 — 이 폴더를 서버에 어떤 레포 표식으로 알릴지(훅들이 함께 쓴다 · source 해서 쓴다).
#
#   teamping_repo_key <폴더>   → 성공(0)이면 TEAMPING_RK(레포 표식) · TEAMPING_RK_ROOT(경로의 기준 폴더)
#                                실패(1)면 기록 대상이 아니다 — 그 훅은 서버에 아무것도 보내지 않는다.
#
#   · git origin 이 있으면 그 주소(지금처럼)
#   · git 저장소인데 origin 이 없으면 폴더 이름(지금처럼)
#   · git 저장소가 아니면 사용자가 정해 둔 폴더(teamping-folders.mjs)만 — 표식은 `dir:<id 앞 16자>`(폴더 이름 아님)
# ─────────────────────────────────────────────────────────────────────────────
#   TEAMPING_RK_KIND = git | dir — 등록 폴더인지는 이 값으로 가른다(git origin 이 우연히 `dir:` 로 시작해도 섞이지 않게).
teamping_repo_key() {
  local d="$1" out
  TEAMPING_RK=""; TEAMPING_RK_ROOT=""; TEAMPING_RK_KIND=""
  [ -n "$d" ] || return 1 # 빈 값이면 git -C "" 가 현재 폴더를 본다 — 대상 아님
  # 사용자 셸의 GIT_DIR 류가 판정을 남의 저장소로 바꾸지 않게 뺀다
  TEAMPING_RK="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$d" remote get-url origin 2>/dev/null || true)"
  if [ -n "$TEAMPING_RK" ]; then TEAMPING_RK_ROOT="$d"; TEAMPING_RK_KIND="git"; return 0; fi
  # 위쪽에 .git 표식이 있으면 git 에게 한 번만 묻는다(node 를 띄우지 않는다 — 편집 전 훅은 도구를 기다리게 한다).
  #   저장소면 지금처럼 폴더 이름 · git 이 「저장소 아님」이라 하면(빈 .git) 등록 폴더 판정으로 · git 이 없거나 이상하면 기록 안 함(계약).
  local up="$d" mark=""
  while [ -n "$up" ]; do
    if [ -e "$up/.git" ]; then mark=1; break; fi
    [ "$up" = "/" ] && break
    local next="${up%/*}"; [ -n "$next" ] || next="/"
    [ "$next" = "$up" ] && break # 상대경로 등 — 더 올라갈 수 없으면 멈춘다
    up="$next"
  done
  if [ -n "$mark" ]; then
    local g="" e=""
    if command -v git >/dev/null 2>&1; then
      # 답(stdout)과 오류(stderr)를 따로 본다 — GIT_TRACE 같은 출력이 섞여 저장소를 저장소 아님으로 보지 않게
      g="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR LC_ALL=C LANG=C git -C "$d" --no-optional-locks rev-parse --is-inside-work-tree 2>/dev/null)"
      if [ "$g" != "true" ]; then
        e="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR LC_ALL=C LANG=C git -C "$d" --no-optional-locks rev-parse --is-inside-work-tree 2>&1 >/dev/null)"
      fi
    fi
    if [ "$g" = "true" ]; then TEAMPING_RK="$(basename "$d")"; TEAMPING_RK_ROOT="$d"; TEAMPING_RK_KIND="git"; return 0; fi
    case "$e" in
      *"not a git repository"*) ;; # 빈·깨진 .git — 아래 등록 폴더 판정
      *) TEAMPING_RK=""; return 1 ;; # 표식은 있는데 git 이 없거나 이상하다 — 기록 안 함
    esac
  fi
  command -v node >/dev/null 2>&1 || return 1
  # 끝에 표식(.)을 붙여 받는다 — 명령 치환이 경로 끝의 줄바꿈을 지우지 못하게
  out="$(node "$(dirname "${BASH_SOURCE[0]}")/teamping-folders.mjs" resolve "$d" 2>/dev/null; printf .)" || out="."
  out="${out%.}"; out="${out%
}"
  case "$out" in
    git"	"*) TEAMPING_RK="$(basename "$d")"; TEAMPING_RK_ROOT="$d"; TEAMPING_RK_KIND="git"; return 0 ;;
    dir:*"	"*) TEAMPING_RK="${out%%	*}"; TEAMPING_RK_ROOT="${out#*	}"; TEAMPING_RK_KIND="dir"; return 0 ;;
  esac
  TEAMPING_RK=""; return 1
}
