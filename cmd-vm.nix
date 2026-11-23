{pkgs, ...}: let
  restic = "${pkgs.restic}/bin/restic";
  virsh = "${pkgs.libvirt}/bin/virsh -c qemu:///system";
  vmTag = "libvirt";
  vmHost = "vm-library";
  libvirtPaths = [
    "/var/lib/libvirt/images"
    "/var/lib/libvirt/qemu/nvram"
    "/var/lib/libvirt/qemu/snapshot"
    "/var/lib/libvirt/swtpm"
    "/var/lib/libvirt/secrets"
    "/var/lib/swtpm-localca"
  ];
  pathList = builtins.concatStringsSep " " (map (p: ''"${p}"'') libvirtPaths);
  sudoKeepEnv = "AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_DEFAULT_REGION,RESTIC_REPOSITORY,RESTIC_PASSWORD_FILE";
in {
  # -- nx: vm — push/pull/log/del the libvirt VM state (disks, NVRAM, TPM,
  # snapshot metadata, secrets) on Cloudflare R2 via restic. VM and network
  # definitions are not backed up: they come from the flake (modules/libvirt).
  # Kept separate — unlike everything else nx touches, this doesn't
  # read/write the flake repo; it uses the r2Credentials/resticPassword
  # agenix secrets.
  #
  # The R2/restic env vars are loaded inline in each of push/pull/log/del
  # below, not factored into a shared helper — a helper's `set -lx` does
  # NOT survive back to its caller in fish (confirmed by testing), so a
  # single "load everything" helper would silently leave every command
  # running with no credentials set.

  programs.fish.functions = {
    # shared readability check used by every vm subcommand before loading
    # R2/restic credentials
    __nx_require_readable = ''
      if not test -r $argv[1]
        __nx_fail "$argv[2]"
        return 1
      end
    '';

    # looks up one KEY from /run/agenix/r2Credentials's KEY=VALUE lines and
    # prints it over stdout — a command substitution, unlike a variable
    # assignment, crosses the function-call boundary fine
    __nx_vm_r2_field = ''
      set -l cred_file /run/agenix/r2Credentials
      for line in (cat $cred_file 2>/dev/null)
        test -z "$line"
        and continue
        set -l parts (string split -m1 "=" -- $line)
        if test "$parts[1]" = "$argv[1]"
          echo $parts[2]
          return 0
        end
      end
      return 1
    '';

    # every libvirt domain must be shut off with no managed-save image: a disk
    # copied while running is inconsistent, and a managed save keeps RAM state
    # outside the backed-up paths
    __nx_vm_require_stopped = ''
      if not ${virsh} version >/dev/null 2>&1
        __nx_fail "Could not reach libvirt (qemu:///system) — is libvirtd running?"
        return 1
      end
      for d in (${virsh} list --all --name | string match -v "")
        set -l state (${virsh} domstate $d | string match -v "" | string trim)
        if test "$state" != "shut off"
          __nx_fail "$d is $state — shut it down first."
          return 1
        end
        if ${virsh} dominfo $d | string match -rq 'Managed save:\s+yes'
          __nx_fail "$d has a managed-save image — start and shut it down properly (or run 'virsh managedsave-remove $d') first."
          return 1
        end
      end
    '';

    # backup paths that exist on this machine, one per line
    __nx_vm_paths = ''
      for p in ${pathList}
        if test -e $p
          echo $p
        else
          __nx_warn "$p does not exist — skipping it." >&2
        end
      end
    '';

    __nx_cmd_vm = ''
      switch "$argv[2]"
        case push
          __nx_cmd_vm_push
        case pull
          __nx_cmd_vm_pull $argv
        case log
          __nx_cmd_vm_log
        case del
          __nx_cmd_vm_del $argv
        case '*'
          echo "Usage: nx vm push | nx vm pull [id] | nx vm log | nx vm del <id>"
          return 1
      end
    '';

    __nx_cmd_vm_push = ''
      __nx_stage "Checking all VMs are shut off"
      __nx_vm_require_stopped
      or return 1
      __nx_ok

      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      __nx_require_readable $cred_file "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
      or return 1
      __nx_require_readable $pw_file "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
      or return 1

      set -lx AWS_ACCESS_KEY_ID (__nx_vm_r2_field R2_ACCESS_KEY_ID)
      set -lx AWS_SECRET_ACCESS_KEY (__nx_vm_r2_field R2_SECRET_ACCESS_KEY)
      set -l r2_endpoint (__nx_vm_r2_field R2_ENDPOINT)
      set -l r2_bucket (__nx_vm_r2_field R2_BUCKET)
      if test -z "$AWS_ACCESS_KEY_ID" -o -z "$AWS_SECRET_ACCESS_KEY" -o -z "$r2_endpoint" -o -z "$r2_bucket"
        __nx_fail "$cred_file is missing one or more of R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_ENDPOINT/R2_BUCKET."
        return 1
      end
      # required by Cloudflare R2's S3-compatible API
      set -lx AWS_DEFAULT_REGION auto
      set -lx RESTIC_REPOSITORY "s3:$r2_endpoint/$r2_bucket"
      set -lx RESTIC_PASSWORD_FILE $pw_file

      __nx_stage "Checking the restic repository"
      ${restic} snapshots >/dev/null 2>&1
      or ${restic} init
      if test $status -ne 0
        __nx_fail "Could not reach or initialize the restic repository at $RESTIC_REPOSITORY — check network access and the R2 credentials."
        return 1
      end
      __nx_ok

      set -l paths (__nx_vm_paths)
      if test (count $paths) -eq 0
        __nx_fail "None of the libvirt state directories exist on this machine — nothing to back up."
        return 1
      end

      # root-only directories, so restic runs under sudo; ISOs are re-downloadable
      __nx_stage "Backing up libvirt state to R2 (only changed data is uploaded after the first run)"
      sudo --preserve-env=${sudoKeepEnv} ${restic} backup $paths --exclude '*.iso' --host ${vmHost} --tag ${vmTag}
      if test $status -ne 0
        __nx_fail "restic backup failed — check network access and the R2 credentials (see restic's own output above)."
        return 1
      end
      __nx_ok
    '';

    __nx_cmd_vm_pull = ''
      set -l target_snapshot latest
      if test -n "$argv[3]"
        set target_snapshot "$argv[3]"
      end

      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      __nx_require_readable $cred_file "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
      or return 1
      __nx_require_readable $pw_file "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
      or return 1

      set -lx AWS_ACCESS_KEY_ID (__nx_vm_r2_field R2_ACCESS_KEY_ID)
      set -lx AWS_SECRET_ACCESS_KEY (__nx_vm_r2_field R2_SECRET_ACCESS_KEY)
      set -l r2_endpoint (__nx_vm_r2_field R2_ENDPOINT)
      set -l r2_bucket (__nx_vm_r2_field R2_BUCKET)
      if test -z "$AWS_ACCESS_KEY_ID" -o -z "$AWS_SECRET_ACCESS_KEY" -o -z "$r2_endpoint" -o -z "$r2_bucket"
        __nx_fail "$cred_file is missing one or more of R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_ENDPOINT/R2_BUCKET."
        return 1
      end
      # required by Cloudflare R2's S3-compatible API
      set -lx AWS_DEFAULT_REGION auto
      set -lx RESTIC_REPOSITORY "s3:$r2_endpoint/$r2_bucket"
      set -lx RESTIC_PASSWORD_FILE $pw_file

      __nx_stage "Checking the restic repository"
      ${restic} snapshots >/dev/null 2>&1
      if test $status -ne 0
        __nx_fail "Could not reach the restic repository at $RESTIC_REPOSITORY, or nothing has been pushed yet — check network access and the R2 credentials, or run 'nx vm push' first on the machine that has the VMs."
        return 1
      end
      __nx_ok

      # best-effort cleanup of a stale lock left by a previously killed
      # push/pull — restic unlock is a no-op if there's nothing to unlock
      ${restic} unlock >/dev/null 2>&1

      if ${virsh} version >/dev/null 2>&1
        __nx_stage "Checking all VMs are shut off"
        __nx_vm_require_stopped
        or return 1
        __nx_ok
      end

      set -l existing (sudo find /var/lib/libvirt/images -maxdepth 1 -name '*.qcow2' 2>/dev/null)
      if test (count $existing) -gt 0
        __nx_warn "libvirt disk images already exist on this machine — restoring will OVERWRITE them with the backup's versions (files not in the backup are left alone)."
        __nx_confirm "Continue?"
        or begin
          echo "Aborted."
          return 1
        end
      end

      # libvirtd caches nvram/snapshot/TPM state, so it must be down while those files are replaced
      set -l units libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket
      __nx_stage "Stopping libvirtd"
      sudo systemctl stop $units
      __nx_ok

      __nx_stage "Restoring $target_snapshot from R2 into /var/lib/libvirt (existing files overwritten, nothing deleted)"
      set -l includes
      for p in ${pathList}
        set -a includes --include $p
      end
      set -l selector
      if test "$target_snapshot" = latest
        # --host/--tag pick the right snapshot out of the repo for "latest" —
        # irrelevant (and not applied) once you already have one specific ID
        set selector --host ${vmHost} --tag ${vmTag}
      end
      sudo --preserve-env=${sudoKeepEnv} ${restic} restore $selector $target_snapshot --target / --sparse $includes
      set -l restore_status $status

      sudo systemctl start libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd.service
      if test $restore_status -ne 0
        __nx_fail "restic restore failed — check the ID is correct (run 'nx vm log' to list available backups), and that network access and the R2 credentials are OK (see restic's own output above)."
        return 1
      end
      __nx_ok
    '';

    __nx_cmd_vm_log = ''
      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      __nx_require_readable $cred_file "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
      or return 1
      __nx_require_readable $pw_file "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
      or return 1

      set -lx AWS_ACCESS_KEY_ID (__nx_vm_r2_field R2_ACCESS_KEY_ID)
      set -lx AWS_SECRET_ACCESS_KEY (__nx_vm_r2_field R2_SECRET_ACCESS_KEY)
      set -l r2_endpoint (__nx_vm_r2_field R2_ENDPOINT)
      set -l r2_bucket (__nx_vm_r2_field R2_BUCKET)
      if test -z "$AWS_ACCESS_KEY_ID" -o -z "$AWS_SECRET_ACCESS_KEY" -o -z "$r2_endpoint" -o -z "$r2_bucket"
        __nx_fail "$cred_file is missing one or more of R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_ENDPOINT/R2_BUCKET."
        return 1
      end
      set -lx AWS_DEFAULT_REGION auto
      set -lx RESTIC_REPOSITORY "s3:$r2_endpoint/$r2_bucket"
      set -lx RESTIC_PASSWORD_FILE $pw_file

      __nx_stage "Backup history for libvirt VMs in R2"
      set -l log_output (${restic} snapshots --host ${vmHost} --tag ${vmTag} 2>&1)
      set -l log_status $status
      # restic's own exit code for "repository does not exist yet" — the
      # expected state before the first ever 'nx vm push', not an error
      if test $log_status -eq 10
        echo "No backups yet — run 'nx vm push' first."
        return 0
      else if test $log_status -ne 0
        __nx_fail "Could not reach the restic repository at $RESTIC_REPOSITORY — check network access and the R2 credentials."
        printf '%s\n' $log_output
        return 1
      end
      printf '%s\n' $log_output
    '';

    __nx_cmd_vm_del = ''
      set -l id "$argv[3]"
      if test -z "$id"
        echo "Usage: nx vm del <snapshot-id>"
        echo "Run 'nx vm log' to see available snapshot IDs."
        return 1
      end

      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      __nx_require_readable $cred_file "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
      or return 1
      __nx_require_readable $pw_file "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
      or return 1

      set -lx AWS_ACCESS_KEY_ID (__nx_vm_r2_field R2_ACCESS_KEY_ID)
      set -lx AWS_SECRET_ACCESS_KEY (__nx_vm_r2_field R2_SECRET_ACCESS_KEY)
      set -l r2_endpoint (__nx_vm_r2_field R2_ENDPOINT)
      set -l r2_bucket (__nx_vm_r2_field R2_BUCKET)
      if test -z "$AWS_ACCESS_KEY_ID" -o -z "$AWS_SECRET_ACCESS_KEY" -o -z "$r2_endpoint" -o -z "$r2_bucket"
        __nx_fail "$cred_file is missing one or more of R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_ENDPOINT/R2_BUCKET."
        return 1
      end
      set -lx AWS_DEFAULT_REGION auto
      set -lx RESTIC_REPOSITORY "s3:$r2_endpoint/$r2_bucket"
      set -lx RESTIC_PASSWORD_FILE $pw_file

      __nx_stage "Looking up $id"
      set -l lookup_output (${restic} snapshots $id 2>&1)
      if test $status -ne 0
        __nx_fail "No snapshot found matching '$id' — run 'nx vm log' to see available IDs."
        return 1
      end
      printf '%s\n' $lookup_output

      __nx_confirm "Permanently delete this backup from R2? This cannot be undone."
      or begin
        echo "Aborted."
        return 1
      end

      __nx_stage "Deleting $id"
      ${restic} forget $id --prune
      if test $status -ne 0
        __nx_fail "Deletion failed — check network access and the R2 credentials (see restic's own output above)."
        return 1
      end
      __nx_ok
    '';
  };
}
