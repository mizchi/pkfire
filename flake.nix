{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # MoonBit toolchain + `buildMoonPackage` (reproducible source build inside
    # the Nix sandbox). The companion `moon-registry` input is the mooncakes.io
    # package index, fetched at eval time; `buildMoonPackage` then resolves every
    # transitive dep as a fixed-output derivation keyed by the index checksum, so
    # the build itself runs with no network (pure).
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
    moon-registry = {
      url = "git+https://mooncakes.io/git/index";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, moonbit-overlay, moon-registry }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ moonbit-overlay.overlays.default ];
        };

        # Build the MoonBit `pkf` from source (pkf-mbt/) via `moon build
        # --target native --release`. pkf uses mizchi/zlib's pure-MoonBit
        # deflate, so the binary links only libc — no system zlib needed.
        pkfMbt = pkgs.moonPlatform.buildMoonPackage {
          pname = "pkfire";
          version = "0.0.0";

          src = ./pkf-mbt;
          moonModJson = ./pkf-mbt/moon.mod.json;
          moonRegistryIndex = moon-registry;

          # Skip the in-sandbox `moon test` run; this derivation packages the
          # `pkf` binary, conformance is gated in CI.
          doCheck = false;
        };

        # `pkf` shells out to `pkl` at evaluation time. Wrap the binary so the
        # bundled Pkl CLI is on PATH for users who installed pkfire via Nix
        # without separately installing pkl. buildMoonPackage installs the
        # MoonBit output as `bin/pkf` (renamed from pkf.exe).
        pkfire = pkfMbt.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
          postInstall = (old.postInstall or "") + ''
            wrapProgram $out/bin/pkf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]}
          '';
          meta = (old.meta or { }) // (with pkgs.lib; {
            description = "Typed task runner with Bazel-style incremental caching, configured in Pkl";
            homepage = "https://github.com/mizchi/pkfire";
            license = licenses.mit;
            mainProgram = "pkf";
            platforms = platforms.unix;
          });
        });
      in {
        packages = {
          default = pkfire;
          pkfire = pkfire;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = pkfire;
          name = "pkf";
        };

        # `nix develop` for working on pkfire itself: Go toolchain plus
        # the Pkl CLI (needed for `pkl test` and pkl-go's evaluator).
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go
            pkl
            gopls
          ];
        };
      });
}
