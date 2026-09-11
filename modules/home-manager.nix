{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.keyhint;
  hyprland = config.wayland.windowManager.hyprland;
in
{
  options.services.keyhint = {
    enable = lib.mkEnableOption "keyhint, a keybind sheet for the modifiers being held";

    package = lib.mkPackageOption pkgs "keyhint" { };

    gate = lib.mkOption {
      type = lib.types.enum [
        "super"
        "ctrl"
        "alt"
        "shift"
      ];
      default = "super";
      description = ''
        Modifier that must be held for the sheet to appear at all. Anything
        used in ordinary typing makes a poor gate: shift is a capital letter
        and alt is a menu.
      '';
    };

    delay = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 200;
      example = 400;
      description = ''
        Milliseconds the gate must be held before the sheet appears. A
        deliberate chord finishes well inside this, so the common case never
        sees a flash.
      '';
    };

    rowsPerColumn = lib.mkOption {
      type = lib.types.ints.positive;
      default = 13;
      description = "Binds listed down a column before wrapping into the next.";
    };

    anchor = lib.mkOption {
      type = lib.types.enum [
        "center"
        "top"
        "bottom"
      ];
      default = "center";
      description = ''
        Where the sheet sits. An edge is worth considering if the gate is also
        held for dragging windows, since a centred sheet lands on top of what
        is being dragged.
      '';
    };

    margin = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 48;
      description = "Gap in pixels from the anchored edge. Ignored when centred.";
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        .keyhint-sheet { background: #1c1c2c; border-color: #78a0e0; }
      '';
      description = ''
        CSS appended to the built-in stylesheet. The classes are
        `keyhint-sheet`, `keyhint-title`, `keyhint-key`, `keyhint-description`
        and `keyhint-empty`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--poll=100" ];
      description = "Extra arguments appended to the keyhint command line.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hyprland.enable -> hyprland.configType == "lua";
        message = ''
          services.keyhint requires the Lua config provider. Set
          wayland.windowManager.hyprland.configType = "lua", or load
          keyhint.lua yourself and leave the Hyprland module alone.
        '';
      }
    ];

    warnings = lib.optional (!hyprland.enable) ''
      services.keyhint is enabled but wayland.windowManager.hyprland is not, so
      nothing loads keyhint.lua and the sheet will never appear. Add

          require("keyhint")

      to your Hyprland Lua config, having copied it from
      ${cfg.package}/share/keyhint/keyhint.lua.
    '';

    home.packages = [ cfg.package ];

    # The compositor half. It is taken from this flake's source rather than
    # from the package because extraLuaFiles distinguishes a path from literal
    # Lua text, and a store path built into a string reads as the latter.
    wayland.windowManager.hyprland.extraLuaFiles = lib.mkIf hyprland.enable {
      keyhint = ../src/keyhint.lua;
    };

    xdg.configFile."keyhint/style.css" = lib.mkIf (cfg.style != "") { text = cfg.style; };

    systemd.user.services.keyhint = {
      Unit = {
        Description = "Keybind sheet for the modifiers being held";
        Documentation = "https://github.com/R3D2/keyhint";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };

      Service = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "--gate=${cfg.gate}"
            "--delay=${toString cfg.delay}"
            "--rows=${toString cfg.rowsPerColumn}"
            "--anchor=${cfg.anchor}"
            "--margin=${toString cfg.margin}"
          ]
          ++ lib.optional (cfg.style != "") "--style=${config.xdg.configHome}/keyhint/style.css"
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
        Slice = "session.slice";
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
