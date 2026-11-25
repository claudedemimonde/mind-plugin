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
#   - run with the argument `stop` (the Stop hook, a turn ended): first the ask check (IG11: a turn that asks a person something but posted nothing to the Mind
#     is blocked ONCE, JSON on fd 3), else only restart a dead relay (BT16).
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
  case $_rp in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$_rp" 2>/dev/null; then
        # PP20 b2: a relay that runs another install than the installed one (no relays/KEY.gen = one that predates the gen, or an older gen) is
        # told to stop, ONCE: its sh runs the TERM trap only when the curl or sleep it waits for ends (up to a minute), so this call neither waits
        # nor starts the new one; relays/KEY.replacing (epoch) holds further TERMs off for 60 s, and the first hook call after the old relay has
        # exited starts the new one (the dead pid is simply ignored; the start lock keeps parallel hooks to one relay). A relay writes its gen
        # before its pid, so a live pid with no gen is an old relay, never a new one. No installed gen (a checkout, a test): nothing to compare.
        _ig=; _rg=
        [ -f "$dir/bin/.plugin-gen" ] && read -r _ig < "$dir/bin/.plugin-gen"
        [ -f "$dir/relays/$_rk.gen" ] && read -r _rg < "$dir/relays/$_rk.gen"
        if [ -z "$_ig" ] || [ "$_rg" = "$_ig" ]; then return 0; fi
        _tt=0
        [ -f "$dir/relays/$_rk.replacing" ] && read -r _tt < "$dir/relays/$_rk.replacing"
        case $_tt in ''|*[!0-9]*) _tt=0 ;; esac
        _tn=$(date +%s) || return 0
        [ $((_tn - _tt)) -ge 60 ] || return 0
        # Only a process that is this socket's relay is signalled, never an unrelated one that reused the pid.
        _pa=$(ps -o args= -p "$_rp" 2>/dev/null)
        case $_pa in *mind-relay*" $_rk"*) ;; *) return 0 ;; esac
        printf '%s\n' "$_tn" > "$dir/relays/$_rk.replacing"
        kill -TERM "$_rp" 2>/dev/null
        return 0
      fi
      ;;
  esac
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
  # 3>&-: the Stop hook has Claude Code's stdout on fd 3 (IG11); a relay that kept it open would make Claude Code wait for it.
  ( sh "$here/mind-relay" "$_rk" "$_cp" </dev/null >/dev/null 2>&1 3>&- & )
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
# PP20 a: a subagent's tool call carries "agent_id" in the input. A wake reaches only the top-level session, so a subagent's watch or job
# reply is not noted (the subagent runs `mind-checkin wait` instead). The field's place in the input is not known (assumed, not
# captured), so the whole input is searched; the match needs the unescaped quote pair of a key, so text a tool carries (its quotes are
# escaped inside a string) cannot pose as one.
sub=
case $(printf '%s' "$prefix" | grep -Ec '"agent_id" *: *"') in 0) ;; *) sub=1 ;; esac
# The socket's relays/KEY.watches holds this session's open watches (PP20 a); the key is the one relay_ensure cached for the session.
keyed_watches() {
  _kk=
  [ -f "$dir/sessions/$1.rk" ] && read -r _kk _ < "$dir/sessions/$1.rk"
  case $_kk in ''|*[!0-9]*) return 1 ;; esac
  [ -s "$dir/relays/$_kk.watches" ]
}

# IG11 - the Stop hook asks once. A turn that ends on a question to the person ("last_assistant_message" asks something) with nothing posted to the
# Mind this turn is blocked from ending ONCE: {"decision":"block","reason":...} on fd 3 (the shim's stdout; the hook's own stdout is /dev/null), exit 0.
# Skipped, silently, when: the input says stop_hook_active (so it cannot loop) or carries an agent_id (a subagent); there is no
# CLAUDE_CODE_MESSAGING_SOCKET (a headless `claude -p` job); fd 3 is not open (an older shim sent stop's stdout to /dev/null); no origin names a server;
# the message asks nothing; or a Mind tool was used this turn (sessions/<id>.asked-at, written by asked_note below, is newer than the previous Stop).
# POSIX sh and awk, no network, 2 s between steps; any failure returns 1 and the turn ends as it would have. $1 = session id. Returns 0 only when it blocked.
ask_check() {
  _as=$1
  [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] || return 1
  _t0=$(date +%s) || return 1
  # The previous Stop: the larger of the relay's idle stamp and this check's own (the relay key needs a bound session; ours does not).
  _prev=0; _rk=
  [ -f "$dir/sessions/$_as.rk" ] && read -r _rk _ < "$dir/sessions/$_as.rk"
  case $_rk in ''|*[!0-9]*) ;; *) [ -f "$dir/relays/$_rk.idle-at" ] && read -r _prev < "$dir/relays/$_rk.idle-at" ;; esac
  case $_prev in ''|*[!0-9]*) _prev=0 ;; esac
  _so=0; [ -f "$dir/sessions/$_as.stop-at" ] && read -r _so < "$dir/sessions/$_as.stop-at"
  case $_so in ''|*[!0-9]*) _so=0 ;; esac
  [ "$_so" -le "$_prev" ] || _prev=$_so
  mkdir -p "$dir/sessions" 2>/dev/null && printf '%s\n' "$_t0" > "$dir/sessions/$_as.stop-at" 2>/dev/null
  # Never twice in a row, whatever the input says: a block leaves sessions/<id>.blocked, and the next Stop (the end of the turn that
  # block made) only removes it. stop_hook_active says the same; this does not depend on reading it.
  if [ -e "$dir/sessions/$_as.blocked" ]; then rm -f "$dir/sessions/$_as.blocked"; return 1; fi
  { true >&3; } 2>/dev/null || return 1
  set -- "$dir"/origins/*/servers
  [ -f "$1" ] || return 1
  _in=$(printf '%s' "$input" | head -c 262144)
  case $(printf '%s' "$_in" | grep -Ec '"stop_hook_active" *: *true|"agent_id" *: *"') in 0) ;; *) return 1 ;; esac
  # The message: a JSON string, cut at its closing quote and unescaped; fenced code, quoted lines and inline code are dropped; then the
  # last paragraph is asked "does a sentence end in ?" and the whole text "does it hold one of the phrases".
  _ask=$(printf '%s' "$_in" | awk '
    BEGIN { RS = "\001" }
    NR == 1 {
      k = index($0, "\"last_assistant_message\"")
      if (k == 0) exit 1
      s = substr($0, k + 24)
      if (!match(s, /^ *: *"/)) exit 1
      rest = substr(s, RLENGTH + 1); msg = ""; found = 0
      while ((q = index(rest, "\"")) > 0) {
        pre = substr(rest, 1, q - 1)
        b = 0; j = length(pre)
        while (j > 0 && substr(pre, j, 1) == "\\") { b++; j-- }
        msg = msg pre
        if (b % 2 == 0) { found = 1; break }
        msg = msg "\""
        rest = substr(rest, q + 1)
      }
      if (!found) exit 1
      gsub(/\\\\/, "\001", msg); gsub(/\\n/, "\n", msg); gsub(/\\r/, "", msg); gsub(/\\t/, " ", msg)
      gsub(/\\"/, "\"", msg); gsub(/\\\//, "/", msg); gsub(/\001/, "\\", msg)
      n = split(msg, L, "\n"); fence = 0; para = ""; last = ""; kept = ""
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; continue }
        if (fence) continue
        if (line ~ /^[ \t]*>/) continue
        gsub(/`[^`]*`/, "", line)
        kept = kept line "\n"
        if (line ~ /^[ \t]*$/) { if (para != "") last = para; para = "" } else para = para " " line
      }
      if (para != "") last = para
      ph = "(^|[^a-z])(needs you|waiting for you|can you|could you|should i|do you want|your call|let me know)([^a-z]|$)"
      qm = "\\?([] \t)\"\047*_]|$)"
      if (tolower(last) ~ qm || tolower(kept) ~ ph) print "ask"
      exit 0
    }' 2>/dev/null)
  [ "$_ask" = ask ] || return 1
  [ $(( $(date +%s) - _t0 )) -lt 2 ] || return 1
  # Marked asked this turn: a stamp newer than the previous Stop. With no previous Stop known, only a recent stamp counts (a resumed session's old one does not).
  _aa=0; [ -f "$dir/sessions/$_as.asked-at" ] && read -r _aa < "$dir/sessions/$_as.asked-at"
  case $_aa in ''|*[!0-9]*) _aa=0 ;; esac
  _this=
  if [ "$_aa" -gt "$_prev" ]; then
    if [ "$_prev" -gt 0 ] || [ $((_t0 - _aa)) -lt 21600 ]; then _this=1; fi
  fi
  [ -z "$_this" ] || return 1
  printf '%s\n' '{"decision":"block","reason":"You asked a person something but posted nothing to the Mind. Post it with raise_decision: kind decide (with options) or do, impact blocked | slowed | nice, goalId = the task of the goal you work on. If the person is chatting with you right now, pass revealAfterMinutes: 15 and withdraw it if they answer here. If you have no Mind tools, say so in one line. Then end the turn."}' >&3 || return 1
  : > "$dir/sessions/$_as.blocked" 2>/dev/null
  return 0
}

# The Stop hook (`sh mind-checkin-hook.sh stop`, run when a turn ends): a session that ended its turn to wait would otherwise lose its
# relay for good, because only a later tool call restarts it. Cheap: no network unless the relay is started; prints nothing.
if [ "$mode" = watch ]; then
  relay_ensure "$sid" register
  exit 0
fi
if [ "$mode" = stop ]; then
  # IG11: a block is printed on fd 3 and ends this hook: the relay is proven and restarted by the next Stop.
  ask_check "$sid" && exit 0
  relay_prove "$sid"
  relay_stamp idle
  [ -s "$dir/sessions/$sid.bind" ] || [ -s "$dir/sessions/$sid.follow" ] || [ -s "$dir/sessions/$sid.jobs" ] || [ -s "$dir/sessions/$sid.watches" ] || keyed_watches "$sid" || exit 0
  relay_ensure "$sid"
  exit 0
fi
relay_prove "$sid"
relay_stamp busy

# IG11 - the ask check's proof that the session posted: `sessions/<id>.asked-at` (epoch) when this tool call put something to the Mind - a Mind tool
# (raise_decision, wait_for_decisions, watch, request_work, request_test_run, request_experiment) whose reply is not an error, a Bash
# `mind-checkin watch`, or a REPL call whose input names one of those tools (REPL sessions record MCP calls under REPL). A subagent's call counts too.
asked_note() {
  case $tool in
    mcp__*__raise_decision|mcp__*__wait_for_decisions|mcp__*__watch|mcp__*__request_work|mcp__*__request_test_run|mcp__*__request_experiment|Bash|REPL) ;;
    *) return 0 ;;
  esac
  _ar=${prefix#*'"tool_input"'}
  [ "$_ar" != "$prefix" ] || return 0
  _aargs=${_ar%%'"tool_response"'*}
  _aresp=${_ar#*'"tool_response"'}
  case $tool in
    Bash) printf '%s' "$_aargs" | sed -e 's/\\"//g' -e 's/\\t/ /g' | grep -Eq 'mind-checkin[A-Za-z0-9_./~-]*[[:space:]]+watch([^A-Za-z0-9_-]|$)' || return 0 ;;
    REPL) printf '%s' "$_aargs" | grep -Eq -e 'mcp__[A-Za-z0-9_-]*__(raise_decision|wait_for_decisions|watch|request_work|request_test_run|request_experiment)([^A-Za-z0-9_]|$)' -e '(^|[^A-Za-z0-9_])(raise_decision|wait_for_decisions|request_work|request_test_run|request_experiment)([^A-Za-z0-9_]|$)' || return 0 ;;
    *) if [ "$_aresp" != "$_ar" ] && printf '%s' "$_aresp" | grep -Eq '"is_?[Ee]rror" *: *true'; then return 0; fi ;;
  esac
  mkdir -p "$dir/sessions" || return 0
  date +%s > "$dir/sessions/$sid.asked-at.tmp.$$" && mv -f "$dir/sessions/$sid.asked-at.tmp.$$" "$dir/sessions/$sid.asked-at"
  return 0
}
asked_note

# BT23 - job results wake the session. The reply of request_work / request_test_run / request_experiment names the job ids; one group line
# `J <writtenEpoch> <jobId>...` goes to the session's own sessions/<id>.jobs (append only: the relay appends `D <jobId>` to the same file,
# it never rewrites it). The ids come from the REPLY, never from the input (a model's own words), and only for a server an origin names,
# so a local Mind's job id is never polled on the hosted one. A repeat (`created: false`) whose ids a line already holds writes nothing.
# A request is also a tool call: this only notes the job, and the hook goes on to the normal check-in path below (a bound session still checks in).
jobs_note() {
  [ -z "$sub" ] || return 0
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

# BT30 - a `watch` reply: `W <writtenEpoch> <watchId>` to the socket's relays/KEY.watches (PP20 a; sessions/<id>.watches when there is no socket;
# append only, the relay appends `D <watchId>`). Like the J line, the id comes from the REPLY, never the input, for a server an origin names.
# A repeat (`created: false`) of an id the file already holds writes nothing.
watch_note() {
  [ -z "$sub" ] || return 0
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
  wf="$dir/sessions/$sid.watches"
  if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
    wk=$(printf '%s' "$CLAUDE_CODE_MESSAGING_SOCKET" | cksum); wk=${wk%% *}
    wf="$dir/relays/$wk.watches"
  fi
  mkdir -p "${wf%/*}" || return 0
  grep -Eq "^W [0-9]+ $wid\$" "$wf" 2>/dev/null && return 0
  printf 'W %s %s\n' "$(date +%s)" "$wid" >> "$wf" || return 0
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
  { [ -s "$dir/sessions/$sid.follow" ] || [ -s "$dir/sessions/$sid.jobs" ] || [ -s "$dir/sessions/$sid.watches" ] || keyed_watches "$sid"; } && relay_ensure "$sid"
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
  ( sh "$here/mind-checkin" send "$sid" </dev/null >/dev/null 2>&1 3>&- & )
fi
exit 0
