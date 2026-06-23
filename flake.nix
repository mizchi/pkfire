{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    # Stable channel: nixpkgs-unstable ships glibc 2.42, against which the
    # MoonBit native runtime aborts (silent SIGABRT at startup) on x86_64-linux.
    # A stable release's older glibc matches what the official toolchain targets.
    # Channel tarball (not github:) to avoid the unauthenticated GitHub API.
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

          # Don't strip the MoonBit native binary: on x86_64-linux the
          # default `strip -S -p` corrupts it (it runs but aborts/core-dumps
          # at startup); macOS strip leaves it runnable. The binary is already
          # release-built and links only libc, so stripping buys little.
          dontStrip = true;
        };

        # `pkf` shells out to `pkl` at evaluation time. Wrap the binary so the
        # bundled Pkl CLI is on PATH for users who installed pkfire via Nix
        # without separately installing pkl. buildMoonPackage installs the
        # MoonBit output as `bin/pkf` (renamed from pkf.exe).
        pkfire = pkfMbt.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
          # `moonbitlang/async`'s TLS module dlopen()s OpenSSL during
          # moonbit_init (global init runs unconditionally at startup); if
          # libssl isn't findable the binary core-dumps before main
          # (moonbit_panic ← tls.load__openssl). The Nix closure has no
          # system OpenSSL, so put it on LD_LIBRARY_PATH via the wrapper.
          postInstall = (old.postInstall or "") + ''
            wrapProgram $out/bin/pkf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]} \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}
          '';
          meta = (old.meta or { }) // (with pkgs.lib; {
            description = "Typed task runner with Bazel-style incremental caching, configured in Pkl";
            homepage = "https://github.com/mizchi/pkfire";
            license = licenses.mit;
            mainProgram = "pkf";
            # MoonBit toolchain targets: linux x86_64/arm64 + darwin arm64
            # (no Intel macOS build).
            platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
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
