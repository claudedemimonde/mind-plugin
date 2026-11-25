#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# The plugin's hook entry (the design doc's Build rule BT26, "The hook keeps one stable install"). Claude Code runs it for
# PostToolUse (`post`), Stop (`stop`), PreToolUse on Bash (`pre`, PP20 c) and SessionStart (`session-start`, PP20 c). It keeps ONE install of the five check-in
# files in ~/.config/mind/bin, so
# `status`, `login`, `link`, the relay and every doc path keep the one path they have. The install is keyed on CONTENT, not on the
# plugin folder (that changes with every merge, and two sessions on different versions would copy over each other):
# scripts/.files-gen holds "<gen> <cksum> <size>" of the five files, bin/.plugin-gen holds what was installed.
#   - same value, all five files there: nothing to do (the fast path: two reads and a test)
#   - the plugin's gen is NEWER, a file is missing, or bin/.plugin-gen says `connect-line` (a connect-line run overwrote
#     the files): copy. An OLDER plugin never overwrites a newer install.
# After a copy it runs `mind-checkin link` (local, no network) so the plugin's MCP server name is linked, then hands the same
# input to the installed hook. Prints nothing and always exits 0: a failed copy only means the installed hook runs as it is.
#   - `pre` writes relays/<key>.hook-at (the epoch; key = the cksum of the session's socket, as everywhere) FIRST, before any early exit: it is the
#     proof, read by `mind-checkin watch` and `doctor`, that the plugin's hooks run in this session. It copies nothing and denies
#     `mind-checkin watch` from a subagent (a wake reaches only the top-level session).
#   - `session-start` (startup, resume, clear, compact) stamps hook-at too, copies like `post`, then runs `mind-checkin doctor --brief` and prints
#     {"systemMessage", "hookSpecificOutput":{"additionalContext"}} only when a check failed.
#   - `stop` (IG11) keeps fd 3 too: the installed hook's ask check may print {"decision":"block",...} there. That hook closes fd 3 for every relay it starts.
#     A hook of another gen could keep it open for a relay and Claude Code waits for the hook's stdout to close, so the exec below closes fd 3 unless
#     the installed hook is this plugin's gen or newer.
# fd 3 (Claude Code's stdout) is opened only for the three modes that print: a fd left open would be inherited by the detached relay the post
# mode starts, and Claude Code waits for the hook's stdout to close.
case ${1:-} in pre|session-start|stop) exec 3>&1 >/dev/null 2>&1 ;; *) exec >/dev/null 2>&1 ;; esac
umask 077
dir="${MIND_CHECKIN_DIR:-$HOME/.config/mind}"
bin="$dir/bin"
mode=${1:-}

# PP20 c: the stamp, before anything else can exit.
if [ "$mode" = pre ] || [ "$mode" = session-start ]; then
  if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
    _k=$(printf '%s' "$CLAUDE_CODE_MESSAGING_SOCKET" | cksum); _k=${_k%% *}
    case $_k in ''|*[!0-9]*) ;; *) mkdir -p "$dir/relays" && date +%s > "$dir/relays/$_k.hook-at.tmp.$$" && mv -f "$dir/relays/$_k.hook-at.tmp.$$" "$dir/relays/$_k.hook-at" ;; esac
  fi
fi
if [ "$mode" = pre ]; then
  input=$(cat) || exit 0
  case $input in *mind-checkin*watch*) ;; *) exit 0 ;; esac
  # A subagent's input carries "agent_id" (matched as a key, with its unescaped quotes: a command that merely mentions it cannot match) and
  # a `mind-checkin watch` command (not watches).
  printf '%s' "$input" | head -c 65536 | grep -Eq '"agent_id" *: *"' || exit 0
  # The command is a JSON string: \" (a quoted path) is dropped and \t is a space before matching `mind-checkin <anything> watch`, so
  # "/path/mind-checkin" watch, ./scripts/mind-checkin<TAB>watch and $(mind-checkin watch ...) are all caught; `watches` is not.
  printf '%s' "$input" | head -c 65536 | sed -e 's/\\"//g' -e 's/\\t/ /g' | grep -Eq 'mind-checkin[A-Za-z0-9_./~-]*[[:space:]]+watch([^A-Za-z0-9_-]|$)' || exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"A subagent cannot be woken by a Mind watch: a wake reaches only the top-level session. Set the watch with the Mind watch tool, then run %s/bin/mind-checkin wait <watchId> in the background, or leave the watch to the top-level session."}}\n' "$(printf '%s' "$dir" | tr -d '"\\')" >&3
  exit 0
fi
# Where the plugin's files are: its own root when Claude Code sets it (a Windows path becomes a Git Bash path), else beside this script.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  src="$CLAUDE_PLUGIN_ROOT/scripts"
  case $CLAUDE_PLUGIN_ROOT in *\\*) src=$(cygpath -u "$CLAUDE_PLUGIN_ROOT" 2>/dev/null)/scripts ;; esac
else
  src=${0%/*}
fi
FILES="mind-checkin mind-checkin-settings.awk mind-relay mind-launcher mind-checkin-hook.sh" # the hook last

have=; want=
[ -f "$bin/.plugin-gen" ] && read -r have < "$bin/.plugin-gen"
[ -f "$src/.files-gen" ] && read -r want < "$src/.files-gen"
want=${want:-0 0 0}

# need_copy: 0 when this plugin should install its files now.
need_copy() {
  [ -f "$bin/mind-checkin" ] && [ -f "$bin/mind-checkin-settings.awk" ] && [ -f "$bin/mind-relay" ] && [ -f "$bin/mind-launcher" ] && [ -f "$bin/mind-checkin-hook.sh" ] || return 0
  [ "$have" = "$want" ] && return 1
  _hg=${have%% *}; _wg=${want%% *}
  case $_hg in ''|*[!0-9]*) return 0 ;; esac # connect-line, or an unreadable record
  case $_wg in ''|*[!0-9]*) return 1 ;; esac
  [ "$_wg" -gt "$_hg" ] # newer only; the same gen with other sums is a conflict, left alone
}

if need_copy; then
  copied=
  now=$(date +%s)
  fail=0
  [ -f "$bin/.plugin-fail" ] && read -r fail < "$bin/.plugin-fail"
  case $fail in ''|*[!0-9]*) fail=0 ;; esac
  # A failed copy is tried again at most once a minute.
  if [ $((now - fail)) -ge 60 ] && mkdir -p "$bin" 2>/dev/null; then
    lock="$bin/.plugin-lock"
    if ! mkdir "$lock" 2>/dev/null; then
      # A claim older than a minute belongs to a copy that died. One shim at a time may take it over (the .take claim), and it
      # looks at the age again once it holds that, so it never removes a lock another shim has just taken.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && mkdir "$lock.take" 2>/dev/null; then
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$lock"; mkdir "$lock" 2>/dev/null || lock=; else lock=; fi
        rmdir "$lock.take" 2>/dev/null
      else
        [ -n "$(find "$lock.take" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$lock.take" 2>/dev/null
        lock=
      fi
    fi
    if [ -n "$lock" ]; then
      # Another shim may have finished while this one looked: look again under the lock.
      have=; [ -f "$bin/.plugin-gen" ] && read -r have < "$bin/.plugin-gen"
      if need_copy; then
        find "$bin" -maxdepth 1 -name '*.tmp.*' -mmin +1 -exec rm -f {} + 2>/dev/null # what a killed copy left
        ok=1
        for f in $FILES; do
          # Written to a temp name and moved over the old file: a running sh keeps reading the old one.
          if cp "$src/$f" "$bin/$f.tmp.$$" && chmod 755 "$bin/$f.tmp.$$" && mv -f "$bin/$f.tmp.$$" "$bin/$f"; then :; else rm -f "$bin/$f.tmp.$$"; ok=; break; fi
        done
        if [ -n "$ok" ] && printf '%s\n' "$want" > "$bin/.plugin-gen.tmp.$$" && mv -f "$bin/.plugin-gen.tmp.$$" "$bin/.plugin-gen"; then
          copied=1; rm -f "$bin/.plugin-fail"
        else
          rm -f "$bin/.plugin-gen.tmp.$$"; printf '%s\n' "$now" > "$bin/.plugin-fail"
        fi
      fi
      # Local, no network: puts the plugin's MCP server name (plugin_mind-plugin_mind) in origins/*/servers, or the hook would
      # drop every report as unlinked. Inside the lock, so a second shim never sees new files before the link is done. Not
      # signed in yet: it fails quietly, and `login` finds the name itself.
      if [ -n "$copied" ]; then
        MIND_CHECKIN_DIR="$dir" sh "$bin/mind-checkin" link --url "${MIND_URL:-https://mind.wideopen.dev}" </dev/null 3>&-
      fi
      rmdir "$lock" 2>/dev/null
    fi
  elif [ $((now - fail)) -ge 60 ]; then
    printf '%s\n' "$now" > "$bin/.plugin-fail" # the bin folder cannot be made; this fails quietly too
  fi
fi

if [ "$mode" = session-start ]; then
  # Quiet when all is well. Otherwise one JSON object: systemMessage is shown to the person, additionalContext goes to the model (the model is
  # told what to do about a watch until the person has fixed it). The doctor's lines are escaped into one JSON string each.
  [ -f "$bin/mind-checkin" ] || exit 0
  report=$(MIND_CHECKIN_DIR="$dir" sh "$bin/mind-checkin" doctor --brief </dev/null 2>/dev/null) || exit 0
  [ -n "$report" ] || exit 0
  esc=$(printf '%s' "$report" | tr '\011\015' '  ' | tr -d '\000-\010\013\014\016-\037\177' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
  fixhint="Run $(printf '%s' "$bin" | tr -d '"\\')/mind-checkin doctor for the full list."
  # Only a fault that breaks wakes (1 not signed in, 2 no plugin, 6 hooks not running) tells the model not to rely on watch; the others are setup notes.
  advice=
  if printf '%s\n' "$report" | grep -Eq '^!! +(1|2|6) '; then
    advice=" Until they are fixed do not rely on mind-checkin watch or the Mind watch tool to wake this session: run mind-checkin wait <watchId> in the background instead."
  fi
  printf '{"systemMessage":"Mind setup problem on this computer:\\n%s\\n%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"The Mind plugin found setup problems on this computer. Tell the person, briefly.%s\\n%s"}}\n' "$esc" "$fixhint" "$advice" "$esc" >&3
  exit 0
fi
[ -f "$bin/mind-checkin-hook.sh" ] || exit 0
if [ "${1:-}" = stop ]; then
  # IG11: fd 3 goes only to a hook of this plugin's gen or newer (the ask check and its `3>&-` on every relay start came together).
  have=; [ -f "$bin/.plugin-gen" ] && read -r have < "$bin/.plugin-gen"
  _hg=${have%% *}; _wg=${want%% *}
  case $_hg$_wg in *[!0-9]*|'') exec 3>&- ;; *) [ "$_hg" -ge "$_wg" ] || exec 3>&- ;; esac
  exec sh "$bin/mind-checkin-hook.sh" stop
fi
exec sh "$bin/mind-checkin-hook.sh"
exit 0
