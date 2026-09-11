{
  lib,
  glib,
  gobject-introspection,
  gtk4,
  gtk4-layer-shell,
  python3Packages,
  wrapGAppsHook4,
}:

python3Packages.buildPythonApplication {
  pname = "keyhint";
  version = "0.2.0";
  format = "other";

  src = ./src;

  nativeBuildInputs = [
    # Puts the typelibs belonging to buildInputs onto GI_TYPELIB_PATH, which is
    # the only dependable way for PyGObject to find them. Doing it by hand is
    # easy to get subtly wrong: pango keeps its typelibs in `out` while its
    # default output is `bin`, and cairo-1.0.typelib ships in
    # gobject-introspection rather than in cairo.
    gobject-introspection
    wrapGAppsHook4
  ];

  buildInputs = [
    glib
    gtk4
    gtk4-layer-shell
  ];

  propagatedBuildInputs = [ python3Packages.pygobject3 ];

  strictDeps = true;

  # The GApps wrapper would run before the Python one and be overwritten, so
  # the arguments it collected are passed to the Python wrapper instead. This
  # is the documented arrangement for a PyGObject application.
  dontWrapGApps = true;
  makeWrapperArgs = [
    "\${gappsWrapperArgs[@]}"

    # GTK4 layer-shell has to be loaded before libwayland-client, or it cannot
    # intercept surface creation and the window silently becomes an ordinary
    # toplevel rather than a layer surface. A compiled program satisfies that
    # by link order; a Python process importing the typelib at runtime cannot,
    # and LD_PRELOAD is the escape hatch upstream documents for this case.
    #
    # https://github.com/wmww/gtk4-layer-shell/blob/main/linking.md
    "--set"
    "LD_PRELOAD"
    "${gtk4-layer-shell}/lib/libgtk4-layer-shell.so"
  ];

  # hyprctl is resolved on PATH at runtime rather than pinned here: it speaks a
  # socket protocol to the compositor it shipped with, so the running
  # Hyprland's own copy is the right one to use, and pinning a second Hyprland
  # into the closure would be both large and wrong.
  installPhase = ''
    runHook preInstall

    install -Dm755 keyhint.py $out/bin/keyhint
    install -Dm644 keyhint.lua $out/share/keyhint/keyhint.lua

    runHook postInstall
  '';

  meta = {
    description = "Show the Hyprland binds reachable from the modifiers you are holding";
    longDescription = ''
      Hold a modifier and keyhint lists every bind reachable from it, with
      descriptions, on a layer-shell surface that never takes keyboard focus.
      Add another modifier and the list is replaced by that combination's
      binds; let go and it disappears.

      Modifier state is read from inside Hyprland's own Lua VM rather than from
      /dev/input, so keyhint needs no elevated privileges and no membership of
      the input group.
    '';
    homepage = "https://github.com/R3D2/keyhint";
    license = lib.licenses.mit;
    mainProgram = "keyhint";
    maintainers = [ ];
    platforms = lib.platforms.linux;
  };
}
