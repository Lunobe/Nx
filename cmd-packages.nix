{
  repoDir,
  hostName,
  ...
}: {
  # -- nx: list, install, uninstall --

  programs.fish.functions = {
    __nx_cmd_install = ''
      set -l query "$argv[2]"
      if test -z "$query"
        echo "Usage: nx install <package>"
        return 1
      end

      set -l pkg_attr
      # resolve against the locked flake's own nixpkgs (not the global
      # flake registry) so an exact match here means the package really
      # exists in the nixpkgs revision that will actually get deployed
      set -l is_derivation (nix eval --raw --apply '(x: if (x.type or null) == "derivation" then "derivation" else "other")' "${repoDir}#nixosConfigurations.${hostName}.pkgs.$query" 2>/dev/null)
      if test "$is_derivation" = derivation
        set pkg_attr $query
      else
        # the registry here is fine — this is just discovery, and a
        # full recursive nix search over nixosConfigurations.*.pkgs
        # fails outright on nixpkgs's handful of throwing attributes
        __nx_stage "No exact package '$query' — searching nixpkgs"
        set -l json (nix search nixpkgs $query --json 2>/dev/null)
        set -l search_status $status
        # `,` is nix-index-database's comma shorthand (programs.nix-index-database.comma.enable
        # in home.nix) — runs jq via a throwaway nix-shell without installing it
        set -l lines (echo $json | , jq -r '
          to_entries[]
          | (.key | sub("^legacyPackages\\\\.[^.]+\\\\."; "")) as $name
          | "\($name)\t\($name) (\(.value.version)) - \(.value.description)"
        ')
        if test (count $lines) -eq 0
          if test $search_status -ne 0
            __nx_fail "Searching nixpkgs failed — likely no network access or the nixpkgs input is unreachable."
          else
            echo "No packages found for '$query'."
          end
          return 1
        end
        set -l names
        set -l descs
        for line in $lines
          set -l parts (string split -m1 \t -- $line)
          set -a names $parts[1]
          set -a descs $parts[2]
        end
        for i in (seq (count $names))
          echo "$i) $descs[$i]"
        end
        echo ""
        read -l -P "Pick a number to install (Enter to cancel): " choice
        if test -z "$choice"
          echo "Aborted."
          return 1
        end
        if not string match -qr '^[0-9]+$' -- "$choice"
          echo "Invalid choice."
          return 1
        end
        if test "$choice" -lt 1 -o "$choice" -gt (count $names)
          echo "Invalid choice."
          return 1
        end
        set pkg_attr $names[$choice]
      end

      if grep -qxF "    $pkg_attr" ${repoDir}/modules/packages.nix
        echo "'$pkg_attr' is already in packages.nix."
        return 1
      end

      __nx_stage "Adding '$pkg_attr' to packages.nix"
      sed -i "/^  \];\$/i\\    $pkg_attr" ${repoDir}/modules/packages.nix
      __nx_ok

      nx deploy
    '';

    __nx_cmd_uninstall = ''
      set -l pkg_attr "$argv[2]"
      if test -z "$pkg_attr"
        echo "Usage: nx uninstall <package>"
        return 1
      end

      if not grep -qxF "    $pkg_attr" ${repoDir}/modules/packages.nix
        echo "'$pkg_attr' is not in packages.nix."
        return 1
      end

      __nx_stage "Removing '$pkg_attr' from packages.nix"
      set -l tmp (mktemp)
      grep -vxF "    $pkg_attr" ${repoDir}/modules/packages.nix > $tmp
      mv $tmp ${repoDir}/modules/packages.nix
      __nx_ok

      nx deploy
    '';
  };
}
