{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    # Pin a stable channel (not nixpkgs-unstable) for reproducible, non-churning
    # builds. Channel tarball (not github:) to avoid the unauthenticated GitHub API.
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.xz";
    flake-utils.url = "git+https://github.com/numtide/flake-utils.git";

    # MoonBit toolchain for the `nix develop` shell (building the pkf sources
    # at the repo root). The package itself no longer builds from source — it installs
    # the prebuilt release binary — so the mooncakes index input is gone.
    moonbit-overlay.url = "git+https://github.com/moonbit-community/moonbit-overlay.git";
  };

  outputs = { self, nixpkgs, flake-utils, moonbit-overlay }:
    let
      # pkf is distributed as a prebuilt MoonBit binary. This flake installs
      # the release tarball rather than compiling from source (fast, and the
      # same artifact `install.sh` / the GitHub Action ship).
      #
      # `version` + the per-platform sha256 live in `nix/pkf-release.json`,
      # which the release workflow (.github/workflows/pkl-publish.yml) auto-
      # regenerates from the freshly built checksums and opens a follow-up PR
      # for. To bump by hand: set version, then refresh each sha256 from
      #   curl -fsSL https://github.com/mizchi/pkfire/releases/download/pkfire@<v>/pkf-<plat>.tar.gz.sha256
      # (no x86_64-darwin: the MoonBit toolchain has no Intel macOS build.)
      release = builtins.fromJSON (builtins.readFile ./nix/pkf-release.json);
      version = release.version;
      assets = release.platforms;
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

        apps.default = (flake-utils.lib.mkApp {
          drv = pkfire;
          name = "pkf";
        }) // {
          meta.description = "Run the pkf task runner";
        };

        # `nix develop` for working on pkfire itself: the MoonBit toolchain
        # (`moon`, `moonc`, …) to build the pkf sources from source, plus the Pkl
        # CLI (needed for `pkl test` and `pkl format`).
        devShells.default = pkgs.mkShell {
          packages = [
            moonbit-overlay.packages.${system}.default
            pkgs.pkl
          ];
        };
      });
}
