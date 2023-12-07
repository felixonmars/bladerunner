{ config, pkgs, modulesPath, ... }:
let
  build = config.system.build;
  kernelTarget = pkgs.stdenv.hostPlatform.linux-kernel.target;
  scratch = "/mnt/scratch";
  rostore = "/mnt/store";
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    # FIXME: replace qemu quest profile with actual kernel modules required for initrd networking
    # boot.initrd.availableKernelModules = [ ];
    # boot.initrd.kernelModules = [ ];
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = false;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [
    # FIXME: Use netconsole
  ];

  boot.initrd.systemd.enable = true;
  boot.initrd.network.enable = true;
  boot.initrd.kernelModules = [ "nbd" "overlay" "r8169" "mt7921e" ];
  hardware.enableRedistributableFirmware = true;

  boot.initrd.systemd.storePaths = [ pkgs.nbd ];
  boot.initrd.systemd.emergencyAccess = true;

  boot.initrd.systemd.targets.network-online.requiredBy = [ "initrd.target" ];
  boot.initrd.systemd.services.systemd-networkd-wait-online.requiredBy = [ "network-online.target" ];

  boot.initrd.systemd.services.nbd0 = {
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    wantedBy = [ "sysroot-mnt-store.mount" ];
    before = [ "sysroot-mnt-store.mount" ];
    unitConfig = {
      IgnoreOnIsolate = true;
      DefaultDependencies = false;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nbd}/bin/nbd-client 172.24.5.1 10809 /dev/nbd0 -name rostore";
    };
  };

  boot.initrd.systemd.services.nbd1 = {
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    wantedBy = [ "sysroot.mount" ];
    before = [ "sysroot.mount" ];
    unitConfig = {
      IgnoreOnIsolate = true;
      DefaultDependencies = false;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nbd}/bin/nbd-client 172.24.5.1 10809 /dev/nbd1 -name scratch";
    };
  };

  boot.initrd.systemd.services.mkdir-rw-store = {
    wantedBy = [ "sysroot-nix-store.mount" ];
    before = [ "sysroot-nix-store.mount" ];
    unitConfig = {
      IgnoreOnIsolate = true;
      DefaultDependencies = false;
      RequiresMountsFor = [
        "/sysroot/${scratch}"
        "/sysroot/${rostore}"
      ];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.coreutils}/bin/mkdir -p /sysroot/${scratch}/upperdir"
        "${pkgs.coreutils}/bin/mkdir -p /sysroot/${scratch}/workdir"
      ];
    };
  };

  services.getty.autologinUser = "root";

  networking.firewall.enable = false;
  networking.useNetworkd = true;

  system.build.rootblk = pkgs.callPackage (modulesPath + "/../lib/make-squashfs.nix") {
    # FIXME: before prod, drop this line to use the default compression algo xz
    comp = "zstd -Xcompression-level 6";
    storeContents = [ build.toplevel ];
  };

  fileSystems."/" = {
    fsType = "tmpfs";
    options = [ "defaults" "mode=755" ];
  };

  fileSystems."${scratch}" = {
    fsType = "ext4";
    device = "/dev/nbd1";
    options = [ "_netdev" ];
    autoFormat = true;
    neededForBoot = true;
  };

  fileSystems."${rostore}" = {
    fsType = "squashfs";
    device = "/dev/nbd0";
    options = [ "_netdev" ];
    neededForBoot = true;
  };

  fileSystems."/nix/store" = {
    fsType = "overlay";
    device = "overlay";
    options = [
      "lowerdir=/sysroot/${rostore}"
      "upperdir=/sysroot/${scratch}/upperdir"
      "workdir=/sysroot/${scratch}/workdir"
    ];
  };

  boot.postBootCommands = ''
    ${config.nix.package}/bin/nix-store --load-db < /nix/store/nix-path-registration
  '';

  system.build.ipxeScript = pkgs.writeText "netboot.ipxe" ''
    #!ipxe
    dhcp
    kernel ${kernelTarget} init=${build.toplevel}/init initrd=initrd ${toString config.boot.kernelParams}
    initrd initrd
    boot
  '';

  system.build.netboot = pkgs.symlinkJoin {
    name = "netboot";
    paths = [
      build.kernel
      build.initialRamdisk
      (pkgs.ipxe.override { embedScript = build.ipxeScript; })
    ];
  };

  services.github-runners.sequencer = {
    enable = true;
    # FIXME: use actual repo url and github token
    url = "https://github.com/NickCao/bladerunner";
    tokenFile = builtins.toFile "token" "github_pat_something";
    name = "sequencer";
    ephemeral = true;
  };

  system.stateVersion = "23.11";

}
