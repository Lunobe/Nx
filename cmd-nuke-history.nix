{
  repoDir,
  hostName,
  ...
}: {
  # -- nx: nuke-history — kept separate from cmd-maintenance.nix since this
  # is the one truly destructive operation in the whole tool; everything
  # else in that file is safe, routine, and confirm-gated the same way but
  # never rewrites history.

  programs.fish.functions = {
    __nx_cmd_nuke_history = ''
      __nx_stage "Nuking git history"
      echo "WARNING: this permanently rewrites ALL git history in ${repoDir}."
      echo "Every file will be committed fresh as a single \"squashed into single commit\","
      echo "which is then force-pushed, overwriting the remote history too."
      echo "A full backup of the current history is saved locally first (see"
      echo "below), but restoring from it is a manual process, not an undo button."

      set -l changes (git -C ${repoDir} status --porcelain)
      if test (count $changes) -gt 0
        __nx_stage "Local changes that will be swept into the new history:"
        __nx_diff_dirty
      end

      set -l tracked_ignored (git -C ${repoDir} ls-files -ci --exclude-standard)
      if test (count $tracked_ignored) -gt 0
        __nx_stage "Tracked files matching .gitignore that will be dropped:"
        for f in $tracked_ignored
          echo "  $f"
        end
      end

      echo ""
      read -l -P "Type NUKE to continue: " confirm
      switch "$confirm"
        case NUKE
          __nx_stage "Backing up current history"
          # .git-backups/ is gitignored, so it's never tracked, never
          # committed, and never swept into the new squashed history by
          # the git add -A below — safe to keep right inside the repo
          set -l backup_dir ${repoDir}/.git-backups
          mkdir -p $backup_dir
          set -l backup_file $backup_dir/${hostName}-(date +%Y%m%d-%H%M%S).bundle
          # --all bundles every ref (branches + tags), not just the current
          # branch, so nothing reachable is left out of the backup
          git -C ${repoDir} bundle create $backup_file --all
          if test $status -ne 0
            __nx_fail "Backup failed — aborting before touching history. Check disk space/permissions for $backup_dir."
            return 1
          end
          echo "Backup saved: $backup_file"
          __nx_ok

          __nx_stage "Squashing history into a single commit"
          set -l branch (git -C ${repoDir} branch --show-current)
          set -l remote (git -C ${repoDir} remote | head -n1)
          git -C ${repoDir} checkout --orphan __nx_nuke_tmp
          and __nx_untrack_ignored
          and git -C ${repoDir} add -A
          and git -C ${repoDir} commit -m "squashed into single commit"
          and git -C ${repoDir} branch -D $branch
          and git -C ${repoDir} branch -m $branch
          and __nx_stage "Force-pushing rewritten history"
          and git -C ${repoDir} push --force --set-upstream $remote $branch
          and __nx_ok
          or begin
            __nx_fail "History rewrite stopped partway — likely no network/auth for the force-push, or a git step failed; run 'git status' and 'git branch' in ${repoDir} before retrying, the branch may still be __nx_nuke_tmp. The pre-nuke backup is still at $backup_file either way."
            return 1
          end
        case '*'
          echo "Aborted."
          return 1
      end
    '';
  };
}
