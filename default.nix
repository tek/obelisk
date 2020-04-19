{ system ? builtins.currentSystem
, profiling ? false
, iosSdkVersion ? "10.2"
, config ? {}
, reflex-platform-func ? import ./dep/reflex-platform
}:
let
  reflex-platform = getReflexPlatform { inherit system; };
  inherit (reflex-platform) hackGet nixpkgs;
  pkgs = nixpkgs;

  inherit (import dep/gitignore.nix { inherit (nixpkgs) lib; }) gitignoreSource;

  getReflexPlatform = { system, enableLibraryProfiling ? profiling }: reflex-platform-func {
    inherit iosSdkVersion config system enableLibraryProfiling;

    nixpkgsOverlays = [
      (import ./nixpkgs-overlays)
    ];

    haskellOverlays = [
      (import ./haskell-overlays/misc-deps.nix { inherit hackGet; })
      pkgs.obeliskExecutableConfig.haskellOverlay
      (import ./haskell-overlays/obelisk.nix)
      (import ./haskell-overlays/tighten-ob-exes.nix)
    ];
  };

  # The haskell environment used to build Obelisk itself, e.g. the 'ob' command
  ghcObelisk = reflex-platform.ghc;

  # Development environments for obelisk packages.
  ghcObeliskEnvs = pkgs.lib.mapAttrs (n: v: reflex-platform.workOn ghcObelisk v) ghcObelisk;

  inherit (import ./lib/asset/assets.nix { inherit nixpkgs; }) mkAssets;

  haskellLib = pkgs.haskell.lib;

in rec {
  inherit reflex-platform;
  inherit (reflex-platform) nixpkgs pinBuildInputs;
  inherit (nixpkgs) lib;
  pathGit = ./.;  # Used in CI by the migration graph hash algorithm to correctly ignore files.
  path = reflex-platform.filterGit ./.;
  obelisk = ghcObelisk;
  obeliskEnvs = pkgs.lib.filterAttrs (k: _: pkgs.lib.strings.hasPrefix "obelisk-" k) ghcObeliskEnvs;
  command = ghcObelisk.obelisk-command;
  shell = pinBuildInputs "obelisk-shell" ([command] ++ command.commandRuntimeDeps);

  selftest = pkgs.writeScript "selftest" ''
    #!${pkgs.runtimeShell}
    set -euo pipefail

    PATH="${command}/bin:$PATH"
    cd ${./.}
    "${ghcObelisk.obelisk-selftest}/bin/obelisk-selftest" +RTS -N -RTS "$@"
  '';
  skeleton = pkgs.runCommand "skeleton" {
    dir = builtins.filterSource (path: type: builtins.trace path (baseNameOf path != ".obelisk")) ./skeleton;
  } ''
    ln -s "$dir" "$out"
  '';
  nullIfAbsent = p: if lib.pathExists p then p else null;
  #TODO: Avoid copying files within the nix store.  Right now, obelisk-asset-manifest-generate copies files into a big blob so that the android/ios static assets can be imported from there; instead, we should get everything lined up right before turning it into an APK, so that copies, if necessary, only exist temporarily.
  processAssets = { src, packageName ? "obelisk-generated-static", moduleName ? "Obelisk.Generated.Static" }: pkgs.runCommand "asset-manifest" {
    inherit src;
    outputs = [ "out" "haskellManifest" "symlinked" ];
    nativeBuildInputs = [ ghcObelisk.obelisk-asset-manifest ];
  } ''
    set -euo pipefail
    touch "$out"
    mkdir -p "$symlinked"
    obelisk-asset-manifest-generate "$src" "$haskellManifest" ${packageName} ${moduleName} "$symlinked"
  '';

  compressedJs = frontend: optimizationLevel: pkgs.runCommand "compressedJs" {} ''
    mkdir $out
    cd $out
    # TODO profiling + static shouldn't break and need an ad-hoc workaround like that
    ln -s "${haskellLib.justStaticExecutables frontend}/bin/frontend.jsexe/all.js" all.unminified.js
    ${if optimizationLevel == null then ''
      ln -s all.unminified.js all.js
    '' else ''
      ${pkgs.closurecompiler}/bin/closure-compiler --externs "${reflex-platform.ghcjsExternsJs}" -O ${optimizationLevel} --jscomp_warning=checkVars --create_source_map="all.js.map" --source_map_format=V3 --js_output_file="all.js" all.unminified.js
      echo "//# sourceMappingURL=all.js.map" >> all.js
    ''}
  '';

  serverModules = {
    mkBaseEc2 = { nixosPkgs, ... }: {...}: {
      imports = [
        (nixosPkgs.path + /nixos/modules/virtualisation/amazon-image.nix)
      ];
      ec2.hvm = true;
    };

    mkDefaultNetworking = { adminEmail, enableHttps, hostName, routeHost, ... }: {...}: {
      networking = {
        inherit hostName;
        firewall.allowedTCPPorts = if enableHttps then [ 80 443 ] else [ 80 ];
      };

      # `amazon-image.nix` already sets these but if the user provides their own module then
      # forgetting these can cause them to lose access to the server!
      # https://github.com/NixOS/nixpkgs/blob/fab05f17d15e4e125def4fd4e708d205b41d8d74/nixos/modules/virtualisation/amazon-image.nix#L133-L136
      services.openssh.enable = true;
      services.openssh.permitRootLogin = "prohibit-password";

      security.acme.certs = if enableHttps then {
        "${routeHost}".email = adminEmail;
      } else {};
    };

    mkObeliskApp =
      { exe
      , routeHost
      , enableHttps
      , name ? "backend"
      , user ? name
      , group ? user
      , baseUrl ? "/"
      , internalPort ? 8000
      , backendArgs ? "--port=${toString internalPort}"
      , ...
      }: {...}: {
      services.nginx = {
        enable = true;
        virtualHosts."${routeHost}" = {
          enableACME = enableHttps;
          forceSSL = enableHttps;
          locations.${baseUrl} = {
            proxyPass = "http://127.0.0.1:" + toString internalPort;
            proxyWebsockets = true;
          };
        };
      };
      systemd.services.${name} = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        restartIfChanged = true;
        path = [ pkgs.gnutar ];
        script = ''
          ln -sft . '${exe}'/*
          mkdir -p log
          exec ./backend ${backendArgs} </dev/null
        '';
        serviceConfig = {
          User = user;
          KillMode = "process";
          WorkingDirectory = "~";
          Restart = "always";
          RestartSec = 5;
        };
      };
      users = {
        users.${user} = {
          description = "${user} service";
          home = "/var/lib/${user}";
          createHome = true;
          isSystemUser = true;
          group = group;
        };
        groups.${group} = {};
      };
    };
  };

  inherit mkAssets;
  dockerImageConfig = args@{exe, name, version, extraContents ? [], extraPaths ? []}: 
    let
      appDirSetupScript = nixpkgs.runCommand "appDirSetupScript.sh" {} ''
        mkdir -p    $out/var/lib/backend
        ln -sft $out/var/lib/backend '${exe}'/*
        ${nixpkgs.findutils}/bin/find $out/var/lib/backend
        '';
    in {
      name = name;
      tag = version;
      contents = [ nixpkgs.iana-etc nixpkgs.cacert appDirSetupScript ] ++ extraContents;
      keepContentsDirlinks = true;
      config = {
        Env = [
          ("PATH=" + builtins.concatStringsSep(":")(extraPaths ++ [
            "/var/lib/backend" # put the obelisk project on the path.
            "/bin" # put contents on path
          ] ++ map (pkg: "${pkg}/bin") pkgs.stdenv.initialPath # put common tools in path so docker exec is useful
          ))
        ];
        Expose = 8000;
        Entrypoint = ["/var/lib/backend/backend"];
        WorkingDir = "/var/lib/backend";
        User = "99:99";
      };
    };

  dockerImage = args: nixpkgs.dockerTools.buildImage (dockerImageConfig args);

  serverExe = backend: frontend: assets: optimizationLevel: version:
    pkgs.runCommand "serverExe" {} ''
      mkdir $out
      set -eux
      ln -s "${if profiling then backend else haskellLib.justStaticExecutables backend}"/bin/* $out/
      ln -s "${mkAssets assets}" $out/static.assets
      ln -s ${mkAssets (compressedJs frontend optimizationLevel)} $out/frontend.jsexe.assets
      echo ${version} > $out/version
    '';

  server = { exe, hostName, adminEmail, routeHost, enableHttps, version, module ? serverModules.mkBaseEc2 }@args:
    let
      nixos = import (pkgs.path + /nixos);
    in nixos {
      system = "x86_64-linux";
      configuration = {
        imports = [
          (module { inherit exe hostName adminEmail routeHost enableHttps version; nixosPkgs = pkgs; })
          (serverModules.mkDefaultNetworking args)
          (serverModules.mkObeliskApp args)
        ];
      };
    };

  # An Obelisk project is a reflex-platform project with a predefined layout and role for each component
  project = base': projectDefinition:
    let
      projectOut = { system, enableLibraryProfiling ? profiling }: let reflexPlatformProject = (getReflexPlatform { inherit system enableLibraryProfiling; }).project; in reflexPlatformProject (args@{ nixpkgs, ... }:
        let
          inherit (lib.strings) hasPrefix;
          mkProject =
            { android ? null #TODO: Better error when missing
            , ios ? null #TODO: Better error when missing
            , packages ? {}
            , overrides ? _: _: {}
            , staticFiles ? null
            , tools ? _: []
            , shellToolOverrides ? _: _: {}
            , withHoogle ? false # Setting this to `true` makes shell reloading far slower
            , __closureCompilerOptimizationLevel ? "ADVANCED" # Set this to `null` to skip the closure-compiler step
            , __withGhcide ? false
            }:
            let
              allConfig = nixpkgs.lib.makeExtensible (self: {
                base = base';
                inherit args;
                userSettings = {
                  inherit android ios packages overrides tools shellToolOverrides withHoogle __closureCompilerOptimizationLevel __withGhcide;
                  staticFiles = if staticFiles == null then self.base + /static else staticFiles;
                };
                frontendName = "frontend";
                backendName = "backend";
                commonName = "common";
                staticName = "obelisk-generated-static";
                staticFilesImpure = let fs = self.userSettings.staticFiles; in if lib.isDerivation fs then fs else toString fs;
                processedStatic = processAssets { src = self.userSettings.staticFiles; };
                # The packages whose names and roles are defined by this package
                predefinedPackages = lib.filterAttrs (_: x: x != null) {
                  ${self.frontendName} = nullIfAbsent (self.base + "/frontend");
                  ${self.commonName} = nullIfAbsent (self.base + "/common");
                  ${self.backendName} = nullIfAbsent (self.base + "/backend");
                };
                shellPackages = {};
                combinedPackages = self.predefinedPackages // self.userSettings.packages // self.shellPackages;
                projectOverrides = self': super': {
                  ${self.staticName} = haskellLib.dontHaddock (self'.callCabal2nix self.staticName self.processedStatic.haskellManifest {});
                  ${self.backendName} = haskellLib.addBuildDepend super'.${self.backendName} self'.obelisk-run;
                };
                totalOverrides = lib.composeExtensions self.projectOverrides self.userSettings.overrides;
                privateConfigDirs = ["config/backend"];
                injectableConfig = builtins.filterSource (path: _:
                  !(lib.lists.any (x: hasPrefix (toString self.base + "/" + toString x) (toString path)) self.privateConfigDirs)
                );
                __androidWithConfig = configPath: {
                  ${if self.userSettings.android == null then null else self.frontendName} = {
                    executableName = "frontend";
                    ${if builtins.pathExists self.userSettings.staticFiles then "assets" else null} =
                      nixpkgs.obeliskExecutableConfig.platforms.android.inject
                        (self.injectableConfig configPath)
                        self.processedStatic.symlinked;
                  } // self.userSettings.android;
                };
                __iosWithConfig = configPath: {
                  ${if self.userSettings.ios == null then null else self.frontendName} = {
                    executableName = "frontend";
                    ${if builtins.pathExists self.userSettings.staticFiles then "staticSrc" else null} =
                      nixpkgs.obeliskExecutableConfig.platforms.ios.inject
                        (self.injectableConfig configPath)
                        self.processedStatic.symlinked;
                  } // self.userSettings.ios;
                };

                shells-ghc = builtins.attrNames (self.predefinedPackages // self.shellPackages);

                shells-ghcjs = [
                  self.frontendName
                  self.commonName
                ];

                shells-ghcSavedSplices = [
                  self.commonName
                  self.frontendName
                ];

                shellToolOverrides = lib.composeExtensions
                  self.userSettings.shellToolOverrides
                  (if self.userSettings.__withGhcide
                    then (import ./haskell-overlays/ghcide.nix)
                    else (_: _: {})
                  );

                project = reflexPlatformProject ({...}: self.projectConfig);
                projectConfig = {
                  inherit (self) shellToolOverrides;
                  inherit (self.userSettings) tools withHoogle;
                  overrides = self.totalOverrides;
                  packages = self.combinedPackages;
                  shells = {
                    ${if self.userSettings.android == null && self.userSettings.ios == null then null else "ghcSavedSplices"} =
                      lib.filter (x: lib.hasAttr x self.combinedPackages) self.shells-ghcSavedSplices;
                    ghc = lib.filter (x: lib.hasAttr x self.combinedPackages) self.shells-ghc;
                    ghcjs = lib.filter (x: lib.hasAttr x self.combinedPackages) self.shells-ghcjs;
                  };
                  android = self.__androidWithConfig (self.base + "/config");
                  ios = self.__iosWithConfig (self.base + "/config");

                  passthru = {
                    __unstable__.self = allConfig;
                    inherit (self)
                      staticFilesImpure processedStatic
                      __iosWithConfig __androidWithConfig
                      ;
                    inherit (self.userSettings)
                      android ios overrides packages shellToolOverrides staticFiles tools withHoogle
                      __closureCompilerOptimizationLevel
                      ;
                  };
                };
              });
            in allConfig;
        in (mkProject (projectDefinition args)).projectConfig);
      mainProjectOut = projectOut { inherit system; };
      serverOn = projectInst: version: serverExe
        projectInst.ghc.backend
        mainProjectOut.ghcjs.frontend
        projectInst.passthru.staticFiles
        projectInst.passthru.__closureCompilerOptimizationLevel
        version;
      linuxExe = serverOn (projectOut { system = "x86_64-linux"; });
      dummyVersion = "Version number is only available for deployments";
    in mainProjectOut // {
      __unstable__.profiledObRun = let
        profiled = projectOut { inherit system; enableLibraryProfiling = true; };
        exeSource = builtins.toFile "ob-run.hs" ''
          module Main where

          import Control.Exception
          import Reflex.Profiled
          import System.Environment

          import qualified Obelisk.Run
          import qualified Frontend
          import qualified Backend

          main :: IO ()
          main = do
            args <- getArgs
            let port = read $ args !! 0
                assets = args !! 1
                profileFile = (args !! 2) <> ".rprof"
            Obelisk.Run.run port (Obelisk.Run.runServeAsset assets) Backend.backend Frontend.frontend `finally` writeProfilingData profileFile
        '';
      in nixpkgs.runCommand "ob-run" {
        buildInputs = [ (profiled.ghc.ghcWithPackages (p: [ p.backend p.frontend])) ];
      } ''
        mkdir -p $out/bin/
        ghc -x hs -prof -fno-prof-auto -threaded ${exeSource} -o $out/bin/ob-run
      '';

      linuxExeConfigurable = linuxExe;
      linuxExe = linuxExe dummyVersion;
      exe = serverOn mainProjectOut dummyVersion;
      server = args@{ hostName, adminEmail, routeHost, enableHttps, version, module ? serverModules.mkBaseEc2 }:
        server (args // { exe = linuxExe version; });
      dockerImage = args@{ name, version }:
        dockerImage (args // { exe = linuxExe version; });
      obelisk = import (base' + "/.obelisk/impl") {};
    };
  haskellPackageSets = {
    inherit (reflex-platform) ghc ghcjs;
  };
}
