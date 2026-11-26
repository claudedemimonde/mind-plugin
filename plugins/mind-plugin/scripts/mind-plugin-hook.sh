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
#   - `session-start` on macOS also writes the SJ4 session record (~/.config/mind/sessions/<session_id>), read by the launcher's focus line (SJ8).
#   - `mind-tool` (SJ1, PreToolUse on the Mind's tools that take `session`) keeps fd 3 and answers there with the tool input plus the real
#     `session`; it exits before the copy step below and before the installed hook, and never fails a call.
#   - `stop` (IG11) keeps fd 3 too: the installed hook's ask check may print {"decision":"block",...} there. That hook closes fd 3 for every relay it starts.
#     A hook of another gen could keep it open for a relay and Claude Code waits for the hook's stdout to close, so the exec below closes fd 3 unless
#     the installed hook is this plugin's gen or newer.
# fd 3 (Claude Code's stdout) is opened only for the four modes that print: a fd left open would be inherited by the detached relay the post
# mode starts, and Claude Code waits for the hook's stdout to close.
case ${1:-} in pre|session-start|stop|mind-tool) exec 3>&1 >/dev/null 2>&1 ;; *) exec >/dev/null 2>&1 ;; esac
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
# SJ4: `session-start` also writes this session's local record, $dir/sessions/<session_id> (macOS only), which the launcher reads when the
# person presses "Open terminal" in the Mind. `key=value` lines, each value checked against a strict alphabet before it is written; a value that
# fails is left out. Nothing in it leaves this Mac. Records older than 30 days are removed on each write. The shim stays POSIX sh + sed; it never
# fails the hook (every step is allowed to give up quietly).
sj_path_ok() { # absolute, no control character (bytes above 0x7f are fine), at most 1000 bytes
  case $1 in /*) ;; *) return 1 ;; esac
  [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -le 1000 ] || return 1
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177' | wc -c | tr -d ' ')" = "$(printf '%s' "$1" | wc -c | tr -d ' ')" ]
}
sj_uuid_ok() { case $1 in ????????-????-????-????-????????????) ;; *) return 1 ;; esac; case $1 in *[!0-9A-Fa-f-]*) return 1 ;; esac; return 0; }
sj_record() {
  [ ! -t 0 ] || return 0
  _in=$(head -c 65536) || return 0
  _sid=$(printf '%s' "$_in" | sed -n 's/.*"session_id" *: *"\([0-9A-Fa-f-]\{36\}\)".*/\1/p' | head -n 1 | tr 'A-F' 'a-f')
  sj_uuid_ok "$_sid" || return 0
  _cwd=$(printf '%s' "$_in" | sed -n 's/.*"cwd" *: *"\(\/[^"\\]*\)".*/\1/p' | head -n 1)
  # The hook's parent process is Claude Code; a wrapper shell between them (sh -c) is stepped over, at most twice. The process NAME is never
  # a test of liveness (the native binary's command is its version number, an npm install's is node), only this walk uses it.
  _pid=$PPID; _i=0
  while [ "$_i" -lt 2 ]; do
    _c=$(ps -o comm= -p "$_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'); _c=${_c##*/}
    case $_c in sh|bash|zsh|dash|-sh|-bash|-zsh) ;; *) break ;; esac
    _pp=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    case $_pp in ''|*[!0-9]*|0|1) break ;; esac
    _pid=$_pp; _i=$((_i + 1))
  done
  case $_pid in ''|*[!0-9]*) _pid= ;; esac
  _start=; _tty=
  if [ -n "$_pid" ]; then
    # LC_ALL=C: lstart is written in the locale (de_DE: "Mi. 25 Nov."), and the launcher compares it under LC_ALL=C.
    _start=$(LC_ALL=C ps -o lstart= -p "$_pid" 2>/dev/null | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
    case $_start in ''|*[!A-Za-z0-9': ']*) _start= ;; esac
    [ ${#_start} -le 40 ] || _start=
    _tty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    case $_tty in ttys[0-9]*) case ${_tty#ttys} in *[!0-9]*) _tty= ;; esac ;; *) _tty= ;; esac
    [ ${#_tty} -le 12 ] || _tty=
  fi
  case ${TERM_PROGRAM:-} in iTerm.app) _app=iterm ;; Apple_Terminal) _app=apple ;; vscode) _app=vscode ;; *) _app=other ;; esac
  _iterm=${ITERM_SESSION_ID#*:}
  case ${ITERM_SESSION_ID:-} in *:*) sj_uuid_ok "$_iterm" || _iterm= ;; *) _iterm= ;; esac
  _pane=${TMUX_PANE:-}
  case $_pane in %[0-9]*) case ${_pane#%} in *[!0-9]*) _pane= ;; esac ;; *) _pane= ;; esac
  _tsock=${TMUX:-}; _tsock=${_tsock%%,*}
  [ -n "$_pane" ] && sj_path_ok "$_tsock" || { _pane=; _tsock=; }
  _sock=${CLAUDE_CODE_MESSAGING_SOCKET:-}
  sj_path_ok "$_sock" || _sock=
  sj_path_ok "$_cwd" || _cwd=
  _d="$dir/sessions"
  mkdir -p "$_d" 2>/dev/null && chmod 700 "$_d" 2>/dev/null || return 0
  _tmp="$_d/.$_sid.$$"
  {
    [ -z "$_sock" ] || printf 'sock=%s\n' "$_sock"
    [ -z "$_pid" ] || [ -z "$_start" ] || printf 'pid=%s\nstart=%s\n' "$_pid" "$_start"
    [ -z "$_tty" ] || printf 'tty=%s\n' "$_tty"
    printf 'app=%s\n' "$_app"
    [ -z "$_iterm" ] || printf 'iterm=%s\n' "$_iterm"
    [ -z "$_pane" ] || printf 'tmux=%s\ntmuxsock=%s\n' "$_pane" "$_tsock"
    [ -z "$_cwd" ] || printf 'cwd=%s\n' "$_cwd"
    printf 'at=%s\n' "$(date +%s)"
  } > "$_tmp" 2>/dev/null && chmod 600 "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_d/$_sid" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  find "$_d" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
  return 0
}
if [ "$mode" = session-start ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then sj_record; fi
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
# SJ1: `mind-tool` (PreToolUse on the Mind's own tools that take `session`) fills in `session: {name, id}` with the REAL Claude Code
# session, so a to-do / decision shows which session raised it, and withdraw / reveal can prove it. It answers
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":<tool_input with session>}} on fd 3, with no permissionDecision (the
# person's own permission rules still apply). It copies nothing, never blocks and never fails a call: any doubt prints nothing, so the
# call goes through unchanged. POSIX sh + awk only (no jq, no node); the awk runs in the C locale, so it works in bytes.
if [ "$mode" = mind-tool ]; then
  # The tools whose input schema has `session: SESSION_ARG`. mcp/src/test/sessionHookDrift.test.ts fails when this list or the matcher in
  # hooks.json differs from the MCP registrations.
  MIND_SESSION_TOOLS="add_mockup attach_decision_writeup comment_on_criterion propose_criterion_change propose_system_change propose_tree_change raise_decision report report_criterion_progress reveal_decision set_criterion_position set_required_roles submit_spec wait_for_decisions withdraw_decision withdraw_proposal"
  input=$(head -c 262145) || exit 0
  [ "$(printf '%s' "$input" | wc -c)" -le 262144 ] || exit 0 # over 256 KB
  # The scanner: depth-1 members of a JSON object, string-aware. load(s) splits s into the byte array C once (a substr per byte is
  # O(length) in macOS awk, so a 256 KB input would take seconds); members(i) then fills KS / KE (raw key start / end), MS / ME (value
  # start / end) and MN, and returns the index of the closing brace, or 0 when the text is not an object it understands.
  _lib='function load(s){NC=split(s,C,"");return NC}
function ws(i,  c){while(i<=NC){c=C[i];if(c==" "||c=="\t"||c=="\n"||c=="\r")i++;else break}return i}
function skipstr(i,  c){i++;while(i<=NC){c=C[i];if(c=="\\")i+=2;else if(c=="\"")return i+1;else i++}return 0}
function skipval(i,  c,d,j){c=C[i]
  if(c=="\"")return skipstr(i)
  if(c=="{"||c=="["){d=0;while(i<=NC){c=C[i]
    if(c=="\""){i=skipstr(i);if(!i)return 0;continue}
    if(c=="{"||c=="[")d++;else if(c=="}"||c=="]"){d--;if(d==0)return i+1}
    i++}return 0}
  j=i;while(j<=NC){c=C[j];if(c==","||c=="}"||c=="]"||c==" "||c=="\t"||c=="\n"||c=="\r")break;j++}
  return (j>i)?j:0}
function members(i,  c,e){MN=0
  if(C[i]!="{")return 0
  i=ws(i+1);if(C[i]=="}")return i
  while(i<=NC){if(C[i]!="\"")return 0
    e=skipstr(i);if(!e)return 0
    MN++;KS[MN]=i+1;KE[MN]=e-2
    i=ws(e);if(C[i]!=":")return 0
    i=ws(i+1);e=skipval(i);if(!e)return 0
    MS[MN]=i;ME[MN]=e-1
    i=ws(e);c=C[i]
    if(c==","){i=ws(i+1);continue}
    if(c=="}")return i
    return 0}return 0}
function keyesc(k,  j){for(j=KS[k];j<=KE[k];j++)if(C[j]=="\\")return 1;return 0}
function keyis(k,key,  j,L){L=length(key);if(KE[k]-KS[k]+1!=L)return 0;for(j=0;j<L;j++)if(C[KS[k]+j]!=substr(key,j+1,1))return 0;return 1}
function find(key,  k,f){f=0;for(k=1;k<=MN;k++)if(keyis(k,key)){if(f)return -1;f=k}return f}
function strval(s,k){if(C[MS[k]]!="\"")return "";return substr(s,MS[k]+1,ME[k]-MS[k]-1)}
function unesc(r,  o,p,c){o="";while((p=index(r,"\\"))>0){c=substr(r,p+1,1)
  if(c=="\\"||c=="/"||c=="\""){o=o substr(r,1,p-1) c}else{BAD=1;return ""}
  r=substr(r,p+2)}return o r}'
  # Stage A: the hook input's top-level session_id (a UUID), transcript_path and cwd, one per line; nothing for another tool.
  _a=$(printf '%s' "$input" | MIND_SESSION_TOOLS="$MIND_SESSION_TOOLS" LC_ALL=C awk "$_lib"'
BEGIN{RS="\001"}
NR==1{s=$0}
END{if(NR!=1)exit;load(s);if(!members(ws(1)))exit
  k=find("tool_name");if(k<=0)exit;t=strval(s,k)
  if(index(t,"mcp__plugin_mind-plugin_mind__")!=1)exit
  t=substr(t,31);if(index(" " ENVIRON["MIND_SESSION_TOOLS"] " "," " t " ")==0)exit
  k=find("session_id");if(k<=0)exit;sid=strval(s,k)
  if(sid !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/)exit
  tp="";k=find("transcript_path");if(k>0){BAD=0;tp=unesc(strval(s,k));if(BAD)tp=""}
  cwd="";k=find("cwd");if(k>0){BAD=0;cwd=unesc(strval(s,k));if(BAD)cwd=""}
  print tolower(sid);print tp;print cwd}') || exit 0
  [ -n "$_a" ] || exit 0
  { IFS= read -r sid; IFS= read -r tp; IFS= read -r cwd; } <<MIND_TOOL_EOF
$_a
MIND_TOOL_EOF
  # name_ok TEXT: 0 when TEXT is safe to send (no byte below 0x20 or 0x7f, no byte that UTF-8 never uses, at most 60 code points counted
  # by UTF-8 lead bytes, so never cut inside a sequence); prints it with " and \ escaped. Anything else: returns 1.
  name_ok() {
    [ -n "$1" ] || return 1
    _n1=$(printf '%s' "$1" | LC_ALL=C wc -c)
    _n2=$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177\300\301\370-\377' | LC_ALL=C wc -c)
    [ $_n1 -eq $_n2 ] || return 1
    _n3=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c)
    [ $_n3 -le 60 ] || return 1
    printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  }
  # The name: the folder name (the hook's cwd), else "Claude Code session"; then the title when there is one.
  case $cwd in [A-Za-z]:\\*) cwd=$(printf '%s' "$cwd" | tr '\\' '/') ;; esac # a Windows cwd: its last folder, not the whole path
  base=${cwd%"${cwd##*[!/]}"}; base=${base##*/}
  base=$(printf '%s' "$base" | LC_ALL=C sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')
  name=$(name_ok "$base") || name=
  [ -n "$name" ] || name="Claude Code session"
  # The title, RB1's order, read from the last 256 KB of the transcript only: the latest agent-name, else custom-title, else ai-title.
  case $tp in [A-Za-z]:*) tp=$(printf '%s' "$tp" | tr '\\' '/') ;; esac
  if [ "$(printf '%s' "${PM_SESSION_TITLE:-}" | tr 'A-Z' 'a-z')" != off ]; then
    case $tp in /*.jsonl|[A-Za-z]:/*.jsonl)
      if [ -f "$tp" ] && [ -r "$tp" ]; then
        _size=$(wc -c < "$tp" 2>/dev/null) || _size=0
        _cut=0; [ "$_size" -gt 262144 ] && _cut=1
        _t=$(tail -c 262144 "$tp" 2>/dev/null | MIND_CUT=$_cut LC_ALL=C awk "$_lib"'
function pick(ty,fld,  k,v){k=find("type");if(k<=0||strval($0,k)!=ty)return
  k=find(fld);if(k<=0)return;v=strval($0,k);BAD=0;v=unesc(v);if(BAD){T[ty]="\001";return}
  if(v !~ /[^ \t]/)return
  sub(/^[ \t]+/,"",v);sub(/[ \t]+$/,"",v);T[ty]=v}
NR==1&&ENVIRON["MIND_CUT"]=="1"{next}
index($0,"agent-name")||index($0,"custom-title")||index($0,"ai-title"){load($0);if(!members(ws(1)))next
  pick("agent-name","agentName");pick("custom-title","customTitle");pick("ai-title","aiTitle")}
END{v="";if(T["agent-name"]!="")v=T["agent-name"];else if(T["custom-title"]!="")v=T["custom-title"];else if(T["ai-title"]!="")v=T["ai-title"]
  if(v!="\001")print v}' 2>/dev/null) || _t=
        _t2=$(name_ok "$_t") && [ -n "$_t2" ] && name=$_t2
      fi ;;
    esac
  fi
  # Stage C: put the session in tool_input. Everything else in the input is copied byte for byte.
  _out=$(printf '%s' "$input" | MIND_NAME="$name" MIND_SID="$sid" LC_ALL=C awk "$_lib"'
BEGIN{RS="\001"}
NR==1{s=$0}
END{if(NR!=1)exit;load(s);if(!members(ws(1)))exit
  k=find("tool_input");if(k<=0||C[MS[k]]!="{")exit
  ti=substr(s,MS[k],ME[k]-MS[k]+1)
  load(ti);if(!members(1))exit
  for(k=1;k<=MN;k++)if(keyesc(k))exit
  new="{\"name\":\"" ENVIRON["MIND_NAME"] "\",\"id\":\"" ENVIRON["MIND_SID"] "\"}"
  k=find("session");if(k<0)exit
  if(k==0){ # none: right after the opening brace, with a comma only when the object has a member
    out=substr(ti,1,1) "\"session\":" new (MN>0?",":"") substr(ti,2)
  }else{
    v=substr(ti,MS[k],ME[k]-MS[k]+1);ms=MS[k];me=ME[k]
    if(substr(v,1,1)=="{"){ # an agent object: keep its name and url, set the real id
      load(v);if(!members(1))exit
      bad=0;for(j=1;j<=MN;j++)if(keyesc(j))bad=1
      if(!bad){a=find("name");u=find("url")
        if(a>0&&C[MS[a]]=="\""){
          nn=substr(v,MS[a],ME[a]-MS[a]+1)
          nw="{\"name\":" nn ",\"id\":\"" ENVIRON["MIND_SID"] "\""
          if(u>0){uv=substr(v,MS[u],ME[u]-MS[u]+1);if(uv=="null"||substr(uv,1,1)=="\"")nw=nw ",\"url\":" uv}
          new=nw "}"}}}
    out=substr(ti,1,ms-1) new substr(ti,me+1)}
  printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":%s}}\n",out}' 2>/dev/null) || exit 0
  [ -n "$_out" ] && printf '%s\n' "$_out" >&3
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
