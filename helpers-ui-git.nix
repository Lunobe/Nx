{repoDir, ...}: {
  # -- nx: shared UI/git helpers --

  programs.fish.functions = {
    __nx_stage = ''
      echo ""
      set_color -o blue
      echo -n "==> "
      set_color normal
      echo "$argv[1]"
    '';

    # printed right after a stage's action finishes, so a step that
    # produces no output of its own doesn't leave it unclear whether it
    # actually ran — only call this once the action is known to have
    # succeeded (after any status check for that step); takes an
    # optional trailing note, e.g. __nx_ok "3 generations removed"
    __nx_ok = ''
      set_color -o green
      if test -n "$argv[1]"
        echo "OK — $argv[1]"
      else
        echo "OK"
      end
      set_color normal
    '';

    # short, best-guess diagnosis printed after a command fails, so the
    # relevant line isn't just lost above a wall of build/eval output
    __nx_fail = ''
      echo ""
      set_color -o red
      echo -n "!! "
      set_color normal
      echo "$argv[1]"
    '';

    # "found something, but it's not an error" — distinct from __nx_ok so a
    # genuinely clean pass and "review the report above" don't both read as
    # plain green OK; the caller still continues/returns 0 either way
    __nx_warn = ''
      set_color -o yellow
      echo -n "!  "
      set_color normal
      echo "$argv[1]"
    '';

    __nx_diff_dirty = ''
      # -N stages new files by path only (no content), so they show up
      # in the diff below as additions instead of being invisible
      git -C ${repoDir} add -N -A
      git -C ${repoDir} diff HEAD
    '';

    __nx_commit_if_dirty = ''
      set -l changes (git -C ${repoDir} status --porcelain)
      if test (count $changes) -gt 0
        __nx_stage "Changes to commit:"
        __nx_diff_dirty
        git -C ${repoDir} add -A
        git -C ${repoDir} commit -m "$argv[1]"
      end
    '';

    # like __nx_commit_if_dirty, but without the diff preview — for call
    # sites where the diff was already shown to the user just before
    __nx_commit_quiet = ''
      set -l changes (git -C ${repoDir} status --porcelain)
      if test (count $changes) -gt 0
        git -C ${repoDir} add -A
        git -C ${repoDir} commit -m "$argv[1]"
      end
    '';

    # prompts "$argv[1] [y/N] "; returns 0 on y/yes (any case), 1 otherwise
    __nx_confirm = ''
      echo ""
      read -l -P "$argv[1] [y/N] " confirm
      switch "$confirm"
        case y Y yes Yes YES
          return 0
        case '*'
          return 1
      end
    '';

    # if there are pending changes: shows the diff, asks "$argv[1] [y/N] ",
    # and on yes commits with message "$argv[2]" — used by up/push, which
    # (unlike deploy) commit immediately with no build step in between;
    # returns 1 (and prints "Aborted.") only when declined, not when there
    # was simply nothing to commit
    __nx_confirm_and_commit = ''
      set -l changes (git -C ${repoDir} status --porcelain)
      if test (count $changes) -eq 0
        return 0
      end
      __nx_stage "Changes to commit:"
      __nx_diff_dirty
      if __nx_confirm "$argv[1]"
        git -C ${repoDir} add -A
        git -C ${repoDir} commit -m "$argv[2]"
        return 0
      else
        echo "Aborted."
        return 1
      end
    '';

    # undoes a commit made by __nx_commit_quiet/__nx_commit_if_dirty, but
    # only if one actually happened (HEAD moved past $argv[1]) — leaves
    # the changes staged, as if the commit had never been made
    __nx_rollback_commit = ''
      if test (git -C ${repoDir} rev-parse HEAD) != "$argv[1]"
        git -C ${repoDir} reset --soft "$argv[1]"
      end
    '';

    __nx_untrack_ignored = ''
      set -l tracked_ignored (git -C ${repoDir} ls-files -ci --exclude-standard)
      if test (count $tracked_ignored) -eq 0
        return 0
      end
      __nx_stage "Untracking files matching .gitignore"
      git -C ${repoDir} rm --cached -r -q -f $tracked_ignored
    '';
  };
}
