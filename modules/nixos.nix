{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkAfter
    mkOption
    types
    ;
  cfg = config.nix-home-utils.profilePhotos;

  profilePhotoOption =
    { name, ... }:
    {
      options.source = mkOption {
        type = types.path;
        description = "Image file to use as ${name}'s profile photo.";
      };
    };
in
{
  options.nix-home-utils.profilePhotos = mkOption {
    type = types.attrsOf (types.submodule profilePhotoOption);
    default = { };
    description = "Profile photos keyed by user name. Configures Home Manager .face.icon and AccountsService.";
  };

  config = {
    home-manager.users = lib.mapAttrs (_: photo: {
      home.file.".face.icon" = {
        source = photo.source;
        force = true;
      };
    }) cfg;

    # See: https://github.com/NixOS/nixpkgs/issues/163080#issuecomment-1135601735
    boot.postBootCommands = mkAfter (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          userName: photo:
          let
            accountsServiceConfig = ''
              [User]
              Session=
              Icon=${photo.source}
              SystemAccount=false
            '';
          in
          ''
            echo '${accountsServiceConfig}' > /var/lib/AccountsService/users/${userName}
          ''
        ) cfg
      )
    );
  };
}
