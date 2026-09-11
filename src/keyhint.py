#!/usr/bin/env python3
"""Show the Hyprland binds reachable from the modifiers currently held.

Reads the modifier mask published by keyhint.lua and draws the binds that
match it on a layer-shell surface. The surface never takes keyboard focus, so
the binds it describes keep working while it is on screen.

The bind list comes from `hyprctl binds -j`. Binds without a description are
skipped, so annotate them with `description` (Lua) or use `bindd` (conf).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from math import ceil

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")

from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402
from gi.repository import Gtk4LayerShell as LayerShell  # noqa: E402

# Hyprland reports modmasks using the X11 values, and keyhint.lua publishes the
# same, so no translation is needed anywhere.
MODIFIERS = {
    "shift": 1,
    "ctrl": 4,
    "alt": 8,
    "super": 64,
}

# Most significant first, which is the order they are said out loud.
MODIFIER_ORDER = ("super", "ctrl", "alt", "shift")

# Ordered as they read rather than as they sort, so a folded run of arrows
# comes out as the cluster on the keyboard.
DIRECTIONS = ("left", "up", "down", "right")
ARROWS = {"left": "←", "up": "↑", "down": "↓", "right": "→"}

# Keys whose names are too long or too cryptic to read at a glance.
KEY_LABELS = {
    "mouse:272": "Drag",
    "mouse:273": "Right-drag",
    "mouse_up": "Wheel up",
    "mouse_down": "Wheel down",
    "XF86AudioRaiseVolume": "Vol +",
    "XF86AudioLowerVolume": "Vol -",
    "XF86AudioMute": "Mute",
    "XF86AudioMicMute": "Mic mute",
    "XF86MonBrightnessUp": "Bright +",
    "XF86MonBrightnessDown": "Bright -",
    "XF86AudioNext": "Next",
    "XF86AudioPrev": "Prev",
    "XF86AudioPlay": "Play",
    "XF86AudioPause": "Pause",
}

DEFAULT_CSS = """
window.keyhint {
  background: transparent;
}

.keyhint-sheet {
  background: #cccccc;
  border: 1px solid #000000;
  padding: 14px 18px;
}

.keyhint-title {
  color: #000000;
  font-size: 12px;
  padding-bottom: 10px;
}

.keyhint-key {
  background: #ffffff;
  border: 1px solid #000000;
  color: #000000;
  font-family: monospace;
  font-size: 12px;
  margin: 2px 10px 2px 0;
  padding: 1px 7px;
}

.keyhint-description {
  color: #000000;
  font-size: 12px;
  margin-right: 26px;
}

.keyhint-footer {
  color: #4a4a4a;
  font-size: 11px;
  padding-top: 12px;
}

.keyhint-empty {
  color: #4a4a4a;
  font-size: 12px;
}
"""


def default_state_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "keyhint.mask")


@dataclass(frozen=True)
class Bind:
    key: str
    description: str

    @property
    def label(self) -> str:
        return KEY_LABELS.get(self.key, self.key)

    @property
    def sort_key(self) -> tuple[int, int, str]:
        """Digits in numeric order first, then everything else alphabetically."""
        if len(self.key) == 1 and self.key.isdigit():
            # 0 is usually workspace 10, so it belongs at the end of the run of
            # digits rather than the start -- which is also where it sits on the
            # keyboard.
            return (0, 10 if self.key == "0" else int(self.key), "")
        return (1, 0, self.key.lower())


def describe_mask(mask: int) -> str:
    return " + ".join(
        name.capitalize() for name in MODIFIER_ORDER if mask & MODIFIERS[name]
    )


def fetch_binds() -> list[dict]:
    """Ask the running compositor what is bound.

    hyprctl is deliberately taken from PATH rather than pinned at build time:
    it talks a socket protocol to the compositor it shipped with, so the
    running Hyprland's own copy is the correct one.
    """
    if shutil.which("hyprctl") is None:
        print("keyhint: hyprctl not found on PATH", file=sys.stderr)
        return []
    try:
        completed = subprocess.run(
            ["hyprctl", "binds", "-j"],
            capture_output=True,
            check=True,
            text=True,
            timeout=2,
        )
        return json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"keyhint: could not read binds: {error}", file=sys.stderr)
        return []


def binds_for(mask: int, raw: list[dict]) -> list[Bind]:
    """Binds on exactly this combination, so Super alone omits Super+Shift."""
    binds = [
        Bind(key=entry["key"], description=entry["description"])
        for entry in raw
        if entry.get("modmask") == mask
        and entry.get("description")
        and not entry.get("submap")
    ]
    binds.sort(key=lambda bind: bind.sort_key)
    return binds


@dataclass(frozen=True)
class Row:
    """One printed line: either a bind, or a run of them folded together."""

    keys: str
    description: str
    sort: tuple[int, int, str]


def split_variant(description: str) -> tuple[str, str, object] | None:
    """Split a description into a stem and the thing that varies across a run.

    "Workspace 7" is one of ten lines that say the same thing, and so is
    "Move window left". Both are worth one line, not four or ten.
    """
    words = description.split()
    if len(words) < 2:
        return None
    last = words[-1].lower()
    if last.isdigit():
        return (" ".join(words[:-1]), "number", int(last))
    if last in DIRECTIONS:
        return (" ".join(words[:-1]), "direction", last)
    return None


def fold_runs(binds: list[Bind], minimum: int = 3) -> list[Row]:
    """Fold runs of near-identical binds into a single row.

    A third of the Super sheet was "Workspace 1" through "Workspace 10", and
    more than half of Super+Shift was "Send window to workspace N". Reading the
    same sentence ten times teaches nothing the first one did not.

    Below `minimum` members a run is left alone: folding a pair hides as much
    as it saves.
    """
    groups: dict[tuple[str, str], list[tuple[object, Bind]]] = {}
    rows: list[Row] = []

    for bind in binds:
        parsed = split_variant(bind.description)
        if parsed is None:
            rows.append(Row(bind.label, bind.description, bind.sort_key))
            continue
        stem, kind, variant = parsed
        groups.setdefault((stem, kind), []).append((variant, bind))

    for (stem, kind), members in groups.items():
        if len(members) < minimum:
            rows.extend(
                Row(bind.label, bind.description, bind.sort_key) for _, bind in members
            )
            continue

        sort = min(bind.sort_key for _, bind in members)
        if kind == "number":
            members.sort(key=lambda member: member[0])
            first, last = members[0], members[-1]
            keys = f"{first[1].label}…{last[1].label}"
            description = f"{stem} {first[0]}-{last[0]}"
        else:
            members.sort(key=lambda member: DIRECTIONS.index(member[0]))
            keys = "".join(ARROWS[variant] for variant, _ in members)
            description = stem
        rows.append(Row(keys, description, sort))

    rows.sort(key=lambda row: row.sort)
    return rows


def deeper_masks(mask: int, raw: list[dict]) -> dict[int, int]:
    """Modifier combinations that add to this one, and how many binds each holds.

    Without this the second layer is undiscoverable: holding Super says nothing
    about there being eighteen more binds a Shift away.
    """
    counts: dict[int, int] = {}
    for entry in raw:
        other = entry.get("modmask")
        if other is None or other == mask:
            continue
        if not entry.get("description") or entry.get("submap"):
            continue
        if other & mask == mask:
            counts[other] = counts.get(other, 0) + 1
    return counts


def describe_deeper(mask: int, counts: dict[int, int]) -> str:
    return "   ".join(
        f"+ {describe_mask(other & ~mask)} · {count} more"
        for other, count in sorted(counts.items())
    )


class Keyhint(Gtk.Application):
    def __init__(self, options: argparse.Namespace) -> None:
        super().__init__(
            application_id="io.github.r3d2.keyhint",
            flags=Gio.ApplicationFlags.NON_UNIQUE,
        )
        self.options = options
        self.gate = MODIFIERS[options.gate]
        self.window: Gtk.ApplicationWindow | None = None
        self.grid: Gtk.Grid | None = None
        self.title: Gtk.Label | None = None
        self.footer: Gtk.Label | None = None
        self.monitor: Gio.FileMonitor | None = None
        self.mask = 0
        self.shown_mask: int | None = None
        self.pending: int | None = None
        self.cached_binds: list[dict] | None = None

    # -- setup ---------------------------------------------------------------

    def do_activate(self) -> None:
        self.load_css()
        self.build_window()
        self.watch_state()
        # The window is held open for the lifetime of the process; without this
        # the application would quit as soon as the sheet is first hidden.
        self.hold()

    def load_css(self) -> None:
        css = DEFAULT_CSS
        if self.options.style:
            try:
                with open(self.options.style, encoding="utf-8") as handle:
                    css += handle.read()
            except OSError as error:
                print(f"keyhint: could not read style: {error}", file=sys.stderr)

        provider = Gtk.CssProvider()
        # load_from_string arrived in GTK 4.12; load_from_data is the older
        # spelling and takes bytes.
        if hasattr(provider, "load_from_string"):
            provider.load_from_string(css)
        else:
            provider.load_from_data(css.encode("utf-8"))

        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def build_window(self) -> None:
        self.window = Gtk.ApplicationWindow(application=self)
        self.window.add_css_class("keyhint")

        LayerShell.init_for_window(self.window)
        LayerShell.set_layer(self.window, LayerShell.Layer.OVERLAY)
        LayerShell.set_namespace(self.window, "keyhint")
        # NONE means the surface never takes the keyboard. The whole point is
        # that the binds being described stay usable while it is up.
        LayerShell.set_keyboard_mode(self.window, LayerShell.KeyboardMode.NONE)

        if self.options.anchor != "center":
            edge = {
                "top": LayerShell.Edge.TOP,
                "bottom": LayerShell.Edge.BOTTOM,
            }[self.options.anchor]
            LayerShell.set_anchor(self.window, edge, True)
            LayerShell.set_margin(self.window, edge, self.options.margin)

        sheet = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sheet.add_css_class("keyhint-sheet")
        # Applied to the sheet rather than to the window, and as a widget
        # property rather than as CSS: it then covers the background, the
        # border and the text in one go, and survives a stylesheet that
        # replaces the background colour outright.
        sheet.set_opacity(self.options.opacity)

        self.title = Gtk.Label(xalign=0)
        self.title.add_css_class("keyhint-title")
        sheet.append(self.title)

        self.grid = Gtk.Grid()
        sheet.append(self.grid)

        self.footer = Gtk.Label(xalign=0)
        self.footer.add_css_class("keyhint-footer")
        sheet.append(self.footer)

        self.window.set_child(sheet)

    def watch_state(self) -> None:
        state = Gio.File.new_for_path(self.options.state)
        self.monitor = state.monitor_file(Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", lambda *_: self.poll())
        # A backstop for the cases a file monitor is allowed to miss: the file
        # being created after this point, or events coalescing under load. A
        # missed change would otherwise strand the sheet on screen.
        GLib.timeout_add(self.options.poll, self.on_timeout)

    # -- state ---------------------------------------------------------------

    def read_mask(self) -> int:
        try:
            with open(self.options.state, encoding="utf-8") as handle:
                return int(handle.read().strip() or 0)
        except (OSError, ValueError):
            return 0

    def on_timeout(self) -> bool:
        self.poll()
        return GLib.SOURCE_CONTINUE

    def poll(self) -> None:
        mask = self.read_mask()
        if mask != self.mask:
            self.mask = mask
            self.on_mask_changed(mask)

    def on_mask_changed(self, mask: int) -> None:
        # The gate keeps the sheet off the screen for modifiers used in
        # ordinary typing: Shift for a capital letter, Alt for a menu.
        if not mask & self.gate:
            self.cancel_pending()
            self.hide_sheet()
            return

        if self.shown_mask is not None:
            # Already up, so a modifier was added or dropped. Repaint at once:
            # waiting out the delay again is what makes a which-key feel slow.
            self.render(mask)
            return

        self.cancel_pending()
        self.pending = GLib.timeout_add(self.options.delay, self.on_delay_elapsed, mask)

    def cancel_pending(self) -> None:
        if self.pending is not None:
            GLib.source_remove(self.pending)
            self.pending = None

    def on_delay_elapsed(self, mask: int) -> bool:
        self.pending = None
        if self.mask == mask:
            self.render(mask)
        return GLib.SOURCE_REMOVE

    # -- drawing -------------------------------------------------------------

    def hide_sheet(self) -> None:
        if self.shown_mask is not None:
            self.window.set_visible(False)
            self.shown_mask = None
        # Dropped so the next hold picks up binds added since, by a reload or
        # by hyprctl.
        self.cached_binds = None

    def render(self, mask: int) -> None:
        if self.cached_binds is None:
            self.cached_binds = fetch_binds()

        self.clear_grid()
        self.title.set_text(describe_mask(mask))

        binds = binds_for(mask, self.cached_binds)
        entries = (
            fold_runs(binds)
            if self.options.fold
            else [Row(bind.label, bind.description, bind.sort_key) for bind in binds]
        )
        if not entries:
            label = Gtk.Label(label="nothing bound", xalign=0)
            label.add_css_class("keyhint-empty")
            self.grid.attach(label, 0, 0, 2, 1)
        else:
            # --rows is a maximum, not a target: with 18 entries and a maximum
            # of 13 a fixed split leaves 13 beside 5, so the columns are
            # levelled once the number of them is known.
            columns = ceil(len(entries) / self.options.rows)
            per_column = ceil(len(entries) / columns)
            for index, entry in enumerate(entries):
                column, row = divmod(index, per_column)
                key = Gtk.Label(label=entry.keys, xalign=0.5)
                key.add_css_class("keyhint-key")
                description = Gtk.Label(label=entry.description, xalign=0)
                description.add_css_class("keyhint-description")
                self.grid.attach(key, column * 2, row, 1, 1)
                self.grid.attach(description, column * 2 + 1, row, 1, 1)

        deeper = describe_deeper(mask, deeper_masks(mask, self.cached_binds))
        self.footer.set_text(deeper)
        self.footer.set_visible(bool(deeper))

        self.shown_mask = mask
        self.window.set_visible(True)

    def clear_grid(self) -> None:
        child = self.grid.get_first_child()
        while child is not None:
            following = child.get_next_sibling()
            self.grid.remove(child)
            child = following


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="keyhint",
        description="Show the Hyprland binds reachable from the modifiers held.",
    )
    parser.add_argument(
        "--gate",
        choices=sorted(MODIFIERS),
        default="super",
        help="modifier that must be held for the sheet to appear (default: super)",
    )
    parser.add_argument(
        "--delay",
        type=int,
        default=200,
        metavar="MS",
        help="hold this long before the sheet appears (default: 200)",
    )
    parser.add_argument(
        "--poll",
        type=int,
        default=250,
        metavar="MS",
        help="backstop poll interval for the state file (default: 250)",
    )
    parser.add_argument(
        "--rows",
        type=int,
        default=13,
        help="rows per column before wrapping (default: 13)",
    )
    parser.add_argument(
        "--anchor",
        choices=("center", "top", "bottom"),
        default="center",
        help="where the sheet sits (default: center)",
    )
    parser.add_argument(
        "--margin",
        type=int,
        default=48,
        metavar="PX",
        help="gap from the anchored edge, ignored when centred (default: 48)",
    )
    parser.add_argument(
        "--fold",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "fold runs of near-identical binds into one row, so ten workspace "
            "binds read as one (default: fold)"
        ),
    )
    parser.add_argument(
        "--opacity",
        type=float,
        default=1.0,
        metavar="ALPHA",
        help="opacity of the sheet, 0.0 to 1.0 (default: 1.0)",
    )
    parser.add_argument(
        "--state",
        default=default_state_path(),
        metavar="PATH",
        help="file keyhint.lua publishes the modifier mask to",
    )
    parser.add_argument(
        "--style",
        metavar="PATH",
        help="CSS file appended to the built-in stylesheet",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if argv is None else argv)
    if options.delay < 0 or options.poll <= 0 or options.rows <= 0:
        print("keyhint: delay, poll and rows must be positive", file=sys.stderr)
        return 2
    if not 0.0 <= options.opacity <= 1.0:
        print("keyhint: opacity must be between 0.0 and 1.0", file=sys.stderr)
        return 2
    return Keyhint(options).run(None)


if __name__ == "__main__":
    sys.exit(main())
