{
  description = "l4sh: a Lean 4 shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      runtimeDeps = with pkgs; [
        lean4
        elan
        pigz
        direnv
      ];

      l4sh = pkgs.stdenvNoCC.mkDerivation {
        pname = "l4sh";
        version = "0.1.0";
        src = self;
        nativeBuildInputs = [pkgs.makeWrapper];
        dontBuild = true;
        installPhase = ''
          mkdir -p $out/bin $out/share/l4sh
          cp -r . $out/share/l4sh/
          rm -rf $out/share/l4sh/{.envrc,.claude,flake.nix,flake.lock}
          install -Dm755 l4sh $out/bin/l4sh
          wrapProgram $out/bin/l4sh \
            --prefix PATH : ${pkgs.lib.makeBinPath (runtimeDeps ++ [pkgs.git pkgs.stdenv.cc])} \
            --set IN_L4SH_NIX_SHELL 1 \
            --set L4SH_SOURCE $out/share/l4sh
        '';
        meta.mainProgram = "l4sh";
      };
    in {
      packages = {
        inherit l4sh;
        default = l4sh;
      };

      devShells.default = pkgs.mkShell {
        nativeBuildInputs = runtimeDeps;
      };
    });
}
