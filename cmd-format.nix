{
  repoDir,
  pkgs,
  ...
}: {
  # -- nx: format --

  programs.fish.functions = {
    __nx_cmd_format = ''
      __nx_stage "Sorting modules/packages.nix"
      __nx_sort_packages
      __nx_ok

      __nx_stage "Formatting .nix files"
      __nx_format
      if test $status -ne 0
        __nx_fail "Formatting failed — likely a syntax error in one of the .nix files; run 'alejandra ${repoDir}' to see which."
        return 1
      end
      __nx_ok

      __nx_stage "Checking for lint issues (statix)"
      ${pkgs.statix}/bin/statix check ${repoDir}
      if test $status -eq 0
        __nx_ok
      else
        __nx_warn "issues found — see above"
      end

      __nx_stage "Checking for dead code (deadnix)"
      ${pkgs.deadnix}/bin/deadnix -f ${repoDir}
      if test $status -eq 0
        __nx_ok
      else
        __nx_warn "issues found — see above"
      end
    '';
  };
}
