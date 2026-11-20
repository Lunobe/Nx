{
  repoDir,
  pkgs,
  ...
}: {
  # -- nx: helpers for introspecting/editing the flake's own files --

  programs.fish.functions = {
    __nx_config_files = ''
      # walks the import graph from flake.nix via relative-path references,
      # so new modules are picked up automatically. a reference may be a
      # .nix file or a bare directory (resolved to its default.nix);
      # anything else (a secret path, a fish alias like "../..") is skipped
      set -l root ${repoDir}
      set -l seen $root/flake.nix
      set -l queue $root/flake.nix
      while test (count $queue) -gt 0
        set -l f $queue[1]
        set -e queue[1]
        set -l dir (path dirname $f)
        for rel in (sed -E 's/#.*$//' $f 2>/dev/null | grep -ohE '\.\.?/[A-Za-z0-9_./-]+')
          set -l full (realpath -m $dir/$rel)
          if test -d $full
            set full $full/default.nix
            if not test -e $full
              continue
            end
          else if not string match -q '*.nix' $full
            continue
          end
          if not contains $full $seen
            set -a seen $full
            set -a queue $full
          end
        end
      end
      for f in $seen
        echo $f
      end
    '';

    __nx_packages_bounds = ''
      set -l file ${repoDir}/modules/packages.nix
      set -l start (grep -n '^  home\.packages = with pkgs; \[$' $file | head -n1 | cut -d: -f1)
      if test -z "$start"
        return 1
      end
      # search only after $start, not the whole file — otherwise an
      # earlier "];" belonging to some other list would be picked up
      set -l tail_start (math $start + 1)
      set -l end (sed -n "$tail_start,\$ p" $file | grep -n '^  \];$' | head -n1 | cut -d: -f1)
      if test -z "$end"
        return 1
      end
      set end (math $end + $start)
      echo $start
      echo $end
    '';

    __nx_sort_packages = ''
      set -l file ${repoDir}/modules/packages.nix
      set -l bounds (__nx_packages_bounds)
      or begin
        __nx_fail "Could not find the 'home.packages = with pkgs; [ ... ];' block in modules/packages.nix — has its format changed?"
        return 1
      end
      set -l items_start (math $bounds[1] + 1)
      set -l items_end (math $bounds[2] - 1)
      set -l tmp (mktemp)
      begin
        sed -n "1,$bounds[1] p" $file
        sed -n "$items_start,$items_end p" $file | sort
        sed -n "$bounds[2],\$ p" $file
      end > $tmp
      mv $tmp $file
    '';

    __nx_format = ''
      ${pkgs.alejandra}/bin/alejandra -q ${repoDir}
    '';

    __nx_list_packages = ''
      set -l file ${repoDir}/modules/packages.nix
      set -l bounds (__nx_packages_bounds)
      or begin
        __nx_fail "Could not find the 'home.packages = with pkgs; [ ... ];' block in modules/packages.nix — has its format changed?"
        return 1
      end
      set -l items_start (math $bounds[1] + 1)
      set -l items_end (math $bounds[2] - 1)
      sed -n "$items_start,$items_end p" $file | string trim
    '';

    __nx_list_secrets = ''
      # from secrets.nix's keys, not a directory listing — this correctly
      # excludes identity.txt.age (the root identity, has no secrets.nix
      # entry). comments are stripped first since the file's own header
      # comment shows an example key that would otherwise match too
      sed -E 's/#.*$//' ${repoDir}/secrets/secrets.nix 2>/dev/null \
        | grep -oE '"[^"]+\.age"' \
        | tr -d '"' | sed 's/\.age$//' | sort -u
    '';
  };
}
