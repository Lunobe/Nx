{
  repoDir,
  hostName,
  pkgs,
  ...
}: {
  # -- nx: deploy --

  programs.fish.functions = {
    __nx_cmd_deploy = ''
      __nx_stage "Checking for local changes"
      # stage only (no commit yet) — needed so Nix can see new/changed
      # files while building; the commit itself waits until confirmed
      git -C ${repoDir} add -A
      __nx_ok
      set -l proceed yes
      if not git -C ${repoDir} diff --cached --quiet
        __nx_stage "Changes to commit:"
        git -C ${repoDir} diff --cached

        if __nx_confirm "Build and switch to this configuration?"
          set proceed yes
        else
          set proceed no
        end
      end

      switch "$proceed"
        case yes
          # commit now, so the tree is clean for nix flake check/build
          # (avoids a spurious "Git tree is dirty" warning) — but if
          # either fails, roll the commit back with __nx_rollback_commit
          # so a broken config never lingers in history
          set -l pre_check_head (git -C ${repoDir} rev-parse HEAD)
          __nx_commit_quiet "nx: auto-commit before deploy"

          __nx_stage "Checking flake"
          nix flake check ${repoDir}
          if test $status -ne 0
            __nx_rollback_commit $pre_check_head
            __nx_fail "Flake check failed — likely a syntax or type error in the changed .nix files (see above)."
            return 1
          end
          __nx_ok

          __nx_stage "Building the new configuration"
          set -l build_dir (mktemp -d)
          pushd $build_dir
          # &| (not |&, that's bash/zsh) sends stderr into the pipe too, so
          # nom sees the full build log; $pipestatus[1] is nixos-rebuild's
          # own exit code — $status after a pipe would be nom's instead,
          # which could mask a real build failure as success
          nixos-rebuild build --flake ${repoDir}#${hostName} &| ${pkgs.nix-output-monitor}/bin/nom
          set -l build_status $pipestatus[1]
          popd
          if test $build_status -ne 0
            __nx_rollback_commit $pre_check_head
            rm -rf $build_dir
            __nx_fail "Build failed — likely a bad option value, a missing package, or a build error (see the log above)."
            return 1
          end
          __nx_ok

          __nx_commit_if_dirty "nx: auto-commit flake.lock changes from deploy"

          __nx_stage "Changes"
          ${pkgs.nvd}/bin/nvd diff /run/current-system $build_dir/result

          __nx_stage "Switching to the new configuration"
          sudo nix-env -p /nix/var/nix/profiles/system --set $build_dir/result
          and sudo $build_dir/result/bin/switch-to-configuration switch
          set -l switch_status $status
          rm -rf $build_dir
          if test $switch_status -ne 0
            __nx_fail "Switch failed — the new generation built but activation broke something (a service failing to start?); check 'systemctl status' and the output above."
          else
            __nx_ok
          end
          return $switch_status
        case '*'
          git -C ${repoDir} reset >/dev/null
          echo "Aborted."
          return 1
      end
    '';
  };
}
