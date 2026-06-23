{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    # Pin a stable channel (not nixpkgs-unstable) for reproducible, non-churning
    # builds. Channel tarball (not github:) to avoid the unauthenticated GitHub API.
    nixpkgs.url = "https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz";
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
      "aarch64-linux"
      "aarch64-darwin"
      # No x86_64-darwin: the MoonBit toolchain has no Intel macOS build.
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

          # Ship the MoonBit native binary as the toolchain emitted it
          # (release-built; debug_info is small). The released tarballs come
          # from build-native.sh, not Nix, so this only affects the nix package.
          dontStrip = true;
        };

        # `pkf` shells out to `pkl` at evaluation time. Wrap the binary so the
        # bundled Pkl CLI is on PATH for users who installed pkfire via Nix
        # without separately installing pkl. buildMoonPackage installs the
        # MoonBit output as `bin/pkf` (renamed from pkf.exe).
        # Wrap the raw `buildMoonPackage` output in a separate runCommand so
        # the wrapper is guaranteed to apply (buildMoonPackage doesn't honour
        # the stdenv postInstall hook). Two runtime needs:
        #   1. `moonbitlang/async`'s TLS module dlopen()s `libssl.so.3` during
        #      moonbit_init (runs unconditionally at startup), so libssl must
        #      be findable or the binary core-dumps before main (moonbit_panic
        #      ← tls.load__openssl). The Nix closure has no system OpenSSL →
        #      put it on LD_LIBRARY_PATH (dlopen consults LD_LIBRARY_PATH;
        #      DT_RUNPATH does NOT apply to dlopen, so patchelf --add-rpath
        #      would not help). macOS dlopen's /usr/lib system libssl, so this
        #      is a no-op there.
        #   2. `pkf` shells out to `pkl` — keep it on PATH.
        pkfire = pkgs.runCommand "pkfire-${pkfMbt.version or "0.0.0"}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            meta = (pkfMbt.meta or { }) // (with pkgs.lib; {
              description = "Typed task runner with Bazel-style incremental caching, configured in Pkl";
              homepage = "https://github.com/mizchi/pkfire";
              license = licenses.mit;
              mainProgram = "pkf";
              # MoonBit toolchain targets: linux x86_64/arm64 + darwin arm64
              # (no Intel macOS build).
              platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
            });
          } ''
          mkdir -p $out/bin
          makeWrapper ${pkfMbt}/bin/pkf $out/bin/pkf \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]} \
            --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}
        '';
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
