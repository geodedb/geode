{
  description = "geode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    devnw.url = "git+https://vcs.devnw.com/devnw/flakes";
  };

  outputs =
    {
      self,
      nixpkgs,
      devnw,
      flake-utils,
      flake-compat,
      ...
    }:
    let
      geode-binary =
        pkgs:
        pkgs.buildGoModule rec {
          pname = "geode";
          version = "0.1.0";
          vendorHash = null;

          src = ./.;
          nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.makeWrapper
          ];

          doCheck = false;

          buildPhase = with pkgs; ''
            ${pkgs.go_1_24}/bin/go build ./cmd/geode/
          '';

          installPhase = with pkgs; ''
            mkdir -p $out/bin
            ${pkgs.go_1_24}/bin/go build -o $out/bin/ ./cmd/geode/
          '';

          postInstall = pkgs.lib.optionalString pkgs.stdenv.isLinux '''';
        };

      flakeForSystem =
        nixpkgs: system:
        let
          isDarwin = builtins.elem system [
            "aarch64-darwin"
            "x86_64-darwin"
          ];
          pkgs = nixpkgs.legacyPackages.${system};
          ml = geode-binary pkgs;
        in
        {
          packages = {
            default = ml;
            geode = ml;
          };

          devShell = pkgs.mkShell {
            shellHook = ''
              #cachix use devnw-flakes
            '';
            env = {
            };
            packages =
              (with devnw.packages.${system}; [
                commonPackages
                zigPackages
              ])
              ++ (with pkgs; [
              ]);
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system: flakeForSystem nixpkgs system);

  #nixConfig = {
  #  extra-substituters = ["devnw-flakes.cachix.org"];
  #  extra-trusted-public-keys = ["devnw-flakes.cachix.org-1:ihw2M3SGlG7jiEa1TolVbRfKyR6waZiRpbwdkWOF2zw="];
  #};
}
