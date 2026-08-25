{repoDir, ...}: {
  # -- nx: flake/git lifecycle upkeep — up (which deploys), clean, push,
  # doctor (= format + up + clean + push). Grouped together since
  # doctor is mostly these composed (format lives in its own file —
  # cmd-format.nix — since it's also a standalone command with its own
  # docs). nuke-history lives in its own file (cmd-nuke-history.nix) —
  # unlike these, it rewrites history and isn't something you run routinely.

  programs.fish.functions = {
    # updates flake.lock, then deploys — unless the update left flake.lock
    # unchanged, in which case there's nothing new to build and deploy is
    # skipped; run nx up whenever you want the latest inputs built and
    # switched in
    __nx_cmd_up = ''
      __nx_stage "Checking for local changes"
      __nx_confirm_and_commit "Commit these and update flake inputs?" "nx: auto-commit before update"
      or return 1
      __nx_ok

      __nx_stage "Updating flake inputs"
      nix flake update --flake ${repoDir}
      if test $status -ne 0
        __nx_fail "Updating flake inputs failed — likely no network access or an input source is unreachable."
        return 1
      end

      if git -C ${repoDir} diff --quiet -- flake.lock
        __nx_ok "already up to date — nothing to deploy"
        return 0
      end
      __nx_ok

      nx deploy
    '';

    __nx_cmd_clean = ''
      set -l keep
      set -l all no
      set -l i 2
      while test $i -le (count $argv)
        switch $argv[$i]
          case --keep
            set i (math $i + 1)
            set keep $argv[$i]
          case --all
            set all yes
          case '*'
            __nx_fail "Unknown option '$argv[$i]' — usage: nx clean --keep <n> | nx clean --all"
            return 1
        end
        set i (math $i + 1)
      end

      if test "$all" = yes -a -n "$keep"
        __nx_fail "Use either --keep <n> or --all, not both."
        return 1
      end
      if test "$all" = no
        # no flags at all — default to --keep 7
        if test -z "$keep"
          set keep 7
        end
        if not string match -qr '^[0-9]+$' -- "$keep"
          __nx_fail "--keep expects a whole number of days, got '$keep'."
          return 1
        end
      end

      __nx_stage "Collecting garbage"
      if test "$all" = yes
        sudo nix-collect-garbage -d
      else
        sudo nix-collect-garbage --delete-older-than "$keep"d
      end
      if test $status -ne 0
        __nx_fail "Garbage collection failed — likely a permissions issue or the store is locked by another nix process."
        return 1
      end
      __nx_ok
    '';

    __nx_cmd_push = ''
      __nx_stage "Checking for local changes"
      __nx_confirm_and_commit "Commit and push these to the remote?" "nx: update"
      or return 1
      __nx_ok

      __nx_stage "Pushing to remote"
      git -C ${repoDir} push
      if test $status -ne 0
        __nx_fail "Push failed — likely diverged from the remote (needs a pull/rebase first) or no network/auth access."
        return 1
      end
      __nx_ok
    '';

    __nx_cmd_doctor = ''
      __nx_stage "Running full maintenance cycle (format, up, clean, push)"
      nx format
      and nx up
      and nx clean --keep 7
      and nx push
      and __nx_ok "Maintenance cycle complete"
    '';
  };
}
