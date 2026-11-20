{
  pkgs,
  lib,
  config,
  ...
}: let
  labDomains = config.nx.vm.libvirtDomains;
  swtpmDir = "/var/lib/libvirt/swtpm";
  sudoKeepEnv = "AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_DEFAULT_REGION,RESTIC_REPOSITORY,RESTIC_PASSWORD_FILE";
in {
  # -- nx: vm — push/pull/log/del the ~/vmware VM library on Cloudflare R2
  # via restic. With nx.vm.libvirtDomains set, the same restic snapshot also
  # holds those libvirt VMs (disks, NVRAM, TPM state, snapshot metadata). Kept separate — unlike everything else nx touches, this
  # doesn't read/write the flake repo, just moves data between ~/vmware
  # and R2 using the r2Credentials/resticPassword agenix secrets.
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

    __nx_vm_virsh = ''
      ${pkgs.libvirt}/bin/virsh -c qemu:///system $argv
    '';

    __nx_vm_lab_domains = ''
${lib.concatMapStrings (d: "      echo ${lib.escapeShellArg d}\n") labDomains}    '';

    # true when this host has lab domains configured and libvirt answers
    __nx_vm_lab_enabled = ''
      test (count (__nx_vm_lab_domains)) -gt 0
      and __nx_vm_virsh version >/dev/null 2>&1
    '';

    # every lab domain must be shut off (an iGPU-passthrough VM needs a clean
    # stop, and a disk image copied while running is not consistent) and defined
    __nx_vm_lab_check = ''
      for d in (__nx_vm_lab_domains)
        set -l state (__nx_vm_virsh domstate $d 2>/dev/null | string trim)
        if test -z "$state"
          echo "$d is not defined in libvirt — apply the NixOS config that defines it first." >&2
          return 1
        end
        if test "$state" != "shut off"
          echo "$d is $state — shut it down first." >&2
          return 1
        end
      end
    '';

    # paths the lab owns, read from the domain definitions: disks, NVRAM, swtpm
    # state, and the snapshot-metadata dump (written by __nx_vm_lab_dump)
    __nx_vm_lab_paths = ''
      for d in (__nx_vm_lab_domains)
        __nx_vm_virsh domblklist $d --details 2>/dev/null | string match -rg '^\s*\S+\s+disk\s+\S+\s+(/\S+)'
        __nx_vm_virsh dumpxml --inactive $d 2>/dev/null | string match -rg '<nvram[^>]*>([^<]+)</nvram>'
        if __nx_vm_virsh dumpxml --inactive $d 2>/dev/null | string match -q '*<tpm *'
          echo ${swtpmDir}/(__nx_vm_virsh domuuid $d | string match -r '\S+')
        end
      end
      echo $HOME/.nx-vm-libvirt-snapshots
    '';

    # libvirt keeps snapshot metadata outside the qcow2, so it is dumped to a
    # plain directory that travels in the backup
    __nx_vm_lab_dump = ''
      set -l dump $HOME/.nx-vm-libvirt-snapshots
      rm -rf $dump
      mkdir -p $dump
      for d in (__nx_vm_lab_domains)
        mkdir -p $dump/$d
        for s in (__nx_vm_virsh snapshot-list $d --name 2>/dev/null)
          test -n "$s"
          and __nx_vm_virsh snapshot-dumpxml $d $s > $dump/$d/$s.xml
        end
        __nx_vm_virsh snapshot-current $d --name > $dump/$d/CURRENT 2>/dev/null
      end
    '';

    # restores the lab part of one restic snapshot ($argv[1], or "latest") into
    # the paths from the domain definitions; needs the R2/restic environment
    # exported by the caller
    __nx_vm_lab_restore = ''
      set -l sel $argv[1]
      set -l selector
      if test "$sel" = latest
        set selector --host vm-library --tag vm
      end
      set -l dump $HOME/.nx-vm-libvirt-snapshots
      set -l probe (${pkgs.restic}/bin/restic ls $selector $sel $dump 2>/dev/null | string match '/*')
      if test (count $probe) -eq 0
        echo "This backup has no malware-lab data (made before the lab joined nx vm) — skipping the lab part."
        return 0
      end
      set -l includes
      for p in (__nx_vm_lab_paths)
        set -a includes --include $p
      end
      sudo --preserve-env=${sudoKeepEnv} ${pkgs.restic}/bin/restic restore $selector $sel --target / --sparse $includes
      or return 1
      for d in (__nx_vm_lab_domains)
        for x in $dump/$d/*.xml
          test -e $x
          or continue
          __nx_vm_virsh snapshot-create $d $x --redefine >/dev/null
          or return 1
        end
        set -l cur (string trim < $dump/$d/CURRENT 2>/dev/null)
        test -n "$cur"
        and __nx_vm_virsh snapshot-current $d --snapshotname $cur >/dev/null
      end
    '';

    __nx_cmd_vm = ''
      switch "$argv[2]"
        case push
          __nx_cmd_vm_push $argv
        case pull
          __nx_cmd_vm_pull $argv
        case log
          __nx_cmd_vm_log
        case del
          __nx_cmd_vm_del $argv
        case '*'
          echo "Usage: nx vm push [--no-lab] | nx vm pull [id] [--no-lab] | nx vm log | nx vm del <id>"
          return 1
      end
    '';

    __nx_cmd_vm_push = ''
      set -l vmware_dir $HOME/vmware
      set -l snapshot_dir $HOME/.nx-vm-snapshot
      set -l with_lab true
      contains -- --no-lab $argv
      and set with_lab false
      __nx_vm_lab_enabled
      or set with_lab false

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
      ${pkgs.restic}/bin/restic snapshots >/dev/null 2>&1
      or ${pkgs.restic}/bin/restic init
      if test $status -ne 0
        __nx_fail "Could not reach or initialize the restic repository at $RESTIC_REPOSITORY — check network access and the R2 credentials."
        return 1
      end
      __nx_ok

      set -l lab_paths
      if test $with_lab = true
        __nx_stage "Preparing the malware-lab VMs (both must be shut off)"
        __nx_vm_lab_check
        if test $status -ne 0
          __nx_fail "A malware-lab VM is running or not defined (see above) — shut it down, or push only ~/vmware with 'nx vm push --no-lab'."
          return 1
        end
        __nx_vm_lab_dump
        # root-owned files can only be tested with sudo; anything the definitions name but is missing is skipped
        for p in (__nx_vm_lab_paths)
          sudo test -e $p
          and set -a lab_paths $p
        end
        __nx_ok (count $lab_paths)" lab paths added to the backup"
      end

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
      if test (count $lab_paths) -gt 0
        # the lab files are root-owned, so restic runs as root with the R2 environment kept
        sudo --preserve-env=${sudoKeepEnv} ${pkgs.restic}/bin/restic backup $snapshot_dir $lab_paths --host vm-library --tag vm --tag qemu
      else
        ${pkgs.restic}/bin/restic backup $snapshot_dir --host vm-library --tag vm
      end
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
      set -l ids (string match -v -- '--*' $argv)
      if test -n "$ids[3]"
        set target_snapshot "$ids[3]"
      end
      set -l with_lab true
      contains -- --no-lab $argv
      and set with_lab false
      __nx_vm_lab_enabled
      or set with_lab false

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

      __nx_stage "Checking the restic repository"
      ${pkgs.restic}/bin/restic snapshots >/dev/null 2>&1
      if test $status -ne 0
        __nx_fail "Could not reach the restic repository at $RESTIC_REPOSITORY, or nothing has been pushed yet — check network access and the R2 credentials, or run 'nx vm push' first on the machine that has the VMs."
        return 1
      end
      __nx_ok

      # best-effort cleanup of a stale lock left by a previously killed
      # push/pull — restic unlock is a no-op if there's nothing to unlock
      ${pkgs.restic}/bin/restic unlock >/dev/null 2>&1

      if test $with_lab = true
        __nx_stage "Checking the malware-lab VMs are shut off"
        __nx_vm_lab_check
        if test $status -ne 0
          __nx_fail "A malware-lab VM is running or not defined (see above) — shut it down, or restore only ~/vmware with 'nx vm pull --no-lab'."
          return 1
        end
        __nx_ok
        __nx_warn "If the backup holds malware-lab data, the VM disks, UEFI NVRAM and TPM state on this machine are overwritten by it."
        __nx_confirm "Continue?"
        or begin
          echo "Aborted."
          return 1
        end
      end

      set -l pull_backup_dir $HOME/.nx-vm-pull-snapshot
      if test -e $pull_backup_dir
        sudo btrfs subvolume delete $pull_backup_dir >/dev/null 2>&1
      end
      if sudo btrfs subvolume show $vmware_dir >/dev/null 2>&1
        sudo btrfs subvolume snapshot -r $vmware_dir $pull_backup_dir
        __nx_ok "local rollback snapshot saved at $pull_backup_dir — delete it by hand once you've checked the restore"
      else
        __nx_warn "$vmware_dir is not a btrfs subvolume — no local rollback snapshot will be taken before this restore."
      end

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

      if test $with_lab = true
        __nx_stage "Restoring the malware-lab VMs from $target_snapshot (disks, NVRAM, TPM, snapshots)"
        __nx_vm_lab_restore $target_snapshot
        if test $status -ne 0
          __nx_fail "~/vmware is restored, but the lab restore failed (see restic's output above) — fix the cause and rerun 'nx vm pull $target_snapshot'."
          return 1
        end
        __nx_ok
      end
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

      __nx_stage "Backup history in R2 (each entry: ~/vmware, plus the malware-lab VMs when tagged qemu)"
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
