{lib, ...}: {
  options.nx.vm.libvirtDomains = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = ''
      libvirt (qemu:///system) domains that nx vm backs up and restores together with
      ~/vmware: their disks, UEFI NVRAM, swtpm state and snapshot metadata, all read from
      the domain definitions. Empty means nx vm only handles ~/vmware.
    '';
  };
}
