#!/usr/bin/env bash
# Type-check every script changed since the baseline commit and print only NEW diagnostics
# (messages present now but not in the baseline version of the same file; line numbers ignored).
# Needs luau-lsp + Roblox globalTypes.d.luau (paths below) and sourcemap.json at the repo root.
set -u
cd "$(dirname "$0")/.."
LSP=${LUAU_LSP:-/tmp/tools/luau-lsp}
DEFS=${LUAU_DEFS:-/tmp/tools/globalTypes.d.luau}
BASE=${BASE:-5858734}
files=$(git diff --name-only "$BASE" -- 'src/*.luau'; git ls-files --others --exclude-standard -- 'src/*.luau')
status=0
for f in $files; do
  [ -f "$f" ] || continue
  tmp="src/__base__$(basename "$f")"
  if git cat-file -e "$BASE:$f" 2>/dev/null; then git show "$BASE:$f" > "$tmp"; else : > "$tmp"; fi
  norm() { grep -F "$1" | sed -E 's/^[^)]*\)\: //; s/line [0-9]+/line #/g' | sort; }
  "$LSP" analyze --sourcemap=sourcemap.json --definitions="$DEFS" "$f" 2>&1 | norm "$f" > /tmp/tc_new.txt
  "$LSP" analyze --sourcemap=sourcemap.json --definitions="$DEFS" "$tmp" 2>&1 | norm "$tmp" > /tmp/tc_old.txt
  rm -f "$tmp"
  new=$(comm -23 /tmp/tc_new.txt /tmp/tc_old.txt)
  if [ -n "$new" ]; then
    echo "== $f: NEW diagnostics"; echo "$new"; status=1
  else
    echo "ok  $f"
  fi
done
exit $status
