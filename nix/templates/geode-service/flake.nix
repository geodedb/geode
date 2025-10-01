{
  description = "Geode Service Configuration Template";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    geode.url = "github:spyderorg/geode";
  };

  outputs = { self, nixpkgs, geode, ... }: {
    nixosConfigurations.geode-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        geode.nixosModules.geode
        ./configuration.nix
      ];
    };
  };
}