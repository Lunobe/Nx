{
  repoDir,
  lib,
  ...
}: let
  # single source of truth for the top-level subcommand list, generating
  # the completions below so `nx <Tab>` can't drift from what exists.
  # __nx_help/__nx_help_short stay hand-written prose — their aligned
  # formatting doesn't map onto a flat list, and a stale line there is a
  # readability issue, not a behavioral one.
  nxCommands = [
    {
      name = "format";
      desc = "sort packages.nix and format/lint .nix files";
    }
    {
      name = "deploy";
      desc = "check, build and switch to the flake";
    }
    {
      name = "up";
      desc = "update flake inputs, then deploy (skipped if unchanged)";
    }
    {
      name = "clean";
      desc = "garbage-collect the system (defaults to --keep 7)";
    }
    {
      name = "list";
      desc = "list packages currently in modules/packages.nix";
    }
    {
      name = "install";
      desc = "add a package to modules/packages.nix and deploy";
    }
    {
      name = "uninstall";
      desc = "remove a package from modules/packages.nix and deploy";
    }
    {
      name = "secret";
      desc = "edit an agenix-encrypted secret";
    }
    {
      name = "config";
      desc = "open config files in $EDITOR";
    }
    {
      name = "vm";
      desc = "manage libvirt VM backups on R2 (restic)";
    }
    {
      name = "push";
      desc = "commit and push changes";
    }
    {
      name = "nuke-history";
      desc = "squash all history into one commit and force-push";
    }
    {
      name = "doctor";
      desc = "format + up (which deploys) + clean + push";
    }
    {
      name = "search";
      desc = "search nixpkgs packages, or inspect a NixOS option";
    }
  ];
in {
  # -- nx: dispatcher, help, completions --

  programs.fish.functions = {
    __nx_help = ''
      echo "nx — manage the NixOS configuration in ${repoDir}"
      echo ""
      echo "Usage: nx <command>"
      echo ""
      echo "Commands:"
      set -l sep "  ────────────────────────────────────────────────────────────────────────"
      echo ""
      echo $sep
      echo ""
      echo "  format        sort modules/packages.nix and format/lint every .nix file"
      echo "                1. sort modules/packages.nix"
      echo "                2. format every .nix file (alejandra)"
      echo "                3. lint for antipatterns (statix) — prints findings, never fails"
      echo "                4. lint for dead code (deadnix) — prints findings, never fails"
      echo ""
      echo $sep
      echo ""
      echo "  deploy        build and switch to the flake"
      echo "                1. stage everything (git add -A, no commit yet); if anything"
      echo "                   changed, show the diff and ask to proceed"
      echo "                2. commit the staged changes"
      echo "                3. nix flake check; nixos-rebuild build, into a scratch dir"
      echo "                4. if either fails: undo the commit from step 2 (leaving the"
      echo "                   changes staged) and stop — nothing broken ever lands in"
      echo "                   history"
      echo "                5. commit again if the build touched flake.lock, then print"
      echo "                   the closure diff (nvd) and switch to the new generation"
      echo ""
      echo $sep
      echo ""
      echo "  up            update flake inputs, then deploy"
      echo "                1. show pending local changes and ask to proceed"
      echo "                2. commit them (\"nx: auto-commit before update\")"
      echo "                3. nix flake update"
      echo "                4. if flake.lock didn't change, print that it's already"
      echo "                   up to date and stop — nothing to deploy"
      echo "                5. nx deploy"
      echo ""
      echo $sep
      echo ""
      echo "  clean --keep <n> | --all"
      echo "                garbage-collect the Nix store"
      echo "                every deploy/update leaves the previous system generation"
      echo "                and its packages behind in /nix/store, in case you need to"
      echo "                roll back — this deletes old generations and any store paths"
      echo "                no longer referenced by what's left, freeing disk space; you"
      echo "                lose the ability to roll back to whatever gets deleted"
      echo "                --keep <n>  delete generations older than <n> days"
      echo "                --all       delete all old generations (full gc)"
      echo "                no flags defaults to --keep 7"
      echo ""
      echo $sep
      echo ""
      echo "  list          print the packages currently in modules/packages.nix"
      echo ""
      echo $sep
      echo ""
      echo "  install <name>"
      echo "                add a package and deploy"
      echo "                1. try <name> as an exact attribute in the locked nixpkgs"
      echo "                2. if that fails, search nixpkgs and let you pick a match"
      echo "                   by number (cancel with an empty answer)"
      echo "                3. insert it into modules/packages.nix (skip if already there)"
      echo "                4. nx deploy"
      echo ""
      echo $sep
      echo ""
      echo "  uninstall <name>"
      echo "                remove a package and deploy (tab-completes against the"
      echo "                current package list)"
      echo "                1. remove <name> from modules/packages.nix (must already"
      echo "                   be listed)"
      echo "                2. nx deploy"
      echo ""
      echo $sep
      echo ""
      echo "  secret <name>"
      echo "                edit an agenix-encrypted secret (tab-completes against"
      echo "                secrets/*.age; run with no name to list them)"
      echo "                1. look up secrets/<name>.age"
      echo "                2. decrypt with the bootstrap identity and open in \$EDITOR"
      echo "                   (via agenix, needs sudo)"
      echo "                3. re-encrypt on save; run 'nx deploy' afterwards to apply"
      echo ""
      echo $sep
      echo ""
      echo "  config        walk the import graph from flake.nix and open every file"
      echo "                it references in \$EDITOR"
      echo ""
      echo $sep
      echo ""
      echo "  vm push       back up the libvirt VM state to Cloudflare R2 (restic)"
      echo "                (unrelated to 'nx push', which commits/pushes this git repo)"
      echo "                1. check every VM is shut off, with no managed-save image"
      echo "                2. load R2/restic credentials from agenix; initialize the"
      echo "                   restic repository if this is the first run"
      echo "                3. restic backup (sudo) of /var/lib/libvirt/{images,swtpm,"
      echo "                   secrets,qemu/nvram,qemu/snapshot} and /var/lib/swtpm-localca,"
      echo "                   skipping *.iso (only changed data is uploaded)"
      echo "                VM/network definitions are not included — they come from"
      echo "                modules/libvirt in the flake"
      echo ""
      echo $sep
      echo ""
      echo "  vm pull [id]  restore a libvirt VM backup from Cloudflare R2 (restic)"
      echo "                1. load R2/restic credentials from agenix and clear any stale"
      echo "                   restic lock from a previously killed push/pull"
      echo "                2. check every VM is shut off; ask to confirm if disk images"
      echo "                   already exist (they will be overwritten)"
      echo "                3. stop libvirtd, restic restore into /var/lib/libvirt"
      echo "                   (overwrite only, nothing is deleted), start libvirtd"
      echo "                on a new machine run 'nx deploy' first so the VMs are defined"
      echo "                defaults to the latest backup; pass a snapshot ID (see"
      echo "                'nx vm log') to restore an older one instead"
      echo ""
      echo $sep
      echo ""
      echo "  vm log        list every libvirt VM backup in R2, with its date and ID"
      echo ""
      echo $sep
      echo ""
      echo "  vm del <id>   permanently delete one libvirt VM backup from R2 (asks to"
      echo "                confirm) — find the ID with 'nx vm log' first"
      echo ""
      echo $sep
      echo ""
      echo "  push          commit pending changes and push to the remote"
      echo "                1. show pending local changes and ask to proceed"
      echo "                2. commit them (\"nx: update\")"
      echo "                3. git push"
      echo ""
      echo $sep
      echo ""
      echo "  nuke-history  squash all git history into one \"squashed into single commit\" and"
      echo "                force-push — rewrites remote history; a full backup is"
      echo "                saved locally first, but restoring from it is manual"
      echo "                1. warn about the consequences; show which remote will be"
      echo "                   force-pushed to"
      echo "                2. show local changes and gitignored-but-tracked files that"
      echo "                   would be swept in / dropped"
      echo "                3. ask to confirm by typing NUKE"
      echo "                4. back up the full current history to"
      echo "                   ~/.nx-backups/nuke-history/ (outside the repo, so it"
      echo "                   survives even if the repo itself is later removed) as a"
      echo "                   timestamped git bundle"
      echo "                5. squash everything into one orphan commit, replacing"
      echo "                   the branch"
      echo "                6. force-push, overwriting the remote's history"
      echo ""
      echo $sep
      echo ""
      echo "  doctor        nx format, update flake inputs, nx deploy, then nx clean"
      echo "                --keep 7, then nx push, in that order"
      echo ""
      echo $sep
      echo ""
      echo "  search [search|option|meta|lib] <name>"
      echo "                search <name>         (default) nix search nixpkgs <name>"
      echo "                option <name>         nixos-option's exact lookup, falling"
      echo "                                       back to a substring search across"
      echo "                                       all option names/descriptions"
      echo "                meta <name>           a package's full metadata, as JSON"
      echo "                lib <name>            nixpkgs/lib function docs and inline"
      echo "                                       comments (manix; builds a local cache"
      echo "                                       on first use)"
      echo ""
      echo $sep
      echo ""
    '';

    __nx_help_short = ''
      echo "nx — manage the NixOS configuration in ${repoDir}"
      echo ""
      echo "Usage: nx <command>"
      echo ""
      echo "  format        sort modules/packages.nix and format/lint every .nix file"
      echo "  deploy        build and switch to the flake"
      echo "  up            update flake inputs, then deploy (skipped if nothing changed)"
      echo "  clean         --keep <n> | --all — garbage-collect the Nix store"
      echo "  list          print the packages currently in modules/packages.nix"
      echo "  install       add a package and deploy"
      echo "  uninstall     remove a package and deploy"
      echo "  secret        edit an agenix-encrypted secret"
      echo "  search        [search|option|meta|lib] <name>"
      echo "  config        open every file in the flake's import graph in \$EDITOR"
      echo "  vm push|pull|log|del  manage libvirt VM backups on Cloudflare R2 (restic)"
      echo "  push          commit pending changes and push to the remote"
      echo "  nuke-history  squash all git history into one commit and force-push"
      echo "  doctor        nx format, update flake inputs, deploy, clean, push, in that order"
      echo ""
      echo "Run 'nx --help' for details."
    '';

    nx = ''
      switch "$argv[1]"
        case format
          __nx_cmd_format $argv
        case deploy
          __nx_cmd_deploy $argv
        case up
          __nx_cmd_up $argv
        case clean
          __nx_cmd_clean $argv
        case list
          __nx_list_packages
        case install
          __nx_cmd_install $argv
        case uninstall
          __nx_cmd_uninstall $argv
        case secret
          __nx_cmd_secret $argv
        case search
          __nx_cmd_search $argv
        case config
          __nx_cmd_config $argv
        case vm
          __nx_cmd_vm $argv
        case push
          __nx_cmd_push $argv
        case nuke-history
          __nx_cmd_nuke_history $argv
        case doctor
          __nx_cmd_doctor $argv
        case --help
          __nx_help
        case -h
          __nx_help_short
        case '*'
          __nx_fail "Unknown command '$argv[1]'."
          echo "Run 'nx -h' for brief usage, or 'nx --help' for the full details."
          return 1
      end
    '';
  };

  programs.fish.completions.nx = ''
    complete -c nx -f
    ${lib.concatMapStrings (c: "complete -c nx -n __fish_use_subcommand -a ${c.name} -d '${c.desc}'\n") nxCommands}
    complete -c nx -n "__fish_seen_subcommand_from clean" -l keep -d 'delete generations older than N days' -x
    complete -c nx -n "__fish_seen_subcommand_from clean" -l all -d 'delete all old generations (full gc)'
    complete -c nx -n "__fish_seen_subcommand_from uninstall" -a "(__nx_list_packages)" -d 'installed package'
    complete -c nx -n "__fish_seen_subcommand_from secret" -a "(__nx_list_secrets)" -d 'secret'
    complete -c nx -n "__fish_seen_subcommand_from vm" -a push -d 'back up libvirt VM state to R2'
    complete -c nx -n "__fish_seen_subcommand_from vm" -a pull -d 'restore libvirt VM state from R2 (latest by default)'
    complete -c nx -n "__fish_seen_subcommand_from vm" -a log -d 'list libvirt VM backups in R2 with dates/IDs'
    complete -c nx -n "__fish_seen_subcommand_from vm" -a del -d 'permanently delete one libvirt VM backup from R2'
    complete -c nx -n "__fish_seen_subcommand_from search" -a option -d 'inspect a NixOS option (e.g. nx search option programs.niri.enable)'
    complete -c nx -n "__fish_seen_subcommand_from search" -a search -d 'search nixpkgs packages'
    complete -c nx -n "__fish_seen_subcommand_from search" -a meta -d 'show a package full metadata (e.g. nx search meta niri)'
    complete -c nx -n "__fish_seen_subcommand_from search" -a lib -d 'search nixpkgs/lib function docs and comments (e.g. nx search lib optionalString)'
    complete -c nx -n __fish_use_subcommand -a '--help' -d 'show detailed help'
    complete -c nx -n __fish_use_subcommand -a '-h' -d 'show brief help'
  '';
}
