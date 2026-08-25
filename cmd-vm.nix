{pkgs, ...}: {
  # -- nx: vm — push/pull/log/del the ~/vmware VM library on Cloudflare R2 via
  # restic. Kept separate since, unlike everything else nx touches, this
  # doesn't read/write the flake repo — it moves data between ~/vmware and
  # an R2 bucket, using the r2Credentials/resticPassword agenix secrets.
  #
  # The R2/restic env vars (AWS_ACCESS_KEY_ID etc.) are loaded inline, near-
  # identically, at the top of every one of push/pull/log/del below rather
  # than factored into one shared helper — a helper function's `set -lx`
  # does NOT survive back to its caller in fish (each call gets its own
  # local-variable frame, popped on return), confirmed by testing it
  # directly, so a single "load everything" helper would silently leave
  # every one of these commands running with no credentials set at all.

  programs.fish.functions = {
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
      set -l vmware_dir $HOME/vmware
      set -l snapshot_dir $HOME/.nx-vm-snapshot

      __nx_stage "Checking ~/vmware is a btrfs subvolume"
      # needs sudo — querying subvolume info is a privileged btrfs ioctl,
      # confirmed by 'ERROR: Could not search B-tree: Operation not
      # permitted' when tried as a plain user, even on an owned subvolume
      if not sudo btrfs subvolume show $vmware_dir >/dev/null 2>&1
        __nx_fail "$vmware_dir is not a btrfs subvolume — nx vm push snapshots it read-only before backing up. Check the fileSystems entry for $vmware_dir in configuration.nix (subvol=@vmware)."
        return 1
      end
      __nx_ok

      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      if not test -r $cred_file
        __nx_fail "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
        return 1
      end
      if not test -r $pw_file
        __nx_fail "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
        return 1
      end

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
      ${pkgs.restic}/bin/restic snapshots >/dev/null 2>&1
      or ${pkgs.restic}/bin/restic init
      if test $status -ne 0
        __nx_fail "Could not reach or initialize the restic repository at $RESTIC_REPOSITORY — check network access and the R2 credentials."
        return 1
      end
      __nx_ok

      if test -e $snapshot_dir
        __nx_warn "Leftover snapshot at $snapshot_dir from a previous run — removing it first."
        sudo btrfs subvolume delete $snapshot_dir
      end

      __nx_stage "Snapshotting ~/vmware (read-only, for a consistent backup)"
      sudo btrfs subvolume snapshot -r $vmware_dir $snapshot_dir
      if test $status -ne 0
        __nx_fail "Snapshot failed — check free space and that $vmware_dir is really a btrfs subvolume."
        return 1
      end
      __nx_ok

      __nx_stage "Backing up to R2 (only changed data is uploaded after the first run)"
      ${pkgs.restic}/bin/restic backup $snapshot_dir --host vm-library --tag vm
      set -l backup_status $status
      if test $backup_status -eq 0
        __nx_ok
      end

      __nx_stage "Removing the snapshot"
      sudo btrfs subvolume delete $snapshot_dir
      if test $status -ne 0
        __nx_warn "Could not remove $snapshot_dir — remove it by hand later with 'sudo btrfs subvolume delete $snapshot_dir'."
      else
        __nx_ok
      end

      if test $backup_status -ne 0
        __nx_fail "restic backup failed — check network access and the R2 credentials (see restic's own output above)."
        return 1
      end
    '';

    __nx_cmd_vm_pull = ''
      set -l vmware_dir $HOME/vmware
      set -l snapshot_dir $HOME/.nx-vm-snapshot
      set -l target_snapshot latest
      if test -n "$argv[3]"
        set target_snapshot "$argv[3]"
      end

      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      if not test -r $cred_file
        __nx_fail "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
        return 1
      end
      if not test -r $pw_file
        __nx_fail "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
        return 1
      end

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

      __nx_stage "Checking the restic repository"
      ${pkgs.restic}/bin/restic snapshots >/dev/null 2>&1
      if test $status -ne 0
        __nx_fail "Could not reach the restic repository at $RESTIC_REPOSITORY, or nothing has been pushed yet — check network access and the R2 credentials, or run 'nx vm push' first on the machine that has the VMs."
        return 1
      end
      __nx_ok

      set -l existing $vmware_dir/*
      if test (count $existing) -gt 0
        __nx_warn "$vmware_dir is not empty — this is a mirror restore: files will be overwritten to match the backup, and any file in $vmware_dir that isn't in it will be DELETED."
        __nx_confirm "Continue?"
        or begin
          echo "Aborted."
          return 1
        end
      end

      __nx_stage "Restoring $target_snapshot from R2 into ~/vmware (mirror — extra local files are deleted)"
      mkdir -p $vmware_dir
      if test "$target_snapshot" = latest
        # --host/--tag pick the right snapshot out of the repo for "latest" —
        # irrelevant (and not applied) once you already have one specific ID
        ${pkgs.restic}/bin/restic restore "latest:$snapshot_dir" --target $vmware_dir --delete --host vm-library --tag vm
      else
        ${pkgs.restic}/bin/restic restore "$target_snapshot:$snapshot_dir" --target $vmware_dir --delete
      end
      if test $status -ne 0
        __nx_fail "restic restore failed — check the ID is correct (run 'nx vm log' to list available backups), and that network access and the R2 credentials are OK (see restic's own output above)."
        return 1
      end
      __nx_ok
    '';

    __nx_cmd_vm_log = ''
      set -l cred_file /run/agenix/r2Credentials
      set -l pw_file /run/agenix/resticPassword
      if not test -r $cred_file
        __nx_fail "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
        return 1
      end
      if not test -r $pw_file
        __nx_fail "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
        return 1
      end

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

      __nx_stage "Backup history for ~/vmware in R2"
      set -l log_output (${pkgs.restic}/bin/restic snapshots --host vm-library --tag vm 2>&1)
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
      if not test -r $cred_file
        __nx_fail "R2 credentials secret not found or unreadable at $cred_file — has 'nx deploy' run since the r2Credentials secret was added?"
        return 1
      end
      if not test -r $pw_file
        __nx_fail "restic password secret not found or unreadable at $pw_file — has 'nx deploy' run since the resticPassword secret was added?"
        return 1
      end

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
      set -l lookup_output (${pkgs.restic}/bin/restic snapshots $id 2>&1)
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
      ${pkgs.restic}/bin/restic forget $id --prune
      if test $status -ne 0
        __nx_fail "Deletion failed — check network access and the R2 credentials (see restic's own output above)."
        return 1
      end
      __nx_ok
    '';
  };
}
