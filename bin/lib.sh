# Shared by merge.sh and ship.sh; sourced, not run.
#
#   MERGE_TARGET=<branch>   the branch every session merges into (default: Worktrunk's default branch,
#                           `wt config state default-branch`: its override, then origin/HEAD, then local inference)
#   MERGE_EVENTS=<file>     append JSON lines for the lab (lab/race.sh, lab/summary.py)

target=${MERGE_TARGET:-$(wt config state default-branch 2>/dev/null || true)}
[ -n "$target" ] || { echo "no target branch: set MERGE_TARGET or 'wt config state default-branch set <branch>'" >&2; exit 2; }

ev() { [ -z "${MERGE_EVENTS:-}" ] || printf '{"t":%s,"pid":%s,"wt":"%s","ev":"%s"%s}\n' \
  "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" $$ "${PWD##*/}" "$1" "${2:+,$2}" >> "$MERGE_EVENTS"; }

# merge.sh records the branch tip before each merge here. A rebase interrupted at its start and then
# "continued" can finish with no commit picked: the branch lands on the target's tip, looks merged, and the
# work is only in the reflog (lab/recover.sh R1). Landed means every recorded commit is on the target: matched
# by author, author date and subject, which a rebase keeps and a conflict resolution does not change, or by
# patch, when the rebase dropped it because the same change was already there (lab/recover.sh R3), or by content:
# applying the commit to the target changes nothing, as when a duplicate with a different patch landed first and the
# rebase dropped this one as empty by itself (R6; merge-tree --merge-base needs git >= 2.40). A commit whose intent
# is on the target in other code (a duplicate that came through a conflict, skipped here) matches none of these:
# only the agent can tell, so the agent names it in merge-dropped and only that commit is excused (R6).
orig="$(git rev-parse --git-dir)/merge-orig"; dropped="$(git rev-parse --git-dir)/merge-dropped"
# A retry must not forget a tip that is not in HEAD: a rebase that lost one of two commits would otherwise replace the
# record with the already incomplete history (R12). The record is replaced only when HEAD contains it.
# A kill while the record was written leaves it empty: such a record is no record (R12b). Written whole, through a rename.
record_tip() {
  [ ! -f "$orig" ] || git rev-parse -q --verify "$(cat "$orig")^{commit}" >/dev/null || rm -f "$orig"
  git merge-base --is-ancestor HEAD "$target" && return 0
  [ ! -f "$orig" ] || git merge-base --is-ancestor "$(cat "$orig")" HEAD || return 0
  git rev-parse HEAD > "$orig.tmp" && mv "$orig.tmp" "$orig"
}
# A merge commit with a change of its own (a conflict resolution, an extra file) is dropped by the rebase, and the
# change with it; `git cherry` does not see it (R14). A clean merge of the target into the branch has none: it passes.
refuse_edited_merges() {
  [ -z "$(git log --merges --remerge-diff --format= "$target..HEAD" 2>/dev/null)" ] ||
    { echo "$0: refused: a merge commit of this branch carries a change of its own, and the rebase would drop it. Rebase the branch onto $target by hand (git rebase -r $target), or redo the merge's change in an ordinary commit." >&2; exit 2; }
}
landed() { # exit 0: on the target with nothing lost; 1: not on the target; 5: on the target, recorded commits missing
  git merge-base --is-ancestor HEAD "$target" || return 1
  [ -f "$orig" ] && git rev-parse -q --verify "$(cat "$orig")^{commit}" >/dev/null || { rm -f "$orig"; return 0; }
  local o lost="" c id onto tt m; o=$(cat "$orig"); tt=$(git rev-parse "$target^{tree}")
  onto=$(git log --format='%H %ae %at %s' "$(git merge-base "$target" "$o")..$target")
  # `git cherry` marks with + the commits whose change is not on the target as a patch; only those can be lost
  for c in $(git cherry "$target" "$o" | sed -n 's/^+ //p'); do
    id=$(git log -1 --format='%ae %at %s' "$c")
    # the same author, second and subject is not proof (a shared git identity): the match must touch only files this commit
    # touches (R13). A file of this commit that the match lacks may have been dropped as already on the target by the
    # rebase (R6d). shortcut: that file is not checked, a collision on a subset of files still reads as landed
    # ENVIRON, not -v: awk -v reads backslash escapes, and a subject with \n in it would never match
    for m in $(printf '%s\n' "$onto" | ID="$id" awk '{ h = $1; sub(/^[^ ]+ /, "") } $0 == ENVIRON["ID"] { print h }'); do
      [ -z "$(comm -23 <(git diff-tree --no-commit-id --name-only -r "$m" | sort) <(git diff-tree --no-commit-id --name-only -r "$c" | sort))" ] && continue 2
    done
    # only a clean merge counts: on a conflict (modify/delete, binary) merge-tree keeps the target's side, and the tree
    # can equal the target's while the commit's change is lost (R6c)
    m=$(git merge-tree --write-tree --merge-base="$c^" "$target" "$c" 2>/dev/null) && [ "${m%%$'\n'*}" = "$tt" ] && continue
    [ -f "$dropped" ] && grep -qx "$c" "$dropped" && continue
    lost="$lost$id"$'\n'
  done
  lost=${lost%$'\n'}
  if [ -n "$lost" ]; then
    printf 'commits of this branch are not on %s although the branch is:\n%s\nRestore them: git reset --hard %s, then merge again. If you rewrote this branch on purpose (amend, manual rebase), the record is stale: rm %s\nDropped on purpose (rebase --skip, its intent already on %s): append its sha (git log %s) to %s\n' \
      "$target" "$lost" "$o" "$orig" "$target" "$o" "$dropped" >&2
    return 5
  fi
  rm -f "$orig" "$dropped"
}

# Another session's merge moving the target is not an agent's doing when every step is a move merge.sh recorded under its
# lock in wt-merge.moves (R8): exit 0 when the chain of recorded moves leads from <from> to <to>.
by_merges() { local m; m="$(git rev-parse --path-format=absolute --git-common-dir)/wt-merge.moves"
  [ -f "$m" ] && awk -v cur="$1" -v end="$2" '{ n[$1] = $2 } END { for (i = 0; i < 100000 && cur != end; i++) { if (!(cur in n)) exit 1; cur = n[cur] } exit (cur == end ? 0 : 1) }' "$m"; }
