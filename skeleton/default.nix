{ obelisk ? import ./.obelisk/impl {
    system = builtins.currentSystem;
    iosSdkVersion = "10.2";
    # You must accept the Android Software Development Kit License Agreement at
    # https://developer.android.com/studio/terms in order to build Android apps.
    # Uncomment and set this to `true` to indicate your acceptance:
    # config.android_sdk.accept_license = false;
  }
}:
with obelisk;
project ./. ({ pkgs, ... }: {
  android.applicationId = "systems.obsidian.obelisk.examples.minimal";
  android.displayName = "Obelisk Minimal Example";
  ios.bundleIdentifier = "systems.obsidian.obelisk.examples.minimal";
  ios.bundleName = "Obelisk Minimal Example";

  shellToolOverrides = ghc: super: {
    ghcide = pkgs.haskell.lib.dontCheck ((ghc.override {
      overrides = ghc: super: {
        lsp-test =
          pkgs.haskell.lib.dontCheck (ghc.callHackage "lsp-test" "0.6.1.0" { });
        haddock-library = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "haddock-library" "1.8.0" { });
        haskell-lsp = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "haskell-lsp" "0.19.0.0" { });
        haskell-lsp-types = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "haskell-lsp-types" "0.19.0.0" { });
        regex-posix = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "regex-posix" "0.96.0.0" { });
        test-framework = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "test-framework" "0.8.2.0" { });
        regex-base = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "regex-base" "0.94.0.0" { });
        regex-tdfa = pkgs.haskell.lib.dontCheck
          (ghc.callHackage "regex-tdfa" "1.3.1.0" { });
        shake =
          pkgs.haskell.lib.dontCheck (ghc.callHackage "shake" "0.18.4" { });
        hie-bios = pkgs.haskell.lib.dontCheck (ghc.callHackageDirect {
          pkg = "hie-bios";
          ver = "0.4.0";
          sha256 = "19lpg9ymd9656cy17vna8wr1hvzfal94gpm2d3xpnw1d5qr37z7x";
        } { });
      };
    }).callCabal2nix "ghcide" (pkgs.fetchFromGitHub {
      owner = "digital-asset";
      repo = "ghcide";
      rev = "v0.1.0";
      sha256 = "1kf71iix46hvyxviimrcv7kvsj67hcnnqlpdsmazmlmybf7wbqbb";
    }) { });
  };
})
