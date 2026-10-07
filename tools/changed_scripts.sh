#!/usr/bin/env bash
# Every script changed (M) or added (A) since the baseline extraction, as
#   <status>  <Studio full path>  <ClassName>  <file in src/>
# for whoever applies the changes to the place (paste each file's contents into the script at
# that path; A = create a new script of that class there first).
set -u
cd "$(dirname "$0")/.."
BASE=${BASE:-5858734}
git diff --name-status "$BASE" -- 'src/*.luau' | while read -r st f; do
  fn=$(basename "$f")
  line=$(grep -P "\t${fn//./\\.}$" src/_manifest.tsv | head -1)
  path=$(echo "$line" | cut -f1); cls=$(echo "$line" | cut -f2)
  printf '%s\t%s\t%s\t%s\n' "$st" "$path" "$cls" "$f"
done
