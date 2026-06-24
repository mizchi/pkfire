{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    # Pin a stable channel (not nixpkgs-unstable) for reproducible, non-churning
    # builds. Channel tarball (not github:) to avoid the unauthenticated GitHub API.
    nixpkgs.url = "https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz";
    flake-utils.url = "github:numtide/flake-utils";

    # MoonBit toolchain for the `nix develop` shell (building pkf-mbt/ from
    # source). The package itself no longer builds from source — it installs
    # the prebuilt release binary — so the mooncakes index input is gone.
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, moonbit-overlay }:
    let
      # pkf is distributed as a prebuilt MoonBit binary. This flake installs
      # the release tarball rather than compiling from source (fast, and the
      # same artifact `install.sh` / the GitHub Action ship).
      #
      # To bump after cutting a new release: set `version`, then refresh each
      # sha256 from the published checksums, e.g.
      #   curl -fsSL https://github.com/mizchi/pkfire/releases/download/pkfire@<v>/pkf-<plat>.tar.gz.sha256
      version = "0.12.0";
      assets = {
        "x86_64-linux" = {
          plat = "linux-amd64";
          sha256 = "c4f18db054f27059ebd9ee01a24cad4f4a3f2963d3b53b51ddd1485db6d94d31";
        };
        "aarch64-linux" = {
          plat = "linux-arm64";
          sha256 = "f43abea5c848d2d40b90aac9f70737e1183542c50c923ebb9da63b6046823361";
        };
        "aarch64-darwin" = {
          plat = "darwin-arm64";
          sha256 = "46868135583f4a8d8cb91fb8c11bbfac54dd727ca9645107294c8ad2993a7472";
        };
        # No x86_64-darwin: the MoonBit toolchain has no Intel macOS build.
      };
    in
    flake-utils.lib.eachSystem (builtins.attrNames assets) (system:
      let
        pkgs = import nixpkgs { inherit system; };
        asset = assets.${system};
        isLinux = pkgs.stdenv.hostPlatform.isLinux;

        tarball = pkgs.fetchurl {
          url = "https://github.com/mizchi/pkfire/releases/download/pkfire@${version}/pkf-${asset.plat}.tar.gz";
          sha256 = asset.sha256;
        };

        # Install the prebuilt `pkf`. On Linux the binary was built on a
        # generic runner, so autoPatchelfHook rewrites the ELF interpreter +
        # rpath for the Nix closure (the binary links only libc — pkf uses
        # pure-MoonBit deflate, no system zlib). Two runtime wraps:
        #   1. `pkf` shells out to `pkl` — keep it on PATH.
        #   2. moonbitlang/async's TLS module dlopen()s libssl.so.3 at startup
        #      (unconditional). dlopen consults LD_LIBRARY_PATH (not DT_RUNPATH),
        #      so autoPatchelf can't help — put openssl on LD_LIBRARY_PATH.
        #      macOS dlopen's /usr/lib system libssl, so this is Linux-only.
        pkfire = pkgs.stdenv.mkDerivation {
          pname = "pkfire";
          inherit version;
          src = tarball;
          dontUnpack = true;

          nativeBuildInputs = [ pkgs.makeWrapper ]
            ++ pkgs.lib.optionals isLinux [ pkgs.autoPatchelfHook ];
          # autoPatchelfHook resolves the binary's NEEDED libs against these.
          buildInputs = pkgs.lib.optionals isLinux [ pkgs.stdenv.cc.cc.lib ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            tar -xzf "$src"
            install -m 0755 pkf $out/bin/pkf
            runHook postInstall
          '';

          postFixup = ''
            wrapProgram $out/bin/pkf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]} \
              ${pkgs.lib.optionalString isLinux
                "--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}"}
          '';

          meta = with pkgs.lib; {
            description = "Typed task runner with Bazel-style incremental caching, configured in Pkl";
            homepage = "https://github.com/mizchi/pkfire";
            license = licenses.mit;
            mainProgram = "pkf";
            platforms = builtins.attrNames assets;
          };
        };
      in {
        packages = {
          default = pkfire;
          pkfire = pkfire;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = pkfire;
          name = "pkf";
        };

        # `nix develop` for working on pkfire itself: the MoonBit toolchain
        # (`moon`, `moonc`, …) to build `pkf-mbt/` from source, plus the Pkl
        # CLI (needed for `pkl test` and `pkl format`).
        devShells.default = pkgs.mkShell {
          packages = [
            moonbit-overlay.packages.${system}.default
            pkgs.pkl
          ];
        };
      });
}
