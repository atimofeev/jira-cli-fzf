{
  description = "A simple, interactive TUI for Jira using jira-cli and fzf";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "jira-cli-fzf";
        version = "0.1.0";
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          
          # proper source filtering
          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ pkgs.bash ];

          installPhase = ''
            mkdir -p $out/bin
            cp main.sh $out/bin/${pname}
            chmod +x $out/bin/${pname}
            
            # wrap with runtime dependencies
            wrapProgram $out/bin/${pname} \
              --prefix PATH : ${pkgs.lib.makeBinPath [ 
                pkgs.jira-cli-go 
                pkgs.fzf 
                pkgs.gawk 
                pkgs.gnused 
                pkgs.gnugrep 
                pkgs.findutils 
                pkgs.coreutils 
              ]}
          '';

          meta = with pkgs.lib; {
            description = "Interactive Jira TUI using fzf and jira-cli-go";
            homepage = "https://github.com/atimofeev/jira-cli-fzf";
            license = licenses.mit;
            platforms = platforms.all;
            mainProgram = pname;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.jira-cli-go
            pkgs.fzf
          ];
        };
      });
}
