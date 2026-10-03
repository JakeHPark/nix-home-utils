# Nix Home Utils

Profile pictures, convenient JSON patching, Firefox extension settings and more for Home Manager.

## Adding

```nix
{
  inputs.nix-home-utils = {
    url = "github:JakeHPark/nix-home-utils";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };
}
```

## Importing

For Home Manager inside NixOS, add the Home Manager module to `sharedModules`:

```nix
{
  home-manager.sharedModules = [
    nix-home-utils.homeModules.default
  ];
}
```

For standalone Home Manager, add it to your `homeManagerConfiguration` modules:

```nix
{
  homeConfigurations.jakehpark = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      nix-home-utils.homeModules.default
      ./home.nix
    ];
  };
}
```

The profile photo helper is a NixOS module, so import it at the system level:

```nix
{
  imports = [
    nix-home-utils.nixosModules.default
  ];
}
```

## Partial Atomic JSON Patches

Use this when an app stores JSON in your home directory and you only want to enforce a few keys without leaving behind an immutable file:

```nix
{
  nix-home-utils.patches.json.someApp = {
    path = ".config/some-app/config.json";
    options = {
      enableUpdateCheck = false;
      ui.theme = "system";
    };
  };
}
```

If the JSON does not already exist, it is created. And if you need a final `jq` cleanup:

```nix
{
  nix-home-utils.patches.json.someApp.extra = "del(.temporaryMigrationState)";
}
```

Set `replaceFile` to replace the whole file before applying `options` and `extra`:

```nix
{
  nix-home-utils.patches.json.someApp = {
    path = ".config/some-app/config.json";
    replaceFile = builtins.readFile ./config.json;
    options.ui.theme = "system";
  };
}
```

For Firefox extensions:

```nix
{
  nix-home-utils.patches.firefoxExtensions.someExtension = {
    extension = pkgs.firefoxAddons.some-extension;
    replaceFile = builtins.readFile ./storage.js;
    options = {
      enabled = true;
    };
    extraAllowedSites = [
      "https://example.com/*"
    ];
    extra = "del(.toRemove)";
  };
}
```

`extraAllowedSites` updates the extension GUID's `origins` array in the selected Firefox profile's `extension-preferences.json`. Existing origins are preserved, and a requested origin is appended only when it is not already present. Firefox handles all-sites grants specially, so patterns such as `"*://*/*"` and `"<all_urls>"` are rejected; grant all-sites access through Firefox instead.

Set `profileName` on a single Firefox patch if needed:

```nix
{
  nix-home-utils.patches.firefoxExtensions.someExtension.profileName = "work";
}
```

## Partial Atomic INI Patches

Use this when an app stores INI/KConfig-style settings and you only want to patch selected keys while keeping the file mutable:

```nix
{
  nix-home-utils.patches.ini.someApp = {
    path = ".config/some-app/settingsrc";
    options = {
      General = {
        Theme = "system";
        EnableAnimations = false;
      };
      Event.DuplicatesFinder.Enabled = true; # [Event][DuplicatesFinder]
      "Event/DuplicatesFinder".Enabled = false; # [Event/DuplicatesFinder]
      Nested.Group.SomeKey = {
        value = "expanded-value";
        shellExpand = true;
      };
    };
  };
}
```

If the INI file does not already exist, it is created. Unspecified keys are preserved. Set a key to `null` to remove it:

```nix
{
  nix-home-utils.patches.ini.someApp.options.General.OldKey = null;
}
```

`replaceFile = builtins.readFile ./settingsrc;` replaces the complete INI file first, then applies `options`.

INI keys follow the same low-level style as [Plasma Manager](https://github.com/nix-community/plasma-manager)'s `programs.plasma.configFile`: values may be `null`, booleans, numbers, or strings, and can also be written as an attribute set with `value`, `immutable`, `shellExpand`, `persistent`, and `escapeValue`. Unlike Plasma Manager's slash-separated group syntax, `/` is literal here; use nested Nix attributes for nested KConfig groups.

## Autostart Entries

```nix
{
  nix-home-utils.autostart.items = {
    GalaxyBudsClient = "${pkgs.galaxy-buds-client}/bin/GalaxyBudsClient /StartMinimized";
    qpwgraph = "${pkgs.qpwgraph}/bin/qpwgraph";
  };
}
```

This writes generated desktop entries into `xdg.autostart.entries` with `startupNotify = false;` and `terminal = false;`. The longer
`Name.exec = "Exec";` form is also supported in case I ever decide to add other attributes.

## Per-user Unfree Packages

```nix
{
  nix-home-utils.allowUnfree = true;
}
```

This atomically patches `~/.config/nixpkgs/config.nix` to contain:

```nix
{
  allowUnfree = true;
}
```

Unrelated top-level settings in that file are preserved. This is intentionally separate from Home Manager's `nixpkgs.config` and is useful for tools such as `nix-shell` that still read the legacy per-user nixpkgs config. This only does anything if `allowUnfree` is `true`; setting it to `false` does *not* set it back to `false` in `config.nix`, since this would be a rather redundant use case.

## Profile Photos

Import `nix-home-utils.nixosModules.default`, then configure users by name **in the global configuration**:

```nix
{
  nix-home-utils.profilePhotos = {
    jakehpark.source = ./modules/plasma/jakehpark.jpg;
    another-user.source = ./modules/plasma/another-user.jpg;
  };
}
```

For each user this sets Home Manager's `.face.icon` and writes the AccountsService file from `boot.postBootCommands`.

## App Shortcuts

### Apostrophe

```nix
{
  nix-home-utils.apostrophe.previewActive = true;
}
```

Sets:

```nix
dconf.settings."org/gnome/gitlab/somas/Apostrophe"."preview-active" = true;
```

This makes Apostrophe primarily a Markdown reader application, which is useful if you want to use something else like Neovim for editing, and Apostrophe for rendering.

### Galaxy Buds Client

```nix
{
  nix-home-utils.galaxyBudsClient.settings = {
    # For example:
    MinimizeToTray = true;
  };
}
```

Patches:

```text
~/.local/share/GalaxyBudsClient/settings.json
```

### Grayjay

```nix
{
  nix-home-utils.grayjay.settings = {
    # For example:
    Search.SearchHistory = false;
    Playback.DefaultPlaybackSpeed = 3;
    Synchronization.Enabled = true;
    Notifications.AppUpdates = false;
  };
}
```

Patches:

```text
~/.local/share/Grayjay/settings.json
```

### LosslessCut

```nix
{
  nix-home-utils.losslessCut.settings = {
    # For example:
    enableUpdateCheck = false;
    askBeforeClose = false;
  };
}
```

Patches:

```text
~/.config/LosslessCut/config.json
```

### OnlyOffice

```nix
{
  nix-home-utils.onlyOffice.settings = {
    # For example:
    General.UITheme = "theme-night";
    General.maximized = true;
    General.savePath = "${config.home.homeDirectory}/Desktop";
  };
}
```

Patches:

```text
~/.config/onlyoffice/DesktopEditors.conf
```

Also see my [Nix OnlyOffice](https://github.com/JakeHPark/nix-onlyoffice) for proper setup.

## Firefox Extension Shortcuts

Firefox extension shortcuts expect packages under `pkgs.firefoxAddons`, as with [`nix-firefox-addons`](https://github.com/OsiPog/nix-firefox-addons). If yours are named differently, set the relevant `extension` option explicitly.

Declaring a shortcut's attribute set enables its patch; there is no separate `enable` option.

All Firefox extension shortcuts patch:

```text
~/.config/mozilla/firefox/<profile>/browser-extension-data/<xpi-guid>/storage.js
```

The default profile is `default`. Change it globally with:

```nix
{
  nix-home-utils.firefox.profileName = "main";
}
```

[Here's](https://gist.github.com/JakeHPark/79acbaa74c426eb18c14adfe191ea7d5) an example of how I configure my Firefox, in case you need inspiration.

### Firefox paths and profiles

The Home Manager module does not hardcode `~/.mozilla/firefox` or `~/.config/mozilla/firefox`. It follows `programs.firefox.configPath`.

With Home Manager 26.05, the default path depends on `home.stateVersion`: older configurations retain `.mozilla/firefox`, while 26.05 and newer configurations default to `${config.xdg.configHome}/mozilla/firefox` (normally `~/.config/mozilla/firefox`). Relative paths are resolved against `$HOME`; absolute paths are used unchanged. On Darwin, the module also follows Home Manager's `Profiles` subdirectory layout.

`nix-home-utils.firefox.profileName` is the Home Manager profile name, not necessarily the on-disk directory name. If that profile exists under `programs.firefox.profiles`, nix-home-utils follows its `path` option:

```nix
{
  programs.firefox.profiles.personal.path = "firefox-personal";
  nix-home-utils.firefox.profileName = "personal";
}
```

That patches `<Firefox profiles path>/firefox-personal/browser-extension-data/...`. If the named profile is not declared through Home Manager, the name itself is used as the profile directory. This preserves support for externally-created profiles while following Home Manager whenever it has richer information.

### Bypass Paywalls Clean

Get `pkgs.firefoxAddons.bypass-paywalls-clean` with my [Nix Bypass Paywalls Clean](https://github.com/JakeHPark/nix-bypass-paywalls-clean). Then:

```nix
{
  nix-home-utils.bypassPaywallsClean = {
    # All settings are optional:
    enableNewSitesByDefault = true;
    checkUpdateRulesAtStartup = true;
    showOptionsOnUpdate = false;
  };
}
```

Extra raw storage values can go in `options`:

```nix
{
  nix-home-utils.bypassPaywallsClean.options = {
    customShown = true;
  };
}
```

These are found here:

```bash
~/.config/mozilla/firefox/default/browser-extension-data/magnolia@12.34/storage.js
```

I wanted to also add an option to enable Bypass Paywalls Clean automatically on all sites to get rid of the annoying permissions dialogue on update, but there's no clean way to do this.

### Cookie AutoDelete

```nix
{
  nix-home-utils.cookieAutoDelete = {
    lists = builtins.fromJSON (builtins.readFile ./cookie-autodelete-expressions.json);
    settings = builtins.fromJSON (builtins.readFile ./cookie-autodelete-settings.json);
  };
}
```

You can use the export buttons in the Cookie AutoDelete extension to retrieve these. Alternatively, you can extract them via `jq`:

```bash
cd ~/.config/mozilla/firefox/default/browser-extension-data/CookieAutoDelete@kennydo.com
# For total state:
jq '.state | fromjson' storage.js > cookie-autodelete-state.json
# For just the expressions:
jq '(.state | fromjson).lists' storage.js > cookie-autodelete-expressions.json
# For just the settings:
jq '(.state | fromjson).settings' storage.js > cookie-autodelete-settings.json
```

### Dark Reader

```nix
{
  nix-home-utils.darkReader = {
    activationEmail = "name@example.com";
    activationKey = "...";
  };
}
```

Both activation values are required when Dark Reader is configured.

### Search by Image

```nix
{
  nix-home-utils.searchByImage = {
    options = builtins.fromJSON (builtins.readFile ./search-by-image.json);
  };
}
```

You can find this at:

```bash
~/.config/mozilla/firefox/default/browser-extension-data/{2e5ff8c8-32fe-46d0-9fc8-6b8986621f3c}/storage.js
```

### uBlacklist

Replace uBlacklist's settings completely:

```nix
{
  nix-home-utils.ublacklist = {
    replaceSettings = builtins.readFile ./ublacklist.json;
    extraAllowedSites = [
      "https://search.brave.com/*"
      "https://ublacklist.github.io/*"
    ];
  };
}
```

### Shut Up

```nix
{
  nix-home-utils.shutUp = {
    hosts = [
      "github.com"
      "example.com"
    ];
  };
}
```

The module hashes them the same way Shut Up does: SHA-384 over binary digest bytes, [repeated 500 times](https://github.com/RickyRomero/shut-up-webextension/blob/c9447f85677bc4d24c59e5792a68b99a906ad1bf/src/core/allowlist.js#L55-L64), stored as lowercase hex.

Already have precomputed hashes?

```nix
{
  nix-home-utils.shutUp.hashedHosts = [
    "some-precomputed-host-hash"
  ];
}
```

Defaults:

```nix
{
  hosts = [ ];
  hashedHosts = [ ];
  automaticAllowlist = true;
  contextMenu = true;
}
```

## Library Exports

```nix
nix-home-utils.lib.getXpiGuid pkgs.firefoxAddons.ublock-origin
nix-home-utils.lib.patchJson { inherit lib pkgs; path = "..."; options = { }; }
nix-home-utils.lib.patchIni { inherit lib pkgs; path = "..."; options = { }; }
nix-home-utils.lib.patchFirefoxExtension {
  inherit lib pkgs;
  profilesPath = "...";
  profilePath = "...";
  extension = pkgs.firefoxAddons.foo;
  options = { };
}
nix-home-utils.lib.makeAutostartItem pkgs "qpwgraph" "${pkgs.qpwgraph}/bin/qpwgraph"
```

Most of these should be redundant given the module options. For direct `patchFirefoxExtension` calls, `profilesPath` is the directory containing Firefox profile directories and `profilePath` is the selected profile directory. Module users do not need to supply either; they are resolved from Home Manager.

## Notes

- Patches run after Home Manager `linkGeneration`.
- Generic JSON and INI patch paths may be relative to `$HOME` or absolute.
- Firefox extension patches follow Home Manager's configured Firefox/profile paths when used through the module.
- Patched files stay mutable rather than becoming read-only Nix store symlinks.
- JSON merging uses jq's `. * $patch`.
- INI patching preserves unspecified keys, removes keys set to `null`, and writes KDE KConfig key suffixes for `immutable` and `shellExpand`.
- Do not manage the same file with both `home.file` and these patch helpers.
- Firefox extension packages must contain an `.xpi` somewhere below the package path.
- To restart the Home Manager activation service for debugging, run `sudo systemctl restart "home-manager-$USER.service"`.
