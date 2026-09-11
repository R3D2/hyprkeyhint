{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hyprkeyhint;
  hyprland = config.wayland.windowManager.hyprland;
in
{
  options.services.hyprkeyhint = {
    enable = lib.mkEnableOption "hyprkeyhint, a keybind sheet for the modifiers being held";

    package = lib.mkPackageOption pkgs "hyprkeyhint" { };

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

    fold = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fold runs of near-identical binds into one row, so ten workspace binds
        read as `1…0  Workspace 1-10` and four direction binds as one line of
        arrows. A run is only folded at three members or more.

        The cost is that the exact mapping stops being spelled out: the folded
        row implies that `0` is workspace 10 rather than saying so. Turn it off
        for the unabridged list.
      '';
    };

    opacity = lib.mkOption {
      type = lib.types.numbers.between 0.0 1.0;
      default = 1.0;
      example = 0.9;
      description = ''
        Opacity of the whole sheet, background, border and text together.
        Below about 0.8 the descriptions start competing with whatever is
        behind them, which defeats the purpose.
      '';
    };

    style = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        .hyprkeyhint-sheet { background: #1c1c2c; border-color: #78a0e0; }
      '';
      description = ''
        CSS appended to the built-in stylesheet. The classes are
        `hyprkeyhint-sheet`, `hyprkeyhint-title`, `hyprkeyhint-key`, `hyprkeyhint-description`
        and `hyprkeyhint-empty`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--poll=100" ];
      description = "Extra arguments appended to the hyprkeyhint command line.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hyprland.enable -> hyprland.configType == "lua";
        message = ''
          services.hyprkeyhint requires the Lua config provider. Set
          wayland.windowManager.hyprland.configType = "lua", or load
          hyprkeyhint.lua yourself and leave the Hyprland module alone.
        '';
      }
    ];

    warnings = lib.optional (!hyprland.enable) ''
      services.hyprkeyhint is enabled but wayland.windowManager.hyprland is not, so
      nothing loads hyprkeyhint.lua and the sheet will never appear. Add

          require("hyprkeyhint")

      to your Hyprland Lua config, having copied it from
      ${cfg.package}/share/hyprkeyhint/hyprkeyhint.lua.
    '';

    home.packages = [ cfg.package ];

    # The compositor half. It is taken from this flake's source rather than
    # from the package because extraLuaFiles distinguishes a path from literal
    # Lua text, and a store path built into a string reads as the latter.
    wayland.windowManager.hyprland.extraLuaFiles = lib.mkIf hyprland.enable {
      hyprkeyhint = ../src/hyprkeyhint.lua;
    };

    xdg.configFile."hyprkeyhint/style.css" = lib.mkIf (cfg.style != "") { text = cfg.style; };

    systemd.user.services.hyprkeyhint = {
      Unit = {
        Description = "Keybind sheet for the modifiers being held";
        Documentation = "https://github.com/R3D2/hyprkeyhint";
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
            "--opacity=${toString cfg.opacity}"
            (if cfg.fold then "--fold" else "--no-fold")
          ]
          ++ lib.optional (cfg.style != "") "--style=${config.xdg.configHome}/hyprkeyhint/style.css"
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
        Slice = "session.slice";
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
