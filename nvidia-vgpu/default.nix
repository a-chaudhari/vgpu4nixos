/*
  Copyright (c) 2003-2024 Eelco Dolstra and the Nixpkgs/NixOS contributors

  Original source code:
  https://github.com/NixOS/nixpkgs/blob/85149743aab230dfbf3ffd538a8dd44972883b59/pkgs/os-specific/linux/nvidia-x11/generic.nix
*/
{
  version,
  settingsSha256 ? null,
  settingsVersion ? version,
  persistencedSha256 ? null,
  persistencedVersion ? version,
  vgpuPatcher ? null,
  useGLVND ? true,
  useProfiles ? true,
  preferGtk2 ? false,
  settings32Bit ? false,
  useSettings ? true,
  usePersistenced ? true,
  ibtSupport ? false,

  prePatch ? null,
  postPatch ? null,
  patchFlags ? null,
  patches ? [ ],
  preInstall ? null,
  postInstall ? null,
  broken ? false,
}@args:

{
  lib,
  stdenv,
  runCommandLocal,
  patchutils,
  callPackage,
  pkgs,
  pkgsi686Linux,
  fetchurl,
  fetchzip,
  kernel,
  kernelModuleMakeFlags ? [ ],
  bbe,
  perl,
  gawk,
  coreutils,
  pciutils,
  nukeReferences,
  makeWrapper,
  which,
  libarchive,
  unzip,
  jq,

  src,
  patcherArgs ? "",
  guest ? false,
  merged ? false,
  # don't include the bundled 32-bit libraries on 64-bit platforms,
  # even if it’s in downloaded binary
  disable32Bit ? false,
  # Whether to extract the GSP firmware, datacenter drivers needs to extract the
  # firmware
  firmware ? false,
}:

assert useSettings -> settingsSha256 != null;
assert usePersistenced -> persistencedSha256 != null;

let
  # Rewrites patches meant for the kernel/* folder structure to kernel-open/*
  rewritePatch =
    { from, to }:
    patch:
    runCommandLocal (builtins.baseNameOf patch)
      {
        inherit patch;
        nativeBuildInputs = [ patchutils ];
      }
      ''
        lsdiff \
          -p1 -i ${from}/'*' \
          "$patch" \
        | sort -u | sed -e 's/[*?]/\\&/g' \
        | xargs -I{} \
          filterdiff \
          --include={} \
          --strip=2 \
          --addoldprefix=a/${to}/ \
          --addnewprefix=b/${to}/ \
          --clean "$patch" > "$out"
      '';

  guiBundled = guest || merged;
  i686bundled = !disable32Bit && guiBundled;

  patcher = if vgpuPatcher == null then null else (vgpuPatcher src);

  # TODO: use graphics-related libraries for merged drivers only
  libPathFor =
    pkgs:
    lib.makeLibraryPath (
      with pkgs;
      [
        libdrm
        xorg.libXext
        xorg.libX11
        xorg.libXv
        xorg.libXrandr
        xorg.libxcb
        zlib
        stdenv.cc.cc
        wayland
        mesa
        libGL
        openssl
        dbus # for nvidia-powerd
      ]
    );

  self = stdenv.mkDerivation {
    name = "nvidia-vgpu-${version}-${kernel.version}";

    builder = ./builder.sh;

    inherit src patcher patcherArgs;
    inherit prePatch postPatch patchFlags;
    inherit preInstall postInstall;
    inherit version useGLVND useProfiles;
    inherit (stdenv.hostPlatform) system;
    inherit guiBundled i686bundled patches;

    postFixup = lib.optionalString (!guest) ''
      # wrap sriov-manage
      wrapProgram $bin/bin/sriov-manage \
        --set PATH ${
          lib.makeBinPath [
            coreutils
            pciutils
            gawk
          ]
        }
    '';

    outputs =
      [
        "out"
        "bin"
      ]
      ++ lib.optional i686bundled "lib32"
      ++ lib.optional firmware "firmware";
    outputDev = "bin";

    kernel = kernel.dev;
    kernelVersion = kernel.modDirVersion;

    makeFlags = kernelModuleMakeFlags ++ [
      "IGNORE_PREEMPT_RT_PRESENCE=1"
      "NV_BUILD_SUPPORTS_HMM=1"
      "SYSSRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
      "SYSOUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    ];

    hardeningDisable = [
      "pic"
      "format"
    ];

    dontStrip = true;
    dontPatchELF = true;

    libPath = libPathFor pkgs;
    libPath32 = lib.optionalString i686bundled (libPathFor pkgsi686Linux);

    buildInputs = lib.optional (!guest) pciutils;
    nativeBuildInputs = [
      perl
      nukeReferences
      makeWrapper
      which
      libarchive
      unzip
      jq
      kernel.moduleBuildDependencies
    ] ++ lib.optional (!guest) bbe;

    disallowedReferences = [ kernel.dev ];

    passthru =
      let
        fetchFromGithubOrNvidia =
          {
            owner,
            repo,
            rev,
            ...
          }@args:
          let
            args' = builtins.removeAttrs args [
              "owner"
              "repo"
              "rev"
            ];
            baseUrl = "https://github.com/${owner}/${repo}";
          in
          fetchzip (
            args'
            // {
              urls = [
                "${baseUrl}/archive/${rev}.tar.gz"
                "https://download.nvidia.com/XFree86/${repo}/${repo}-${rev}.tar.bz2"
              ];
              # github and nvidia use different compression algorithms,
              #  use an invalid file extension to force detection.
              extension = "tar.??";
            }
          );
      in
      {
        settings =
          if useSettings then
            (if settings32Bit then pkgsi686Linux.callPackage else callPackage)
              (import (pkgs.path + "/pkgs/os-specific/linux/nvidia-x11/settings.nix") self settingsSha256)
              {
                withGtk2 = preferGtk2;
                withGtk3 = !preferGtk2;
                fetchFromGitHub = fetchFromGithubOrNvidia;
              }
          else
            { };
        persistenced =
          if usePersistenced then
            lib.mapNullable (
              hash:
              callPackage (import (pkgs.path + "/pkgs/os-specific/linux/nvidia-x11/persistenced.nix") self hash) {
                fetchFromGitHub = fetchFromGithubOrNvidia;
              }
            ) persistencedSha256
          else
            { };
        fabricmanager = (
          throw ''
            NVIDIA datacenter drivers are not compatible with vGPU drivers.
            Did you set `hardware.nvidia.datacenter.enable` to `true`?
          ''
        );
        inherit persistencedVersion settingsVersion;
        compressFirmware = false;
        ibtSupport = ibtSupport || (lib.versionAtLeast version "530");
        vgpuPatcher = patcher;
      };

    meta = with lib; {
      license = licenses.unfree;
      platforms = [ "x86_64-linux" ]; # for compatibility with persistenced.nix and settings.nix
      priority = 4; # resolves collision with xorg-server's "lib/xorg/modules/extensions/libglx.so"
      inherit broken;
    };
  };

in
self
