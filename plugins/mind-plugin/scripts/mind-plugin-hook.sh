#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# The plugin's hook entry (the design doc's Build rule BT26, "The hook keeps one stable install"). Claude Code runs it for
# PostToolUse (`post`) and Stop (`stop`). It keeps ONE install of the four check-in files in ~/.config/mind/bin, so
# `status`, `login`, `link`, the relay and every doc path keep the one path they have. The install is keyed on CONTENT, not on the
# plugin folder (that changes with every merge, and two sessions on different versions would copy over each other):
# scripts/.files-gen holds "<gen> <cksum> <size>" of the four files, bin/.plugin-gen holds what was installed.
#   - same value, all four files there: nothing to do (the fast path: two reads and a test)
#   - the plugin's gen is NEWER, a file is missing, or bin/.plugin-gen says `connect-line` (a connect-line run overwrote
#     the files): copy. An OLDER plugin never overwrites a newer install.
# After a copy it runs `mind-checkin link` (local, no network) so the plugin's MCP server name is linked, then hands the same
# input to the installed hook. Prints nothing and always exits 0: a failed copy only means the installed hook runs as it is.
exec >/dev/null 2>&1
umask 077
dir="${MIND_CHECKIN_DIR:-$HOME/.config/mind}"
bin="$dir/bin"
# Where the plugin's files are: its own root when Claude Code sets it (a Windows path becomes a Git Bash path), else beside this script.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  src="$CLAUDE_PLUGIN_ROOT/scripts"
  case $CLAUDE_PLUGIN_ROOT in *\\*) src=$(cygpath -u "$CLAUDE_PLUGIN_ROOT" 2>/dev/null)/scripts ;; esac
else
  src=${0%/*}
fi
FILES="mind-checkin mind-checkin-settings.awk mind-relay mind-checkin-hook.sh" # the hook last

have=; want=
[ -f "$bin/.plugin-gen" ] && read -r have < "$bin/.plugin-gen"
[ -f "$src/.files-gen" ] && read -r want < "$src/.files-gen"
want=${want:-0 0 0}

# need_copy: 0 when this plugin should install its files now.
need_copy() {
  [ -f "$bin/mind-checkin" ] && [ -f "$bin/mind-checkin-settings.awk" ] && [ -f "$bin/mind-relay" ] && [ -f "$bin/mind-checkin-hook.sh" ] || return 0
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
        MIND_CHECKIN_DIR="$dir" sh "$bin/mind-checkin" link --url "${MIND_URL:-https://mind.wideopen.dev}" </dev/null
      fi
      rmdir "$lock" 2>/dev/null
    fi
  elif [ $((now - fail)) -ge 60 ]; then
    printf '%s\n' "$now" > "$bin/.plugin-fail" # the bin folder cannot be made; this fails quietly too
  fi
fi

[ -f "$bin/mind-checkin-hook.sh" ] || exit 0
if [ "${1:-}" = stop ]; then exec sh "$bin/mind-checkin-hook.sh" stop; fi
exec sh "$bin/mind-checkin-hook.sh"
exit 0
