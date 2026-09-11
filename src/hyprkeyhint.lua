-- hyprkeyhint, compositor half.
--
-- Publishes the set of modifiers currently held to a file, which the overlay
-- reads to decide what to draw. Runs inside Hyprland's own Lua VM.
--
-- That placement is the point of the design. Reading modifier state from
-- outside the compositor means reading /dev/input, which means joining the
-- `input` group, which means every process running as that user can read every
-- keystroke on the machine -- passwords included. The compositor already has
-- the state, so this asks it instead. hyprkeyhint needs no privileges at all.
--
-- It sees raw key events and deliberately looks at nothing but whether the
-- eight modifier keys are down. No other keycode is read, stored or written.
--
-- Load it from a Lua config with:
--
--     require("hyprkeyhint")
--
-- or, with home-manager's Hyprland module:
--
--     wayland.windowManager.hyprland.extraLuaFiles.hyprkeyhint = ./hyprkeyhint.lua;

local STATE = os.getenv("HYPRKEYHINT_STATE")
  or ((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hyprkeyhint.mask")

-- The X11 modmask values, which are what Hyprland reports in `hyprctl binds`,
-- so the overlay can compare against them without translating. Verified
-- against a live compositor: SUPER is 64 and SUPER+SHIFT is 65.
local MODIFIERS = {
  { mask = 64, keysyms = { "Super_L", "Super_R" } },
  { mask = 8, keysyms = { "Alt_L", "Alt_R" } },
  { mask = 4, keysyms = { "Control_L", "Control_R" } },
  { mask = 1, keysyms = { "Shift_L", "Shift_R" } },
}

-- xkb keycodes, which are evdev codes plus 8. Only the modifiers appear here;
-- any other keycode is ignored outright.
local MODIFIER_KEYCODES = {
  [133] = "Super_L",
  [134] = "Super_R",
  [64] = "Alt_L",
  [108] = "Alt_R",
  [37] = "Control_L",
  [105] = "Control_R",
  [50] = "Shift_L",
  [62] = "Shift_R",
}

local KEY_PRESSED = 1

local published = nil

local function publish(mask)
  local file = io.open(STATE, "w")
  if file then
    file:write(tostring(mask))
    file:close()
  end
end

--- Mask of the modifiers held once the event being handled has been applied.
--
-- hl.is_key_down reports the state from *before* the current event, so the key
-- that triggered this callback has to be applied over the top by hand.
local function held_mask(keycode, state)
  local settling = MODIFIER_KEYCODES[keycode]
  local pressed = state == KEY_PRESSED
  local mask = 0

  for _, modifier in ipairs(MODIFIERS) do
    local down = false
    for _, keysym in ipairs(modifier.keysyms) do
      if keysym == settling then
        down = down or pressed
      else
        down = down or hl.is_key_down(keysym)
      end
    end
    if down then
      mask = mask + modifier.mask
    end
  end

  return mask
end

-- An error thrown inside this callback silently unsubscribes it, which looks
-- exactly like the feature having never worked. Nothing escapes.
local function on_key(keycode, _timestamp, state)
  local ok, mask = pcall(held_mask, keycode, state)
  if ok and mask ~= published then
    published = mask
    publish(mask)
  end
end

-- Re-requiring or reloading should not leave two subscriptions behind.
if HYPRKEYHINT_SUBSCRIPTION then
  pcall(function()
    HYPRKEYHINT_SUBSCRIPTION:remove()
  end)
end

HYPRKEYHINT_SUBSCRIPTION = hl.on("input.keyboard.key", on_key)

-- A file left behind by a previous session would have the overlay start up
-- believing something is held.
publish(0)

return {
  state_path = STATE,
}
