{
  description = "Profile pictures, convenient JSON patching, Firefox extension settings and more for Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    {
      lib = import ./lib { inherit (nixpkgs) lib; };

      homeModules.default = import ./modules/home.nix { inherit self; };

      nixosModules.default = import ./modules/nixos.nix;
    };
}
