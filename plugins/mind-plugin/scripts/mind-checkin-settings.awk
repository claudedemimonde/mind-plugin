# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# mind-checkin-settings.awk - the one place the check-in tool reads or edits a JSON
# file with no Node and no jq (DESIGN.md "Build" BT15). Plain awk (POSIX: BSD, mawk,
# gawk, busybox). Run as   MIND_MODE=<mode> [MIND_CMD=..] [MIND_ORIGIN=..] awk -f this file FILE
#
#   check      exit 0 if FILE is one valid JSON object, else 3.
#   ensure     install helper: print FILE unchanged and exit 0 when exactly two of our hooks are
#              there: PostToolUse with command MIND_CMD and Stop with command MIND_CMD + " stop";
#              exit 4 otherwise.
#   uninstall  print FILE without any hook that is ours (see is_ours). A group that also held other
#              hooks keeps them. Empty containers we leave behind are removed.
#   add        print FILE with a PostToolUse group running MIND_CMD and a Stop group running MIND_CMD + " stop"
#              (refuses if one of ours is there).
#   servers    print the name of every mcpServers entry whose url is on MIND_ORIGIN.
#   plugins    (installed_plugins.json) print "name<TAB>installPath" for every plugin entry; name is
#              the key up to the first @. Keys with an escape are skipped; in a path only \\ and \/ are
#              decoded (to /), any other escape skips the entry.
#   plugin-servers  (a plugin's .mcp.json) like servers: the root's mcpServers object if it has
#              one, else the root's object-valued members are the servers.
#
# It never writes. It parses the whole file first and edits by splicing text at exact
# positions, so every byte it does not mean to change stays as it was. Exit 3 means the file
# is not valid JSON or not shaped as expected; stdout is then empty and nothing may be written.

function fail(msg) { ERR = msg; return 0 }

# The file is held in pieces of CHUNK bytes. substr on one long string costs its whole length in BSD
# awk, which made a 1 MB ~/.claude.json take 44 s; through pieces it is about a second.
function at(p) { return substr(B[int((p - 1) / CHUNK)], (p - 1) % CHUNK + 1, 1) }

function span(p, n,   out, o, k) {   # n bytes from position p
  out = ""
  while (n > 0 && p <= len) {
    o = (p - 1) % CHUNK
    k = CHUNK - o
    if (k > n) k = n
    out = out substr(B[int((p - 1) / CHUNK)], o + 1, k)
    p += k
    n -= k
  }
  return out
}

function ws(   c) {
  while (pos <= len) {
    c = at(pos)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
    else break
  }
}

function pstring(   c, h, k) {   # pos is on the opening quote; returns raw text between the quotes
  pos++
  start = pos
  while (pos <= len) {
    c = at(pos)
    if (c == "\"") { raw = span(start, pos - start); pos++; return 1 }
    if (c == "\n") return fail("newline in string")
    if (c < " ") return fail("control character in string")
    if (c == "\\") {
      pos++
      c = at(pos)
      if (c == "" || (index("\"\\/bfnrt", c) == 0 && c != "u")) return fail("bad escape")
      if (c == "u") {
        for (k = 1; k <= 4; k++) {
          h = at(pos + k)
          if (h == "" || index("0123456789abcdefABCDEF", h) == 0) return fail("bad unicode escape")
        }
        pos += 4
      }
    }
    pos++
  }
  return fail("unterminated string")
}

function path_decode(s,   out, i, c, n) {   # raw JSON string -> path; only \\ and \/ (both become /), else ""
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") {
      i++
      c = substr(s, i, 1)
      if (c != "\\" && c != "/") return ""
      c = "/"
    }
    out = out c
  }
  return out
}

function pvalue(depth,  c, id, ok, ms, key) {   # returns the node id, or 0 on error
  if (depth > 60) return fail("too deep")
  ws()
  c = at(pos)
  id = ++NID
  S[id] = pos
  if (c == "\"") {
    if (!pstring()) return 0
    KIND[id] = "s"; V[id] = raw
  } else if (c == "{") {
    KIND[id] = "o"; N[id] = 0; pos++
    ws()
    if (at(pos) == "}") pos++
    else for (;;) {
      ws()
      ms = pos
      if (at(pos) != "\"") return fail("expected a key")
      if (!pstring()) return 0
      key = raw
      ws()
      if (at(pos) != ":") return fail("expected a colon")
      pos++
      ok = pvalue(depth + 1)
      if (!ok) return 0
      N[id]++
      CH[id, N[id]] = ok; KEY[id, N[id]] = key; MS[id, N[id]] = ms
      ws()
      c = at(pos)
      pos++
      if (c == "}") break
      if (c != ",") return fail("expected a comma or a closing brace")
    }
  } else if (c == "[") {
    KIND[id] = "a"; N[id] = 0; pos++
    ws()
    if (at(pos) == "]") pos++
    else for (;;) {
      ws()
      ms = pos
      ok = pvalue(depth + 1)
      if (!ok) return 0
      N[id]++
      CH[id, N[id]] = ok; MS[id, N[id]] = ms
      ws()
      c = at(pos)
      pos++
      if (c == "]") break
      if (c != ",") return fail("expected a comma or a closing bracket")
    }
  } else if (match(span(pos, 64), /^(-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null)/)) {
    KIND[id] = "l"; pos += RLENGTH
  } else return fail("unexpected character")
  E[id] = pos
  return id
}

function member(obj, key,   i, found) {   # index of member `key` in object obj, 0 if none, -1 if duplicated
  found = 0
  for (i = 1; i <= N[obj]; i++) if (KEY[obj, i] == key) { if (found) return -1; found = i }
  return found
}

function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }

# A hook object whose whole command is what install writes: sh '<path>/mind-checkin-hook.sh', with
# " hint" for the retired SessionStart entry or " stop" for the Stop entry. A hook of the person's that only mentions our file, or
# runs it among other things, is theirs. Inside the quotes a ' can only appear as '\'' (raw JSON: two
# backslashes), so the path being one quoted word is what proves nothing else runs. The same line
# typed by hand, with a plain path and no quotes, counts too.
function is_ours(h,   m, s) {
  if (KIND[h] != "o") return 0
  m = member(h, "command")
  if (m <= 0 || KIND[CH[h, m]] != "s") return 0
  s = V[CH[h, m]]
  if (s ~ /^sh [A-Za-z0-9_.\/~-]*\/mind-checkin-hook\.sh( hint| stop)?$/) return 1
  if (substr(s, 1, 4) != "sh '") return 0
  sub(/ (hint|stop)$/, "", s)
  if (!match(s, /\/mind-checkin-hook\.sh'$/)) return 0
  s = substr(s, 5, length(s) - 5)
  gsub(/'\\\\''/, "", s)
  return index(s, "'") == 0
}

# A key spelled with an escape can decode to "hooks" or "PostToolUse", which this parser, comparing
# raw text, would not see, and adding ours would then leave two of the same key.
function escaped_key(obj,   i) {
  for (i = 1; i <= N[obj]; i++) if (index(KEY[obj, i], "\\")) return 1
  return 0
}

function addop(s, e, r) { NOPS++; OS[NOPS] = s; OE[NOPS] = e; OR[NOPS] = r }

# Delete the items flagged in DEL[container,i] (not all of them): from the start of the first
# of a run to the start of the next kept item, or, at the end, from the end of the last kept item.
function delete_items(c,   i, a, b) {
  i = 1
  while (i <= N[c]) {
    if (!DEL[c, i]) { i++; continue }
    a = i
    while (i <= N[c] && DEL[c, i]) i++
    b = i - 1
    if (i <= N[c]) addop(MS[c, a], MS[c, i], "")
    else addop(E[CH[c, a - 1]], E[CH[c, b]], "")
  }
}

function count_del(c,   i, n) { n = 0; for (i = 1; i <= N[c]; i++) if (DEL[c, i]) n++; return n }

# Mark everything of ours for removal, cascading up through emptied groups, event arrays and "hooks".
function mark_ours(hooks,   e, g, j, k, gi, gm, harr, nours, ev, evdel, ngroups, found) {
  found = 0
  for (e = 1; e <= N[hooks]; e++) {
    ev = CH[hooks, e]
    if (KIND[ev] != "a") continue
    for (gi = 1; gi <= N[ev]; gi++) {
      g = CH[ev, gi]
      if (KIND[g] != "o") continue
      gm = member(g, "hooks")
      if (gm <= 0 || KIND[CH[g, gm]] != "a") continue
      harr = CH[g, gm]
      nours = 0
      for (k = 1; k <= N[harr]; k++) if (is_ours(CH[harr, k])) { DEL[harr, k] = 1; nours++ }
      if (!nours) continue
      found += nours
      if (nours == N[harr]) { for (k = 1; k <= N[harr]; k++) DEL[harr, k] = 0; DEL[ev, gi] = 1 }
    }
    if (N[ev] > 0 && count_del(ev) == N[ev]) DEL[hooks, e] = 1
  }
  return found
}

function apply_ops(   i, j, t, out, here) {
  for (i = 2; i <= NOPS; i++) {   # insertion sort by start
    t = i
    while (t > 1 && OS[t - 1] > OS[t]) {
      here = OS[t]; OS[t] = OS[t - 1]; OS[t - 1] = here
      here = OE[t]; OE[t] = OE[t - 1]; OE[t - 1] = here
      here = OR[t]; OR[t] = OR[t - 1]; OR[t - 1] = here
      t--
    }
  }
  out = ""; here = 1
  for (i = 1; i <= NOPS; i++) {
    if (OS[i] < here) return fail("overlapping edits")
    out = out span(here, OS[i] - here) OR[i]
    here = OE[i]
  }
  return out span(here, len - here + 1)
}

function origin_of(u) {
  if (match(u, /^[Hh][Tt][Tt][Pp][Ss]?:\/\/[^\/?#]+/)) return tolower(substr(u, 1, RLENGTH))
  return ""
}

# Print the name of each server in object srv whose url is on `want`; a name written with an escape is refused.
function print_servers(srv,   j, s, um) {
  for (j = 1; j <= N[srv]; j++) {
    s = CH[srv, j]
    if (KIND[s] != "o") continue
    um = member(s, "url")
    if (um > 0 && KIND[CH[s, um]] == "s" && origin_of(V[CH[s, um]]) == want && KEY[srv, j] !~ /[\\]/) print KEY[srv, j]
  }
}

BEGIN { CHUNK = 4096; nb = 0; cur = "" }

{
  cur = cur (NR > 1 ? "\n" : "") $0
  while (length(cur) >= CHUNK) { B[nb++] = substr(cur, 1, CHUNK); cur = substr(cur, CHUNK + 1) }
}

END {
  mode = ENVIRON["MIND_MODE"]
  B[nb] = cur
  len = nb * CHUNK + length(cur); pos = 1
  root = pvalue(0)
  if (root) { ws(); if (pos <= len) { root = 0; ERR = "trailing text" } }
  if (!root || KIND[root] != "o") { if (ERR != "") print ERR > "/dev/stderr"; exit 3 }
  if (mode == "check") exit 0

  hm = member(root, "hooks")
  if (hm < 0) { print "hooks appears twice" > "/dev/stderr"; exit 3 }
  hooks = hm > 0 ? CH[root, hm] : 0
  if (hooks && KIND[hooks] != "o") { print "\"hooks\" is not an object" > "/dev/stderr"; exit 3 }
  if (mode != "servers" && mode != "plugins" && mode != "plugin-servers" && (escaped_key(root) || (hooks && escaped_key(hooks)))) { print "a key is written with an escape" > "/dev/stderr"; exit 3 }

  if (mode == "servers") {
    want = tolower(ENVIRON["MIND_ORIGIN"])
    for (n = 1; n <= NID; n++) {
      if (KIND[n] != "o") continue
      for (i = 1; i <= N[n]; i++) {
        if (KEY[n, i] != "mcpServers" || KIND[CH[n, i]] != "o") continue
        print_servers(CH[n, i])
      }
    }
    exit 0
  }

  if (mode == "plugin-servers") {
    want = tolower(ENVIRON["MIND_ORIGIN"])
    m = member(root, "mcpServers")
    if (m > 0 && KIND[CH[root, m]] == "o") print_servers(CH[root, m])
    else if (m == 0) print_servers(root)
    exit 0
  }

  if (mode == "plugins") {
    pm = member(root, "plugins")
    if (pm <= 0 || KIND[CH[root, pm]] != "o") exit 0
    pl = CH[root, pm]
    for (i = 1; i <= N[pl]; i++) {
      arr = CH[pl, i]; key = KEY[pl, i]
      if (KIND[arr] != "a" || index(key, "\\") || key ~ /^@/) continue
      sub(/@.*/, "", key)
      for (j = 1; j <= N[arr]; j++) {
        ent = CH[arr, j]
        if (KIND[ent] != "o") continue
        im = member(ent, "installPath")
        if (im > 0 && KIND[CH[ent, im]] == "s" && V[CH[ent, im]] != "") {
          ip = path_decode(V[CH[ent, im]])
          if (ip != "") print key "\t" ip
        }
      }
    }
    exit 0
  }

  if (mode == "ensure") {
    cmd = jesc(ENVIRON["MIND_CMD"])
    total = 0; good = 0
    for (e = 1; hooks && e <= N[hooks]; e++) {
      ev = CH[hooks, e]
      if (KIND[ev] != "a") continue
      for (gi = 1; gi <= N[ev]; gi++) {
        g = CH[ev, gi]
        gm = (KIND[g] == "o") ? member(g, "hooks") : 0
        if (gm <= 0 || KIND[CH[g, gm]] != "a") continue
        harr = CH[g, gm]
        for (k = 1; k <= N[harr]; k++) if (is_ours(CH[harr, k])) {
          total++
          cm = member(CH[harr, k], "command")
          if (KEY[hooks, e] == "PostToolUse" && V[CH[CH[harr, k], cm]] == cmd) good++
          if (KEY[hooks, e] == "Stop" && V[CH[CH[harr, k], cm]] == cmd " stop") good++
        }
      }
    }
    if (total == 2 && good == 2) { print span(1, len); exit 0 }
    exit 4
  }

  if (mode == "uninstall") {
    if (!hooks) { print span(1, len); exit 0 }
    if (!mark_ours(hooks)) { print span(1, len); exit 0 }
    # Containers that lost everything go as a whole: events from "hooks", and "hooks" from the root.
    for (e = 1; e <= N[hooks]; e++) {
      ev = CH[hooks, e]
      if (KIND[ev] != "a" || DEL[hooks, e]) continue
      if (count_del(ev) > 0) delete_items(ev)
      for (gi = 1; gi <= N[ev]; gi++) {
        g = CH[ev, gi]
        if (DEL[ev, gi] || KIND[g] != "o") continue
        gm = member(g, "hooks")
        if (gm > 0 && KIND[CH[g, gm]] == "a" && count_del(CH[g, gm]) > 0) delete_items(CH[g, gm])
      }
    }
    if (count_del(hooks) == N[hooks]) DEL[root, hm] = 1
    else delete_items(hooks)
    if (count_del(root) > 0) {
      if (count_del(root) == N[root]) addop(MS[root, 1], E[CH[root, N[root]]], "")
      else delete_items(root)
    }
    out = apply_ops()
    if (ERR != "") { print ERR > "/dev/stderr"; exit 3 }
    print out
    exit 0
  }

  if (mode == "add") {
    cmd = jesc(ENVIRON["MIND_CMD"])
    group = "{\"hooks\": [{\"type\": \"command\", \"command\": \"" cmd "\", \"timeout\": 10}]}"
    sgroup = "{\"hooks\": [{\"type\": \"command\", \"command\": \"" cmd " stop\", \"timeout\": 10}]}"
    pevent = "\"PostToolUse\": [\n      " group "\n    ]"
    sevent = "\"Stop\": [\n      " sgroup "\n    ]"
    if (hooks && mark_ours(hooks)) { print "one of our hooks is already there" > "/dev/stderr"; exit 3 }
    if (!hooks) {
      addop(S[root] + 1, S[root] + 1, "\n  \"hooks\": {\n    " pevent ",\n    " sevent "\n  }" (N[root] > 0 ? "," : "\n"))
    } else {
      pm = member(hooks, "PostToolUse")
      if (pm < 0) { print "PostToolUse appears twice" > "/dev/stderr"; exit 3 }
      sm = member(hooks, "Stop")
      if (sm < 0) { print "Stop appears twice" > "/dev/stderr"; exit 3 }
      if ((pm > 0 && KIND[CH[hooks, pm]] != "a") || (sm > 0 && KIND[CH[hooks, sm]] != "a")) { print "a hook event is not an array" > "/dev/stderr"; exit 3 }
      # Events that are missing go in together at the start of "hooks" (one splice, so the commas stay right); an existing array gets its group at its start.
      miss = ""
      if (pm == 0) miss = pevent
      if (sm == 0) miss = miss (miss == "" ? "" : ",\n    ") sevent
      if (miss != "") addop(S[hooks] + 1, S[hooks] + 1, "\n    " miss (N[hooks] > 0 ? "," : "\n  "))
      if (pm > 0) { arr = CH[hooks, pm]; addop(S[arr] + 1, S[arr] + 1, "\n      " group (N[arr] > 0 ? "," : "\n    ")) }
      if (sm > 0) { arr = CH[hooks, sm]; addop(S[arr] + 1, S[arr] + 1, "\n      " sgroup (N[arr] > 0 ? "," : "\n    ")) }
    }
    out = apply_ops()
    if (ERR != "") { print ERR > "/dev/stderr"; exit 3 }
    print out
    exit 0
  }
  print "unknown mode" > "/dev/stderr"
  exit 2
}
