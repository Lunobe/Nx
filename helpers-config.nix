{
  repoDir,
  pkgs,
  ...
}: {
  # -- nx: helpers for introspecting/editing the flake's own files --

  programs.fish.functions = {
    __nx_config_files = ''
      # walk the import graph starting at flake.nix, following relative-path
      # references, so new modules are picked up automatically. a reference
      # may be a .nix file directly, or a bare directory (e.g. "./nx", the
      # nix equivalent of "./nx/default.nix") — resolved below. references
      # that are neither (e.g. "./secrets/foo.age", a fish alias like
      # "../..") are silently skipped
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
      or return 0
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
      or return 0
      set -l items_start (math $bounds[1] + 1)
      set -l items_end (math $bounds[2] - 1)
      sed -n "$items_start,$items_end p" $file | string trim
    '';

    __nx_list_secrets = ''
      # from secrets.nix's keys, not a directory listing — secrets/identity.txt.age
      # is the root identity (encrypted with a passphrase, no secrets.nix entry),
      # not a secret manageable this way, so it's correctly excluded.
      # comments are stripped first — the file's own header comment shows
      # a "name.age".publicKeys = [...] example that would otherwise match too
      sed -E 's/#.*$//' ${repoDir}/secrets/secrets.nix 2>/dev/null \
        | grep -oE '"[^"]+\.age"' \
        | tr -d '"' | sed 's/\.age$//' | sort -u
    '';
  };
}
