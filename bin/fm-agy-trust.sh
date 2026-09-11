#!/usr/bin/env bash
# Pre-register Antigravity CLI's workspace trust for the isolated task worktree
# a ship/scout spawn is about to launch an agy crewmate into, so the worker
# reaches its brief instead of wedging on the trust dialog.
#
# Usage: fm-agy-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. agy gates a folder it has never seen behind an interactive
# dialog, and --dangerously-skip-permissions does NOT cover it. Verified live
# on agy 1.1.27 under tmux: a fresh worktree launch renders
#
#   Do you trust the contents of this project?
#   Antigravity CLI requires permission to read, edit, and execute files here.
#   > Yes, I trust this folder
#     No, exit
#
# before the brief is ever read. Every fresh task worktree therefore hits it.
# The preselected row is the accepting one, so an Enter WOULD answer it, but
# firstmate must not answer a dialog by key: the steering plane carries only
# Enter, Escape and C-c, it cannot see which row a future version preselects,
# and a reordered menu would make the same keystroke choose "No, exit".
# Registering the trust before launch is the deterministic control, and it is
# the same control the claude adapter uses for the same reason
# (bin/fm-claude-trust.sh).
#
# Answering the dialog in the TUI appends the resolved worktree path to
# "trustedWorkspaces" in agy's own settings file, which is what this script
# writes directly (verified live: the array gained exactly the launched
# worktree's path after one accepted dialog, and the next launch in that same
# worktree showed no dialog at all).
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy, exactly as bin/fm-claude-trust.sh documents at length.
# <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument. A
# primary checkout, a worktree of an unrelated repo, a subdirectory of a
# worktree, a plain directory, and a home directory are each refused. Refusal
# is a non-zero exit, never a warning and never a silent skip. Trust is a
# grant to read, edit, and execute, so the grant must never be widened by a
# caller's word about what a path is.
#
# Only the launching user's own store is written: the "trustedWorkspaces" array
# in $HOME/.gemini/antigravity-cli/settings.json, which must be a regular file
# this uid owns. Every unrelated key and every existing entry is preserved, and
# the replacement is atomic. agy exposes no environment override for that
# location (verified: the binary carries no config-root variable alongside its
# ANTIGRAVITY_* names), so HOME is the only input and a spawn that changed HOME
# would name a different store on both sides equally.
set -u
# Path resolution here must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH would
# redirect any relative `cd` operand - notably the `.git` that
# `git rev-parse --git-common-dir` returns for a primary checkout - into an
# unrelated directory. The git overrides do the same to git's own answers: an
# inherited GIT_DIR with GIT_WORK_TREE makes a primary checkout report a linked
# worktree's git dir, so the primary-checkout refusal would pass. Git exports
# GIT_DIR into every hook environment, so an inherited value is ordinary rather
# than hostile. Clear the whole class once here so every subshell inherits it
# and a later added git call cannot silently reintroduce the hole.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-agy-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register agy trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The fully resolved path of an existing file, or empty. Resolution runs in node
# because it must follow a symlink chain to its final target, and node is
# already this script's JSON writer.
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so agy's settings file cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
CONFIG_DIR="$HOME_REAL/.gemini/antigravity-cli"
# agy creates this tree on first run, so a home that has never run agy has no
# directory yet. Create it for the same reason bin/fm-claude-trust.sh does, and
# refuse only when it genuinely cannot be written, since a store this cannot
# reach means the worker meets the dialog after all.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
[ -n "$CONFIG_DIR_REAL" ] || refuse "agy config directory '$CONFIG_DIR' does not exist and could not be created"

# A home or config directory is never a task worktree. Checked explicitly so
# the refusal names the real reason instead of the git verdict behind it.
[ "$WT_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$WT_REAL' is the agy config directory, not a task worktree"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

# The store write needs node, and a missing interpreter refuses like every other
# failure here, for the reason bin/fm-claude-trust.sh states: degrading would
# launch a worker straight into the dialog this registration exists to remove.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

STORE="$CONFIG_DIR_REAL/settings.json"
# A dotfile manager or a synced folder legitimately symlinks this store, so the
# link is followed to its final target and every check below judges that target.
# Ownership is the property that matters: another user's file is refused however
# it is reached. Writing to the resolved path is what keeps the link itself in
# place, since staging beside the link and renaming would replace it with a
# regular file and break that layout.
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. A live agy session writes this
# same file (it persists a trust answer, a model choice, or a permission grant
# mid-session), so the store can move under us and each direction needs its own
# answer, exactly as bin/fm-claude-trust.sh explains.
#
# Losing the VENDOR's write is the serious one: this renames a whole
# re-serialisation over the file, so anything agy changed since the read -
# another workspace's trust, a permissions allow entry - would be gone, in a
# format this does not own. So the bytes read are fingerprinted and re-checked
# immediately before the rename, and a store that moved is not overwritten: the
# whole read-modify-write is retried once, and a second move refuses rather
# than clobbering.
#
# That narrows the window; it does not close it. Rename cannot be conditioned on
# content, so a write landing between the final check and the rename is still
# lost, and this claims no more than that.
#
# Losing OUR entry is the mild one: a vendor rewrite that drops it only
# resurrects the dialog this registration removes, which reaches firstmate as an
# ordinary stale wake and a relaunch registers again. The readback catches it
# within these attempts, and it must fail loudly rather than report a trust it
# did not leave.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.trustedWorkspaces === undefined) root.trustedWorkspaces = [];
  const trusted = root.trustedWorkspaces;
  if (!Array.isArray(trusted)) {
    throw new Error(`${store} has a non-array "trustedWorkspaces" value`);
  }
  // Append only when absent, so a repeat registration is idempotent and never
  // grows the operator's own list with duplicates.
  if (!trusted.includes(worktree)) trusted.push(worktree);
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.settings.json.fm-trust.${unique}`);
  // Two-space pretty-printed with a trailing newline, because that is the
  // format agy itself writes: the store measured on the box this was written
  // on begins "{\n  " and ends "  ]\n}\n". Compact would reformat the
  // operator's whole config on every spawn and the vendor's next write would
  // expand it again.
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return Array.isArray(back.trustedWorkspaces) && back.trustedWorkspaces.includes(worktree)
    ? "recorded"
    : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
