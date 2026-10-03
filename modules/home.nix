{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  utils = self.lib;
  cfg = config.nix-home-utils;

  jsonType = (pkgs.formats.json { }).type;

  patchJsonOption =
    { ... }:
    {
      options = {
        path = mkOption {
          type = types.str;
          description = "JSON file to patch. Relative paths are resolved against HOME; absolute paths are used as-is.";
        };

        replaceFile = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Text used to replace the entire JSON file before options and extra are applied.";
        };

        options = mkOption {
          type = jsonType;
          default = { };
          description = "JSON object merged into the existing file with jq's recursive multiply operator.";
        };

        extra = mkOption {
          type = types.str;
          default = ".";
          description = "Additional jq filter applied after the merge.";
        };

      };
    };

  patchIniOption =
    { ... }:
    {
      options = {
        path = mkOption {
          type = types.str;
          description = "INI file to patch. Relative paths are resolved against HOME; absolute paths are used as-is.";
        };

        replaceFile = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Text used to replace the entire INI file before options are applied.";
        };

        options = mkOption {
          type = jsonType;
          default = { };
          description = "INI groups and keys to merge into the existing file. Nested attribute sets represent nested KConfig groups; null values remove keys.";
        };
      };
    };

  firefoxPatchOption =
    { ... }:
    {
      options = {
        extension = mkOption {
          type = types.nullOr (types.either types.package types.path);
          default = null;
          description = "Firefox extension package or path containing an XPI.";
        };

        profileName = mkOption {
          type = types.str;
          default = cfg.firefox.profileName;
          defaultText = "config.nix-home-utils.firefox.profileName";
          description = "Home Manager Firefox profile name. If declared under programs.firefox.profiles, its path is used; otherwise the name itself is used as the profile directory.";
        };

        replaceFile = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Text used to replace the entire extension storage file before options and extra are applied.";
        };

        options = mkOption {
          type = jsonType;
          default = { };
          description = "Extension storage JSON object to merge.";
        };

        extra = mkOption {
          type = types.str;
          default = ".";
          description = "Additional jq filter applied after the merge.";
        };

        extraAllowedSites = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional site origins to add to this extension in the Firefox profile's extension-preferences.json.";
        };
      };
    };

  enabledFirefoxPatches = lib.filterAttrs (
    _: patch: patch.extension != null
  ) cfg.patches.firefoxExtensions;

  unsupportedAllSites = [
    "<all_urls>"
    "*://*/*"
    "http://*/*"
    "https://*/*"
    "ws://*/*"
    "wss://*/*"
  ];

  # Match Home Manager's Firefox layout without relying on its internal
  # programs.firefox.profilesPath option.
  firefoxProfilesPath =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.programs.firefox.configPath}/Profiles"
    else
      config.programs.firefox.configPath;

  resolveFirefoxProfilePath =
    profileName:
    let
      profile = config.programs.firefox.profiles.${profileName} or null;
    in
    if profile == null then profileName else profile.path;

  firefoxExtensionStoragePath =
    profileName: extension:
    "${firefoxProfilesPath}/${resolveFirefoxProfilePath profileName}/browser-extension-data/${utils.getXpiGuid extension}/storage.js";

  mkPatchJson =
    patch:
    utils.patchJson {
      inherit lib pkgs;
      inherit (patch)
        path
        replaceFile
        options
        extra
        ;
    };

  mkPatchIni =
    patch:
    utils.patchIni {
      inherit lib pkgs;
      inherit (patch) path replaceFile options;
    };

  mkPatchFirefoxExtension =
    patch:
    utils.patchFirefoxExtension {
      inherit lib pkgs;
      profilesPath = firefoxProfilesPath;
      profilePath = resolveFirefoxProfilePath patch.profileName;
      inherit (patch)
        extension
        replaceFile
        options
        extra
        extraAllowedSites
        ;
    };

  extensionOrNull = attr: pkgs.firefoxAddons.${attr} or null;

  requireExtension = optionName: extension: {
    assertion = extension != null;
    message = "nix-home-utils.${optionName} requires pkgs.firefoxAddons.${optionName} or an explicit nix-home-utils.${optionName}.extension.";
  };

  mkShutUpActivation =
    let
      path = firefoxExtensionStoragePath cfg.firefox.profileName cfg.shutUp.extension;
      plaintextHostsJson = builtins.toJSON cfg.shutUp.hosts;
      hashedHostsJson = builtins.toJSON cfg.shutUp.hashedHosts;
      automaticAllowlistJson = builtins.toJSON cfg.shutUp.automaticAllowlist;
      contextMenuJson = builtins.toJSON cfg.shutUp.contextMenu;
    in
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      hash_shut_up_host() {
        input="$(${pkgs.coreutils}/bin/mktemp)"
        output="$(${pkgs.coreutils}/bin/mktemp)"
        printf '%s' "$1" > "$input"
        i=0
        while [ "$i" -lt 500 ]; do
          # Shut Up hashes binary digest bytes each round, then stores final bytes as lowercase hex.
          ${pkgs.openssl}/bin/openssl dgst -sha384 -binary "$input" > "$output"
          ${pkgs.coreutils}/bin/mv "$output" "$input"
          output="$(${pkgs.coreutils}/bin/mktemp)"
          i=$((i + 1))
        done
        ${pkgs.coreutils}/bin/od -An -tx1 -v "$input" | ${pkgs.coreutils}/bin/tr -d ' \n'
        printf '\n'
        ${pkgs.coreutils}/bin/rm "$input" "$output"
      }

      plaintext_hosts="$(${pkgs.coreutils}/bin/mktemp)"
      all_hosts="$(${pkgs.coreutils}/bin/mktemp)"
      patch="$(${pkgs.coreutils}/bin/mktemp)"

      printf '%s' ${lib.escapeShellArg plaintextHostsJson} | ${pkgs.jq}/bin/jq -r '.[]' > "$plaintext_hosts"
      : > "$all_hosts"
      while IFS= read -r host; do
        hash_shut_up_host "$host" >> "$all_hosts"
      done < "$plaintext_hosts"
      printf '%s' ${lib.escapeShellArg hashedHostsJson} | ${pkgs.jq}/bin/jq -r '.[]' >> "$all_hosts"

      hosts_json="$(${pkgs.jq}/bin/jq -R . "$all_hosts" | ${pkgs.jq}/bin/jq -s .)"
      ${pkgs.jq}/bin/jq -n \
        --argjson hosts "$hosts_json" \
        --argjson automaticAllowlist ${lib.escapeShellArg automaticAllowlistJson} \
        --argjson contextMenu ${lib.escapeShellArg contextMenuJson} \
        '{ allowlist: { hosts: $hosts, _initialized: true }, options: { automaticAllowlist: $automaticAllowlist, contextMenu: $contextMenu, _initialized: true } }' \
        > "$patch"

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
      (${pkgs.coreutils}/bin/cat "$target" 2>/dev/null || printf '%s' '{}') \
        | ${pkgs.jq}/bin/jq --slurpfile patch "$patch" '. * $patch[0]' > "$temp"
      ${pkgs.coreutils}/bin/mv -f "$temp" "$target"
      ${pkgs.coreutils}/bin/rm -f "$plaintext_hosts" "$all_hosts" "$patch" "$temp"
    '';

in
{
  options.nix-home-utils = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable nix-home-utils integrations.";
    };

    firefox.profileName = mkOption {
      type = types.str;
      default = "default";
      description = "Default Home Manager Firefox profile name used by extension patches.";
    };

    allowUnfree = mkOption {
      type = types.bool;
      default = false;
      description = "Write a per-user nixpkgs config.nix with allowUnfree = true for tools that still read ~/.config/nixpkgs/config.nix.";
    };

    patches.json = mkOption {
      type = types.attrsOf (types.submodule patchJsonOption);
      default = { };
      description = "Named JSON patches that are automatically added to home.activation.";
    };

    patches.ini = mkOption {
      type = types.attrsOf (types.submodule patchIniOption);
      default = { };
      description = "Named mutable INI patches that are automatically added to home.activation.";
    };

    patches.firefoxExtensions = mkOption {
      type = types.attrsOf (types.submodule firefoxPatchOption);
      default = { };
      description = "Named Firefox extension storage patches automatically added to home.activation.";
    };

    galaxyBudsClient = {
      path = mkOption {
        type = types.str;
        default = ".local/share/GalaxyBudsClient/settings.json";
      };
      settings = mkOption {
        type = jsonType;
        default = { };
        description = "Galaxy Buds Client settings to patch.";
      };
    };

    grayjay = {
      path = mkOption {
        type = types.str;
        default = ".local/share/Grayjay/settings.json";
      };
      settings = mkOption {
        type = jsonType;
        default = { };
        description = "Grayjay settings to patch.";
      };
    };

    losslessCut = {
      path = mkOption {
        type = types.str;
        default = ".config/LosslessCut/config.json";
        description = "LosslessCut JSON config path. Relative paths are resolved against HOME; absolute paths are used as-is.";
      };

      settings = mkOption {
        type = jsonType;
        default = { };
        description = "LosslessCut settings to patch.";
      };
    };

    onlyOffice = {
      path = mkOption {
        type = types.str;
        default = ".config/onlyoffice/DesktopEditors.conf";
        description = "OnlyOffice config path. Relative paths are resolved against HOME; absolute paths are used as-is.";
      };

      settings = mkOption {
        type = jsonType;
        default = { };
        description = "OnlyOffice settings to patch.";
      };
    };

    bypassPaywallsClean = mkOption {
      default = null;
      description = "Bypass Paywalls Clean storage patch. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "bypass-paywalls-clean";
            };
            enableNewSitesByDefault = mkOption {
              type = types.nullOr types.bool;
              default = null;
            };
            checkUpdateRulesAtStartup = mkOption {
              type = types.nullOr types.bool;
              default = null;
            };
            showOptionsOnUpdate = mkOption {
              type = types.nullOr types.bool;
              default = null;
            };
            options = mkOption {
              type = jsonType;
              default = { };
              description = "Additional Bypass Paywalls Clean storage values.";
            };
          };
        }
      );
    };

    cookieAutoDelete = mkOption {
      default = null;
      description = "Cookie AutoDelete storage patch. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "cookie-autodelete";
            };
            lists = mkOption {
              type = jsonType;
              description = "Cookie AutoDelete expression lists.";
            };
            settings = mkOption {
              type = jsonType;
              description = "Cookie AutoDelete settings.";
            };
          };
        }
      );
    };

    darkReader = mkOption {
      default = null;
      description = "Dark Reader activation storage patch. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "darkreader";
            };
            activationEmail = mkOption {
              type = types.str;
            };
            activationKey = mkOption {
              type = types.str;
            };
          };
        }
      );
    };

    searchByImage = mkOption {
      default = null;
      description = "Search by Image storage patch. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "search_by_image";
            };
            options = mkOption {
              type = jsonType;
              description = "Search by Image extension storage options.";
            };
          };
        }
      );
    };

    shutUp = mkOption {
      default = null;
      description = "Shut Up comment blocker storage patch. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "shut-up-comment-blocker";
            };
            hosts = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Plaintext hosts to allowlist. Each host is hashed 500 times with SHA-384 for Shut Up storage.";
            };
            hashedHosts = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Already-hashed Shut Up host allowlist entries.";
            };
            automaticAllowlist = mkOption {
              type = types.bool;
              default = true;
            };
            contextMenu = mkOption {
              type = types.bool;
              default = true;
            };
          };
        }
      );
    };

    ublacklist = mkOption {
      default = null;
      description = "uBlacklist storage replacement. Declaring this attribute set enables the patch.";
      type = types.nullOr (
        types.submodule {
          options = {
            extension = mkOption {
              type = types.nullOr (types.either types.package types.path);
              default = extensionOrNull "ublacklist";
            };
            replaceSettings = mkOption {
              type = types.lines;
              description = "Complete uBlacklist storage.js contents.";
            };
            extraAllowedSites = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional site origins to add for uBlacklist in Firefox extension preferences.";
            };
          };
        }
      );
    };

    autostart.items = mkOption {
      type = types.attrsOf (
        types.coercedTo types.str (exec: { inherit exec; }) (
          types.submodule (
            { name, ... }:
            {
              options.exec = mkOption {
                type = types.str;
                description = "Exec command for the generated desktop autostart entry.";
              };
            }
          )
        )
      );
      default = { };
      description = "Autostart desktop entries generated with nix-home-utils.lib.makeAutostartItem. Values may be Exec strings or attrsets with an exec field.";
    };

    apostrophe.previewActive = mkEnableOption "Apostrophe preview-active dconf setting";
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions =
        lib.optionals (cfg.bypassPaywallsClean != null) [
          (requireExtension "bypassPaywallsClean" cfg.bypassPaywallsClean.extension)
        ]
        ++ lib.optionals (cfg.cookieAutoDelete != null) [
          (requireExtension "cookieAutoDelete" cfg.cookieAutoDelete.extension)
        ]
        ++ lib.optionals (cfg.darkReader != null) [
          (requireExtension "darkReader" cfg.darkReader.extension)
        ]
        ++ lib.optionals (cfg.searchByImage != null) [
          (requireExtension "searchByImage" cfg.searchByImage.extension)
        ]
        ++ lib.optionals (cfg.shutUp != null) [
          (requireExtension "shutUp" cfg.shutUp.extension)
        ]
        ++ lib.optionals (cfg.ublacklist != null) [
          (requireExtension "ublacklist" cfg.ublacklist.extension)
        ]
        ++ lib.mapAttrsToList (name: patch: {
          assertion = lib.all (site: !(builtins.elem site unsupportedAllSites)) patch.extraAllowedSites;
          message = "nix-home-utils.patches.firefoxExtensions.${name}.extraAllowedSites cannot grant all-sites access; grant it through Firefox instead.";
        }) enabledFirefoxPatches;

      nix-home-utils.patches.json = mkMerge [
        (mkIf (cfg.galaxyBudsClient.settings != { }) {
          galaxyBudsClient = {
            path = cfg.galaxyBudsClient.path;
            options = cfg.galaxyBudsClient.settings;
          };
        })
        (mkIf (cfg.grayjay.settings != { }) {
          grayjay = {
            path = cfg.grayjay.path;
            options = cfg.grayjay.settings;
          };
        })
        (mkIf (cfg.losslessCut.settings != { }) {
          losslessCut = {
            path = cfg.losslessCut.path;
            options = cfg.losslessCut.settings;
          };
        })
      ];

      nix-home-utils.patches.ini = mkMerge [
        (mkIf (cfg.onlyOffice.settings != { }) {
          onlyOffice = {
            path = cfg.onlyOffice.path;
            options = cfg.onlyOffice.settings;
          };
        })
      ];

      nix-home-utils.patches.firefoxExtensions = mkMerge [
        (mkIf (cfg.bypassPaywallsClean != null) {
          bypassPaywallsClean = {
            extension = cfg.bypassPaywallsClean.extension;
            options =
              (lib.optionalAttrs (cfg.bypassPaywallsClean.checkUpdateRulesAtStartup != null) {
                optIn = cfg.bypassPaywallsClean.checkUpdateRulesAtStartup;
                optInFetch = cfg.bypassPaywallsClean.checkUpdateRulesAtStartup;
              })
              // (lib.optionalAttrs
                (
                  cfg.bypassPaywallsClean.enableNewSitesByDefault == true
                  || cfg.bypassPaywallsClean.checkUpdateRulesAtStartup == true
                )
                {
                  sites =
                    (lib.optionalAttrs (cfg.bypassPaywallsClean.enableNewSitesByDefault == true) {
                      "Enable new sites by default" = "#options_enable_new_sites";
                    })
                    // (lib.optionalAttrs (cfg.bypassPaywallsClean.checkUpdateRulesAtStartup == true) {
                      "Check for update rules at startup" = "#options_optin_update_rules";
                    });
                }
              )
              // cfg.bypassPaywallsClean.options;
            extra =
              if cfg.bypassPaywallsClean.showOptionsOnUpdate == false then
                "del(.sites.\"Show options on update\")"
              else
                ".";
          };
        })
        (mkIf (cfg.cookieAutoDelete != null) {
          cookieAutoDelete = {
            extension = cfg.cookieAutoDelete.extension;
            # To read, run: `jq '.state | fromjson' storage.js`
            options.state = builtins.toJSON {
              lists = cfg.cookieAutoDelete.lists;
              settings = cfg.cookieAutoDelete.settings;
            };
          };
        })
        (mkIf (cfg.darkReader != null) {
          darkReader = {
            extension = cfg.darkReader.extension;
            options = {
              activationEmail = cfg.darkReader.activationEmail;
              activationkey = cfg.darkReader.activationKey;
            };
          };
        })
        (mkIf (cfg.searchByImage != null) {
          searchByImage = {
            extension = cfg.searchByImage.extension;
            options = cfg.searchByImage.options;
          };
        })
        (mkIf (cfg.ublacklist != null) {
          ublacklist = {
            extension = cfg.ublacklist.extension;
            replaceFile = cfg.ublacklist.replaceSettings;
            extraAllowedSites = cfg.ublacklist.extraAllowedSites;
          };
        })
      ];

      home.activation =
        (lib.mapAttrs (_: mkPatchJson) cfg.patches.json)
        // (lib.mapAttrs (_: mkPatchIni) cfg.patches.ini)
        // (lib.mapAttrs (_: mkPatchFirefoxExtension) enabledFirefoxPatches)
        // (lib.optionalAttrs (cfg.shutUp != null) {
          shutUp = mkShutUpActivation;
        })
        // (lib.optionalAttrs cfg.allowUnfree {
          allowUnfree = utils.patchNixConfig {
            inherit lib pkgs;
            path = ".config/nixpkgs/config.nix";
          };
        });

      xdg.autostart.entries = lib.mapAttrsToList (
        name: item: utils.makeAutostartItem pkgs name item.exec
      ) cfg.autostart.items;
      xdg.autostart.enable = mkDefault (cfg.autostart.items != { });
    }

    (mkIf cfg.apostrophe.previewActive {
      # To read, run: `dconf dump /org/gnome/gitlab/somas/Apostrophe/`
      dconf.settings."org/gnome/gitlab/somas/Apostrophe"."preview-active" = true;
    })
  ]);
}
