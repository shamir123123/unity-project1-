#!/usr/bin/env bash
# Type-check every script changed since the baseline commit and print only NEW diagnostics
# (messages present now but not in the baseline version of the same file; line numbers ignored).
# The baseline is checked AT THE SAME PATH (swapped in, then restored), so relative requires
# resolve the same way for both.
# Needs luau-lsp + Roblox globalTypes.d.luau (paths below) and sourcemap.json at the repo root.
set -u
cd "$(dirname "$0")/.."
LSP=${LUAU_LSP:-/tmp/tools/luau-lsp}
DEFS=${LUAU_DEFS:-/tmp/tools/globalTypes.d.luau}
BASE=${BASE:-5858734}
files=$(git diff --name-only "$BASE" -- 'src/*.luau'; git ls-files --others --exclude-standard -- 'src/*.luau')
status=0
tmpdir=$(mktemp -d)
for f in $files; do
  [ -f "$f" ] || continue
  norm() { grep -F "$1" | sed -E 's/^[^)]*\)\: //; s/line [0-9]+/line #/g' | sort; }
  "$LSP" analyze --sourcemap=sourcemap.json --definitions="$DEFS" "$f" 2>&1 | norm "$f" > "$tmpdir/new.txt"
  if git cat-file -e "$BASE:$f" 2>/dev/null; then
    cp "$f" "$tmpdir/keep"
    trap 'cp "$tmpdir/keep" "$f"' INT TERM
    git show "$BASE:$f" > "$f"
    "$LSP" analyze --sourcemap=sourcemap.json --definitions="$DEFS" "$f" 2>&1 | norm "$f" > "$tmpdir/old.txt"
    cp "$tmpdir/keep" "$f"
    trap - INT TERM
  else
    : > "$tmpdir/old.txt"
  fi
  new=$(comm -23 "$tmpdir/new.txt" "$tmpdir/old.txt")
  if [ -n "$new" ]; then
    echo "== $f: NEW diagnostics"; echo "$new"; status=1
  else
    echo "ok  $f"
  fi
done
rm -rf "$tmpdir"
exit $status
