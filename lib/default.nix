{ lib }:

rec {
  getXpiGuid =
    extension:
    let
      findFirstXpi =
        path:
        let
          entries = builtins.readDir path;
          names = builtins.attrNames entries;
          loop =
            xs:
            if xs == [ ] then
              null
            else
              let
                name = builtins.head xs;
                kind = entries.${name};
                full = "${path}/${name}";
              in
              if kind == "regular" && lib.hasSuffix ".xpi" name then
                name
              else if kind == "directory" then
                let
                  found = findFirstXpi full;
                in
                if found != null then found else loop (builtins.tail xs)
              else
                loop (builtins.tail xs);
        in
        loop names;
      xpi = findFirstXpi "${extension}";
    in
    if xpi == null then
      throw "nix-home-utils.getXpiGuid: no .xpi file found in ${extension}"
    else
      lib.removeSuffix ".xpi" xpi;

  mkPatchJsonActivation =
    {
      lib,
      pkgs,
      path,
      replaceFile ? null,
      options,
      extra ? ".",
    }:
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg path}
      case "$target" in
        /*) ;;
        *) target="$HOME/$target" ;;
      esac

      target_dir="$(${pkgs.coreutils}/bin/dirname "$target")"
      target_base="$(${pkgs.coreutils}/bin/basename "$target")"
      ${pkgs.coreutils}/bin/mkdir -p "$target_dir"
      temp="$(${pkgs.coreutils}/bin/mktemp "$target_dir/.''${target_base}.tmp.XXXXXX")"
      if [ -e "$target" ]; then
        ${pkgs.coreutils}/bin/chmod --reference="$target" "$temp"
      fi
      ${
        if replaceFile == null then
          ''(${pkgs.coreutils}/bin/cat "$target" 2>/dev/null || printf '%s' '{}')''
        else
          "printf '%s' ${lib.escapeShellArg replaceFile}"
      } \
        | ${pkgs.jq}/bin/jq --argjson patch ${lib.escapeShellArg (builtins.toJSON options)} '. * $patch' \
        | ${pkgs.jq}/bin/jq ${lib.escapeShellArg extra} > "$temp"
      ${pkgs.coreutils}/bin/mv -f "$temp" "$target"
    '';

  mkPatchIniActivation =
    {
      lib,
      pkgs,
      path,
      replaceFile ? null,
      options,
    }:
    let
      patchIniScript = pkgs.writeShellApplication {
        name = "patch-ini";
        runtimeInputs = [ pkgs.python3 ];
        text = ''python ${./patch_ini.py} "$@"'';
      };
    in
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg path}
      case "$target" in
        /*) ;;
        *) target="$HOME/$target" ;;
      esac

      ${patchIniScript}/bin/patch-ini "$target" ${lib.escapeShellArg (builtins.toJSON options)} ${lib.escapeShellArg (builtins.toJSON replaceFile)}
    '';

  mkPatchNixConfigActivation =
    {
      lib,
      pkgs,
      path,
    }:
    let
      patchNixConfigScript = pkgs.writeShellApplication {
        name = "patch-nix-config";
        runtimeInputs = [ pkgs.python3 ];
        text = ''python ${./patch_nix_config.py} "$@"'';
      };
    in
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      target=${lib.escapeShellArg path}
      case "$target" in
        /*) ;;
        *) target="$HOME/$target" ;;
      esac

      ${patchNixConfigScript}/bin/patch-nix-config "$target"
    '';

  # See: https://github.com/nix-community/home-manager/issues/6361#issuecomment-4265948928
  mkPatchFirefoxExtensionActivation =
    {
      lib,
      pkgs,
      extension,
      replaceFile ? null,
      options,
      extra ? ".",
      extraAllowedSites ? [ ],
      profilesPath ? ".config/mozilla/firefox",
      profileName ? "default",
      profilePath ? null,
    }:
    let
      resolvedProfilePath = if profilePath == null then profileName else profilePath;
      guid = getXpiGuid extension;
      storagePatch = mkPatchJsonActivation {
        inherit
          lib
          pkgs
          options
          extra
          replaceFile
          ;
        path = "${profilesPath}/${resolvedProfilePath}/browser-extension-data/${guid}/storage.js";
      };
      allowedSitesPatch = mkPatchJsonActivation {
        inherit lib pkgs;
        path = "${profilesPath}/${resolvedProfilePath}/extension-preferences.json";
        options = { };
        extra = ".${builtins.toJSON guid}.origins = (reduce ${builtins.toJSON extraAllowedSites}[] as $site ((.${builtins.toJSON guid}.origins // []); if index($site) == null then . + [$site] else . end))";
      };
    in
    storagePatch
    // {
      data = storagePatch.data + lib.optionalString (extraAllowedSites != [ ]) allowedSitesPatch.data;
    };

  patchJson = mkPatchJsonActivation;
  patchIni = mkPatchIniActivation;
  patchNixConfig = mkPatchNixConfigActivation;
  patchFirefoxExtension = mkPatchFirefoxExtensionActivation;

  makeAutostartItem =
    pkgs: name: exec:
    "${
      pkgs.makeDesktopItem {
        inherit name exec;
        destination = "";
        desktopName = name;
        startupNotify = false;
        terminal = false;
      }
    }/${name}.desktop";
}
