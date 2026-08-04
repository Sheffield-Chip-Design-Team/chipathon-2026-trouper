#!/usr/bin/env python3
"""PreToolUse guard (Bash): block bulk-recursive deletes of .claude/worktrees.

Why: an agent once ran `rm -rf .claude/worktrees` to clean up its OWN single
worktree and destroyed every sibling worktree under it -- including one
actively locked/in-use by another agent's live process. `git worktree
remove <specific-path>` is always the correct tool: it refuses to touch
anything but the named worktree, and refuses a dirty tree without --force.

This hook blocks any recursive `rm` (rm -r/-rf/-fr/--recursive/etc., also
through `find -delete` / `find -exec rm`) whose target is the worktrees
directory itself (`.claude/worktrees`, with or without trailing slash) or a
wildcard/glob directly under it (`.claude/worktrees/*`, `.claude/worktrees/agent-*`).
Removing ONE specific, fully-named subdirectory
(e.g. `.claude/worktrees/agent-<id>`) is left alone by this hook -- but see
the reason text below, which still steers toward `git worktree remove`.
"""
import json
import re
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # can't parse -- don't block on our own bug

if payload.get("tool_name") != "Bash":
    sys.exit(0)

command = (payload.get("tool_input") or {}).get("command") or ""
if not command:
    sys.exit(0)

# Strip heredoc bodies (<<EOF ... EOF, <<'EOF' ... EOF, <<-EOF ... EOF) before
# scanning. Heredoc content is inert string data (e.g. a commit message, a
# doc this very hook is being described in) -- not a command being executed
# -- so leaving it in causes false positives on prose that merely *mentions*
# `rm -rf .claude/worktrees` without running it.
command = re.sub(
    r"<<-?\s*['\"]?(\w+)['\"]?.*?\n\1\b",
    " ",
    command,
    flags=re.DOTALL,
)

# Split the command into segments on shell separators so multi-command lines
# (a && b; c | d) are each inspected independently.
segments = re.split(r"&&|\|\||;|\|", command)

# Matches a path token that refers to .claude/worktrees itself, optionally
# with a trailing slash, or with a glob directly as its next path component.
# Allows an arbitrary prefix (relative, absolute, ./, ../, $VAR/, etc.) and
# requires the .claude/worktrees segment to be a whole path component (not
# e.g. "my.claude/worktreesfoo").
DANGEROUS_TARGET = re.compile(
    r"""(?:^|['"]?)                # start of token, optional open quote
        (?:[^\s'"]*/)?             # optional path prefix ending in /
        \.claude/worktrees         # the directory itself
        (?:
            /?['"]?(?:\s|$)        # ...end of token (bare dir, w/ or w/o trailing slash)
          |
            /[^/\s'"]*[*?\[][^\s'"]*  # ...or next segment contains a glob char
        )
    """,
    re.VERBOSE,
)

RECURSIVE_RM = re.compile(r"""
    \brm\b[^;&|]*?           # an rm invocation, up to the next separator
    (?: -[a-zA-Z]*r[a-zA-Z]* # a short-flag cluster containing r (rf, fr, rfv, ...)
      | --recursive\b
    )
""", re.VERBOSE)

# find ... -delete  or  find ... -exec rm ... {} \;  are just as destructive.
RECURSIVE_FIND_DELETE = re.compile(r"\bfind\b[^;&|]*\.claude/worktrees[^;&|]*(-delete\b|-exec\s+rm\b)")

hit = None
for seg in segments:
    if DANGEROUS_TARGET.search(seg) and (RECURSIVE_RM.search(seg) or "-delete" in seg or "-exec" in seg):
        if RECURSIVE_RM.search(seg) or RECURSIVE_FIND_DELETE.search(seg):
            hit = seg.strip()
            break

if hit is None:
    sys.exit(0)

reason = (
    "Blocked: this recursively deletes the shared .claude/worktrees directory "
    "(or a wildcard under it) rather than one specific worktree.\n"
    f"  Command segment: {hit!r}\n\n"
    "That directory can hold OTHER agents' worktrees, including ones with "
    "uncommitted work or an actively running process -- a bulk rm silently "
    "destroys them with no chance to recover uncommitted changes.\n\n"
    "Use the git-native cleanup instead:\n"
    "  1. git worktree list --porcelain   # check for a `locked` marker on the "
    "target -- that means an agent pid is still using it; leave it alone\n"
    "  2. git worktree remove <specific-worktree-path>   # removes only that "
    "one worktree; refuses if it has uncommitted changes unless you pass "
    "--force\n\n"
    "If you really do need to clear the whole directory (e.g. it's full of "
    "stale/orphaned entries with no live process), remove each worktree "
    "individually with `git worktree remove`, or ask the user before doing "
    "anything broader."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    },
    "systemMessage": "Blocked a bulk delete of .claude/worktrees -- use `git worktree remove <path>` instead.",
}))
sys.exit(0)
