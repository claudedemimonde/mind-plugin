#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# The Project Mind check-in hook (DESIGN.md "Build" BT13, BT15), run by Claude Code as
# PostToolUse after every tool call. POSIX sh only: no Node, no jq. It prints nothing and
# always exits 0, so the common case must cost almost nothing.
#
#   - No sign-in on this machine: leave at once.
#   - report / raise_decision: note the task in the session's binding file (append only, so
#     parallel tool calls cannot lose one). `report` with status done removes it.
#   - any other tool: once per 5 minutes per session, hand the bindings to `mind-checkin send`,
#     detached, so a slow network never slows a tool call.
#   - run with the argument `stop` (the Stop hook, a turn ended): only restart a dead relay (BT16).
#   - run with the argument `watch` by `mind-checkin watch` (BT30), with a synthetic payload: register the session and start the relay now.
#
# A binding line is   <epoch> TAB <mcp server name> TAB <task id> TAB B|D   (B = bound, D = dropped).
exec >/dev/null 2>&1
# Every file this hook writes (follows, own ids, bindings) names tasks and ids: nobody else on the machine reads them.
umask 077
# Bytes, not characters: head -c can cut a character in half, and macOS sed fails on what is left.
LC_ALL=C
export LC_ALL
dir="${MIND_CHECKIN_DIR:-$HOME/.config/mind}"
here=$(cd "${0%/*}" 2>/dev/null && pwd) || exit 0

mode=${1:-} # `stop` = run by the Stop hook; read before `set --` below replaces the arguments
set -- "$dir"/origins/*/refresh
[ -f "$1" ] || exit 0
input=$(cat) || exit 0

# BT16 - messages to sessions. The relay (mind-relay) is started HERE, by this same PostToolUse hook (and again by its Stop entry, so a relay that died
# while the session idles comes back). One relay per socket path, not per session id: /clear gives a new id on the same socket, and the
# relay polls the union of the bindings of every id registered for it. $1 = session id, $2 = "register" to add the id to the set.
# Windows (no nc), cloud, -p and headless sessions (no socket in the environment) get none.
relay_ensure() {
  _sock=${CLAUDE_CODE_MESSAGING_SOCKET:-}
  [ -n "$_sock" ] && [ -n "${CLAUDE_CODE_MESSAGING_TOKEN:-}" ] || return 0
  # The key is a cksum of the socket path. A resumed session keeps its id but gets a new socket, so the cache names the socket too.
  _rk=; _rs=
  [ -f "$dir/sessions/$1.rk" ] && read -r _rk _rs < "$dir/sessions/$1.rk"
  if [ "$_rs" != "$_sock" ]; then
    _rk=$(printf '%s' "$_sock" | cksum); _rk=${_rk%% *}
    printf '%s %s\n' "$_rk" "$_sock" > "$dir/sessions/$1.rk"
    # A resumed session keeps its id but gets a new socket, so the new key's session set has never heard of it: this call registers
    # it (its bindings and follows are then polled by the relay of the new socket, not left with the old one).
    set -- "$1" register
  fi
  case $_rk in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$dir/relays" || return 0
  if [ "${2:-}" = register ] && ! grep -qx -- "$1" "$dir/relays/$_rk.sids" 2>/dev/null; then
    printf '%s\n' "$1" >> "$dir/relays/$_rk.sids"
    tail -n 20 "$dir/relays/$_rk.sids" > "$dir/relays/$_rk.sids.tmp.$$" && mv -f "$dir/relays/$_rk.sids.tmp.$$" "$dir/relays/$_rk.sids"
  fi
  _rp=
  [ -f "$dir/relays/$_rk.pid" ] && read -r _rp < "$dir/relays/$_rk.pid"
  case $_rp in ''|*[!0-9]*) ;; *) if kill -0 "$_rp" 2>/dev/null; then return 0; fi ;; esac
  # Not running. Try again at most once a minute per session, unless this call just bound a task.
  _rn=$(date +%s) || return 0
  if [ "${2:-}" != register ]; then
    _rl=0
    [ -f "$dir/stamps/$1.rt" ] && read -r _rl < "$dir/stamps/$1.rt"
    case $_rl in ''|*[!0-9]*) _rl=0 ;; esac
    [ $((_rn - _rl)) -ge 60 ] || return 0
  fi
  mkdir -p "$dir/stamps" || return 0
  printf '%s\n' "$_rn" > "$dir/stamps/$1.rt"
  command -v nc >/dev/null 2>&1 || return 0
  [ -f "$here/mind-relay" ] || return 0
  # Only a sign-in that holds a RELAY token gets one; a check-in-only sign-in starts nothing.
  grep -qx 'mind:relay' "$dir"/origins/*/scope 2>/dev/null || return 0
  if ! mkdir "$dir/relays/$_rk.lock" 2>/dev/null; then
    # A claim older than a minute belongs to a start that died.
    if [ -n "$(find "$dir/relays/$_rk.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$dir/relays/$_rk.lock"; mkdir "$dir/relays/$_rk.lock" 2>/dev/null || return 0; else return 0; fi
  fi
  # Claude's pid: its own CLAUDE_PID when it is alive, else our parent, skipping a shell that was only in between.
  _cp=${CLAUDE_PID:-}
  case $_cp in ''|*[!0-9]*) _cp= ;; *) kill -0 "$_cp" 2>/dev/null || _cp= ;; esac
  if [ -z "$_cp" ]; then
    _cp=$PPID; _hop=0
    while [ "$_hop" -lt 3 ]; do
      _comm=$(ps -o comm= -p "$_cp" 2>/dev/null); _comm=${_comm##*/}
      case $_comm in sh|-sh|bash|-bash|dash|-dash|zsh|-zsh|ash|ksh) _cp=$(ps -o ppid= -p "$_cp" 2>/dev/null | tr -d ' ') ;; *) break ;; esac
      case $_cp in ''|*[!0-9]*) rmdir "$dir/relays/$_rk.lock"; return 0 ;; esac
      _hop=$((_hop + 1))
    done
  fi
  ( sh "$here/mind-relay" "$_rk" "$_cp" </dev/null >/dev/null 2>&1 & )
  return 0
}

# Proof by round trip, at no token cost. The relay writes relays/KEY.posted-at ("epoch version idle window") after each post into this
# session; idle is 1 when the session was idle at that moment (relays/KEY.idle-at, written by the Stop hook, newer than busy-at, written
# by every tool call). Any hook event after an idle post (a tool call, or a Stop at the end of a text-only turn) shows the session woke:
# the version is proven (ok-versions) and the file is cleared. A post into a busy session proves nothing and counts as no miss. An older
# post is left for the relay to judge. Runs for PostToolUse and Stop. $1 = session id; sets RK to the relay key, or empty.
relay_prove() {
  RK=
  [ -f "$dir/sessions/$1.rk" ] || return 0
  _pk=; read -r _pk _ < "$dir/sessions/$1.rk"
  case $_pk in ''|*[!0-9]*) return 0 ;; esac
  RK=$_pk
  [ -f "$dir/relays/$_pk.posted-at" ] || return 0
  _pe=; _pv=; _pi=; _pw=; read -r _pe _pv _pi _pw < "$dir/relays/$_pk.posted-at"
  case $_pe in ''|*[!0-9]*) return 0 ;; esac
  case $_pv in ''|*[!0-9.]*) return 0 ;; esac
  case $_pw in ''|*[!0-9]*) _pw=600 ;; esac
  [ "$_pi" = 1 ] || return 0
  _pn=$(date +%s) || return 0
  [ $((_pn - _pe)) -lt "$_pw" ] || return 0
  grep -Fqx -- "$_pv" "$dir/ok-versions" 2>/dev/null || printf '%s\n' "$_pv" >> "$dir/ok-versions"
  rm -f "$dir/relays/$_pk.posted-at" "$dir/relays/$_pk.misses"
}
# $1 = idle or busy: stamps the epoch the relay reads when it posts. Needs RK (set by relay_prove).
relay_stamp() {
  [ -n "$RK" ] && [ -d "$dir/relays" ] || return 0
  date +%s > "$dir/relays/$RK.$1-at" 2>/dev/null
  return 0
}

# Claude Code writes session_id first and tool_name before tool_input; read only what precedes
# tool_input, so nothing a tool carries can pose as a top-level field.
prefix=$(printf '%s' "$input" | head -c 65536)
top=${prefix%%'"tool_input"'*}
sid=$(printf '%s' "$top" | sed -n -E 's/.*"session_id" *: *"([^"]*)".*/\1/p' | head -n 1 | tr -cd 'A-Za-z0-9_-' | cut -c1-64)
tool=$(printf '%s' "$top" | sed -n -E 's/.*"tool_name" *: *"([^"]*)".*/\1/p' | head -n 1)
[ -n "$sid" ] || exit 0

# The Stop hook (`sh mind-checkin-hook.sh stop`, run when a turn ends): a session that ended its turn to wait would otherwise lose its
# relay for good, because only a later tool call restarts it. Cheap: no network unless the relay is started; prints nothing.
if [ "$mode" = watch ]; then
  relay_ensure "$sid" register
  exit 0
fi
if [ "$mode" = stop ]; then
  relay_prove "$sid"
  relay_stamp idle
  [ -s "$dir/sessions/$sid.bind" ] || [ -s "$dir/sessions/$sid.follow" ] || [ -s "$dir/sessions/$sid.jobs" ] || [ -s "$dir/sessions/$sid.watches" ] || exit 0
  relay_ensure "$sid"
  exit 0
fi
relay_prove "$sid"
relay_stamp busy

# BT23 - job results wake the session. The reply of request_work / request_test_run / request_experiment names the job ids; one group line
# `J <writtenEpoch> <jobId>...` goes to the session's own sessions/<id>.jobs (append only: the relay appends `D <jobId>` to the same file,
# it never rewrites it). The ids come from the REPLY, never from the input (a model's own words), and only for a server an origin names,
# so a local Mind's job id is never polled on the hosted one. A repeat (`created: false`) whose ids a line already holds writes nothing.
# A request is also a tool call: this only notes the job, and the hook goes on to the normal check-in path below (a bound session still checks in).
jobs_note() {
  server=$(printf '%s' "$tool" | sed -E 's/^mcp__(.*)__request_(work|test_run|experiment)$/\1/')
  case $server in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  rest=${prefix#*'"tool_input"'}
  resp=${rest#*'"tool_response"'}
  [ "$resp" != "$rest" ] || return 0
  if printf '%s' "$resp" | grep -Eq '"is_?[Ee]rror" *: *true'; then return 0; fi
  grep -qx -- "$server" "$dir"/origins/*/servers 2>/dev/null || return 0
  jids=$(printf '%s' "$resp" | grep -oE '\\*"jobId\\*" *: *\\*"[A-Za-z0-9_-]{1,64}' | sed -E 's/.*"([A-Za-z0-9_-]+)$/\1/' | awk '!s[$0]++' | head -n 10 | tr '\n' ' ')
  [ -n "$jids" ] || return 0
  mkdir -p "$dir/sessions" || return 0
  if printf '%s' "$resp" | grep -Eq '\\*"created\\*" *: *false' && [ -f "$dir/sessions/$sid.jobs" ]; then
    known=y
    for j in $jids; do grep -Eq "^J [0-9]+( [A-Za-z0-9_-]+)* $j( |\$)" "$dir/sessions/$sid.jobs" || known=; done
    [ -z "$known" ] || return 0
  fi
  printf 'J %s %s\n' "$(date +%s)" "${jids% }" >> "$dir/sessions/$sid.jobs" || return 0
  relay_ensure "$sid" register
  return 0
}
case $tool in
  mcp__*__request_work|mcp__*__request_test_run|mcp__*__request_experiment) jobs_note ;;
esac

# BT30 - a `watch` reply: `W <writtenEpoch> <watchId>` to sessions/<id>.watches (append only, the relay appends `D <watchId>`). Like the J line, the
# id comes from the REPLY, never the input, for a server an origin names. A repeat (`created: false`) of an id the file already holds writes nothing.
watch_note() {
  server=$(printf '%s' "$tool" | sed -E 's/^mcp__(.*)__watch$/\1/')
  case $server in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  rest=${prefix#*'"tool_input"'}
  resp=${rest#*'"tool_response"'}
  [ "$resp" != "$rest" ] || return 0
  if printf '%s' "$resp" | grep -Eq '"is_?[Ee]rror" *: *true'; then return 0; fi
  # Set, then look (BT29): a watch that fired in the creation request told the session in this very reply; a W line would wake it again.
  if printf '%s' "$resp" | grep -Eq '\\*"state\\*" *: *\\*"fired'; then return 0; fi
  grep -qx -- "$server" "$dir"/origins/*/servers 2>/dev/null || return 0
  wid=$(printf '%s' "$resp" | grep -oE '\\*"watchId\\*" *: *\\*"[A-Za-z0-9_-]{1,64}' | head -n 1 | sed -E 's/.*"([A-Za-z0-9_-]+)$/\1/')
  [ -n "$wid" ] || return 0
  mkdir -p "$dir/sessions" || return 0
  grep -Eq "^W [0-9]+ $wid\$" "$dir/sessions/$sid.watches" 2>/dev/null && return 0
  printf 'W %s %s\n' "$(date +%s)" "$wid" >> "$dir/sessions/$sid.watches" || return 0
  relay_ensure "$sid" register
  return 0
}
case $tool in
  mcp__*__watch) watch_note ;;
esac

case $tool in
  mcp__*__report|mcp__*__raise_decision|mcp__*__follow_task)
    server=$(printf '%s' "$tool" | sed -E 's/^mcp__(.*)__(report|raise_decision|follow_task)$/\1/')
    kind=${tool##*__}
    case $server in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
    rest=${prefix#*'"tool_input"'}
    args=${rest%%'"tool_response"'*}
    resp=${rest#*'"tool_response"'}
    # A reply that says it failed binds nothing (Claude Code fires PostToolUseFailure for real failures).
    if [ "$resp" != "$rest" ] && printf '%s' "$resp" | grep -Eq '"is_?[Ee]rror" *: *true'; then exit 0; fi
    if [ "$kind" = report ]; then field=taskId; else field=subjectId; fi
    if [ "$kind" = follow_task ]; then
      # BT18: the task and the expiry come from the REPLY, never the input (a model's own words): a follow that Mind did not accept binds nothing.
      # The reply may be plain JSON or JSON inside a JSON string (quotes escaped), hence the optional backslashes.
      fact=$(printf '%s' "$args" | sed -n -E 's/.*"action" *: *"(follow|unfollow)".*/\1/p' | head -n 1)
      [ -n "$fact" ] || exit 0
      task=$(printf '%s' "$resp" | grep -oE '\\*"taskId\\*" *: *\\*"[A-Za-z0-9_-]{1,100}' | head -n 1 | sed -E 's/.*"([A-Za-z0-9_-]+)$/\1/')
      fexp=0
      if [ "$fact" = follow ]; then
        fexp=$(printf '%s' "$resp" | grep -oE '\\*"expiresEpoch\\*" *: *[0-9]{9,11} *\}' | tail -n 1 | grep -oE '[0-9]{9,11}')
        case $fexp in ''|*[!0-9]*) exit 0 ;; esac
      fi
    else
      task=$(printf '%s' "$args" | sed -n -E "s/.*\"$field\" *: *\"([A-Za-z0-9_-]{1,100})\".*/\\1/p" | head -n 1)
    fi
    [ -n "$task" ] || exit 0
    # Only a server the sign-in file names counts, so a localhost task id is never posted to a hosted Mind.
    if ! grep -qx -- "$server" "$dir"/origins/*/servers 2>/dev/null; then
      # Leave a note (BT17): `mind-checkin status` names servers that report but are not linked. Never a task id.
      now=$(date +%s) || exit 0
      # One line per server per 5 minutes (the tail is enough to see that), and the file stays under 16 KB.
      seen=
      if [ -f "$dir/unlinked" ]; then
        seen=$(tail -n 50 "$dir/unlinked" | awk -F'\t' -v s="$server" -v min=$((now - 300)) '$2 == s && $1 >= min { print "y"; exit }')
      fi
      if [ -z "$seen" ]; then
        printf '%s\t%s\n' "$now" "$server" >> "$dir/unlinked" || exit 0
        if [ $(wc -c < "$dir/unlinked") -gt 16384 ]; then
          tail -n 200 "$dir/unlinked" > "$dir/unlinked.tmp.$$" && mv -f "$dir/unlinked.tmp.$$" "$dir/unlinked"
        fi
      fi
      exit 0
    fi
    if [ "$kind" = follow_task ]; then
      # A follow lives in its own file, never in the binding file: the parsers of that file drop a binding on any line that is not a live B.
      # <epoch> TAB <server> TAB <task> TAB <expiry epoch, 0 = unfollowed>. A follow never sends a check-in and never moves a bar.
      mkdir -p "$dir/sessions" || exit 0
      printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$server" "$task" "$fexp" >> "$dir/sessions/$sid.follow"
      relay_ensure "$sid" register
      exit 0
    fi
    # BT20: the id of what this session just wrote, so the relay can drop a notice about the session's own report.
    own=$(printf '%s' "$resp" | grep -oE '\\*"id\\*" *: *\\*"[A-Za-z0-9_-]{1,64}' | head -n 1 | sed -E 's/.*"([A-Za-z0-9_-]+)$/\1/')
    flag=B
    if [ "$kind" = report ] && printf '%s' "$args" | grep -Eq '"status" *: *"done"'; then flag=D; fi
    mkdir -p "$dir/sessions" || exit 0
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$server" "$task" "$flag" >> "$dir/sessions/$sid.bind"
    if [ -n "$own" ]; then
      printf '%s\n' "$own" >> "$dir/sessions/$sid.own"
      if [ "$(wc -l < "$dir/sessions/$sid.own")" -gt 260 ]; then
        tail -n 200 "$dir/sessions/$sid.own" > "$dir/sessions/$sid.own.tmp.$$" && mv -f "$dir/sessions/$sid.own.tmp.$$" "$dir/sessions/$sid.own"
      fi
    fi
    relay_ensure "$sid" register
    exit 0
    ;;
esac

# Nothing bound in this session: nothing to send. A session that only follows still gets its relay (BT18), but never a check-in.
if [ ! -s "$dir/sessions/$sid.bind" ]; then
  { [ -s "$dir/sessions/$sid.follow" ] || [ -s "$dir/sessions/$sid.jobs" ] || [ -s "$dir/sessions/$sid.watches" ]; } && relay_ensure "$sid"
  exit 0
fi
relay_ensure "$sid"
now=$(date +%s) || exit 0
# The stamp holds the epoch of the last check-in, so no find (Windows has its own) is involved.
last=0
read -r last < "$dir/stamps/$sid" || last=0
case $last in ''|*[!0-9]*) last=0 ;; esac
if [ $((now - last)) -lt 300 ]; then exit 0; fi
mkdir -p "$dir/stamps" || exit 0
printf '%s\n' "$now" > "$dir/stamps/$sid"
if [ "${MIND_CHECKIN_FOREGROUND:-}" = 1 ]; then
  sh "$here/mind-checkin" send "$sid" </dev/null
else
  ( sh "$here/mind-checkin" send "$sid" </dev/null >/dev/null 2>&1 & )
fi
exit 0
