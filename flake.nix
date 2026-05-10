{
  description = "pkfire — typed task runner with Bazel-style incremental caching, configured in Pkl";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkfire = pkgs.buildGoModule {
          pname = "pkfire";
          version = "0.0.0";
          src = ./.;

          vendorHash = "sha256-eGmZwV2Cay+OqadqozvCNf3vhWUa6xcBfVCa7meOQWY=";

          subPackages = [ "cmd/pkf" ];

          ldflags = [ "-s" "-w" ];

          # `pkf` shells out to `pkl` (via pkl-go) at evaluation time.
          # Wrap the binary so the bundled Pkl CLI is on PATH for users
          # who installed pkfire via Nix without separately installing pkl.
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/pkf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]}
          '';

          meta = with pkgs.lib; {
            description = "Typed task runner with Bazel-style incremental caching, configured in Pkl";
            homepage = "https://github.com/mizchi/pkfire";
            license = licenses.mit;
            mainProgram = "pkf";
            platforms = platforms.unix;
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
