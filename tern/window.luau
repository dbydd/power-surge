-- power-surge, Tern half.
--
-- One job: while a combo is live in the Neovim pane, turn Tern's own cursor effects up, and
-- put them back the way the user had them when the combo dies.
--
-- The screen effect is Tern's, not ours: `cursor.trail` (what the cursor leaves when it moves)
-- and `cursor.pulse` (what a shape change sets off). Nothing is drawn, styled or titled here —
-- the combo only picks which of Tern's effects is playing, and at what volume.
--
-- Input comes from the Neovim half, which writes one small JSON per working directory
-- (`/tmp/power-surge/<sha>.json`): the combo, its level, and when it was last touched. This
-- half polls the file for the focused pane's directory and reacts to the level.
local STATE_DIR = "/tmp/power-surge"

--- What each combo level plays. Levels below the first row leave the user's own effects alone;
--- the last row is the ceiling, so a longer combo keeps the loudest pair rather than racing off
--- the end of either enum.
local LADDER = {
  [3] = { trail = "comet", pulse = "ripple" },
  [4] = { trail = "blaze", pulse = "box_ripple" },
  [5] = { trail = "sparks", pulse = "sonic_boom" },
  [6] = { trail = "sparks", pulse = "box_boom" },
}

--- macOS resolves /tmp through /private/tmp, and a pane's cwd may carry either spelling.
local function without_private(path)
  if path:sub(1, 9) == "/private/" then
    return path:sub(9)
  end
  return path
end

--- Tern shows the home directory as `~`, so compare a state file's absolute cwd in the same
--- form the tab uses.
local function display(path, home)
  if path == nil or path == "" then
    return nil
  end
  path = path:gsub("/+$", "")
  if home and home ~= "" and path:sub(1, #home) == home then
    local tail = path:sub(#home + 1)
    if tail == "" then
      return "~"
    end
    if tail:sub(1, 1) == "/" then
      return "~" .. tail
    end
  end
  return path
end

--- Where there is no room, Tern abbreviates every directory but the last to its first letter:
--- `/private/tmp` is shown as `/p/tmp`. A tab's cwd arrives either way, so both must match.
local function abbrev(path)
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts <= 1 then
    return path
  end
  local out = {}
  for i = 1, #parts - 1 do
    out[i] = string.sub(parts[i], 1, 1)
  end
  out[#parts] = parts[#parts]
  return "/" .. table.concat(out, "/")
end

--- Whether a state file belongs to `cwd`, in any of the spellings Tern may hand over.
local function matches(file, cwd)
  if file == nil or cwd == nil or cwd == "" then
    return false
  end
  local raw = file.cwd
  if raw == nil or raw == "" then
    return false
  end
  raw = raw:gsub("/+$", "")
  cwd = cwd:gsub("/+$", "")
  if raw == cwd or without_private(raw) == without_private(cwd) then
    return true
  end
  local shown = display(raw, file.home)
  for _, form in ipairs({ shown, abbrev(shown) }) do
    if form == cwd or without_private(form) == without_private(cwd) then
      return true
    end
  end
  return false
end

--- The state file for `cwd`, decoded, or nil.
local function state_for(cwd)
  if cwd == nil or cwd == "" or not tern.fs.exists(STATE_DIR) then
    return nil
  end
  for _, name in ipairs(tern.fs.list(STATE_DIR)) do
    if string.sub(name, -5) == ".json" then
      local ok, body = pcall(tern.fs.read, STATE_DIR .. "/" .. name, 4096)
      if ok and body then
        local decoded = tern.json.decode(body)
        if decoded and matches(decoded, cwd) then
          return decoded
        end
      end
    end
  end
  return nil
end

--- The focused tab's directory: it is the focused pane's cwd, and Tern reports it on the tab
--- (a pane's own `cwd` is the shell's, which is what we want, but only the tab is guaranteed).
local function focused_cwd(cx)
  local focus = cx.session:focused()
  for _, tab in ipairs(cx.session:tabs()) do
    if tab.pane == focus and tab.cwd and tab.cwd ~= "" then
      return tab.cwd
    end
  end
  return nil
end

-- The user's own effects, remembered in the plugin's key-value store: a crash mid-combo must
-- not leave the terminal louder than the user left it.
local BASE_KEY = "base_cursor"

local function current_cursor(cx)
  local ok, value = pcall(cx.settings.get, cx.settings, "cursor")
  if not ok or type(value) ~= "table" then
    return nil
  end
  return { trail = value.trail, pulse = value.pulse }
end

--- The user's baseline, from the store when it is there, else from the settings as they stand.
--- A stored baseline that differs from the live settings is a boost left behind by a crash, so
--- it wins and is put back.
local function baseline(cx)
  local live = current_cursor(cx)
  if live == nil then
    return nil
  end
  local stored = tern.kv.get(BASE_KEY)
  if type(stored) == "table" and stored.trail and stored.pulse then
    if stored.trail ~= live.trail or stored.pulse ~= live.pulse then
      tern.log.warn("restoring cursor effects left boosted: " .. stored.trail .. "/" .. stored.pulse)
      pcall(cx.settings.set, cx.settings, "cursor.trail", stored.trail)
      pcall(cx.settings.set, cx.settings, "cursor.pulse", stored.pulse)
    end
    return { trail = stored.trail, pulse = stored.pulse }
  end
  tern.kv.set(BASE_KEY, live)
  return live
end

local base = nil
local applied = nil -- the pair currently in effect, so a change costs one write per step

local function apply(cx, wanted)
  if wanted == nil then
    return
  end
  if applied and applied.trail == wanted.trail and applied.pulse == wanted.pulse then
    return
  end
  applied = { trail = wanted.trail, pulse = wanted.pulse }
  pcall(cx.settings.set, cx.settings, "cursor.trail", wanted.trail)
  pcall(cx.settings.set, cx.settings, "cursor.pulse", wanted.pulse)
end

local function level_pair(level)
  for i = math.min(level, 6), 3, -1 do
    if LADDER[i] then
      return LADDER[i]
    end
  end
  return nil
end

--- Reads the focused directory's state and sets the effects for its level.
--- The baseline is read once, from the first context that has settings; the timer's `cx` is
--- the one that arrives first when the window is already up (a reload).
local function ensure_base(cx)
  if base == nil and cx and cx.settings then
    base = baseline(cx)
    applied = nil
    apply(cx, base)
  end
end

local function look(cx)
  ensure_base(cx)
  local s = state_for(focused_cwd(cx))
  local level = s and tonumber(s.level) or 0
  if level > 0 then
    local pair = level_pair(level)
    if pair == nil then
      apply(cx, base)
      return
    end
    apply(cx, { trail = pair.trail, pulse = pair.pulse })
    return
  end
  apply(cx, base)
end

-- Polling: a state file is the only signal, so the effects come back to the user's own a beat
-- after the last keystroke. One small `read` per tick.
local POLL_MS = 400

local function tick(cx)
  look(cx)
  tern.timer(POLL_MS, tick)
end

tern.on("window_start", function(cx)
  ensure_base(cx)
  tern.timer(POLL_MS, tick)
end)

-- Armed when this module runs too: on a reload the window is already up, so `window_start` has
-- come and gone, and this is what starts the poll again.
tern.timer(POLL_MS, tick)

--- `focus` carries the event first and its `cx` second, unlike `window_start`.
tern.on("focus", function(_, cx)
  look(cx)
end)

--- Commands: the easter egg and the toggle, aimed at the focused pane running Neovim.
---
--- `pane.program` reports the shell, never the editor inside it, so a pane counts as
--- Neovim's when the Neovim half has published a state file for its directory.
local function focused_nvim(cx)
  local focused = cx.session:focused()
  if focused == nil then
    return nil
  end
  for _, pane in ipairs(cx.session:panes()) do
    if pane.pane == focused and state_for(pane.cwd) then
      return pane.pane
    end
  end
  return nil
end

local function run_in_nvim(cx, lua)
  local pane = focused_nvim(cx)
  if pane == nil then
    cx:toast("info", "Power Surge rides in Neovim", "Open a file with nvim, then try again")
    return false
  end
  cx:run(pane, ':lua require("power-surge").' .. lua .. "\r")
  return true
end

tern.command({
  id = "overdrive",
  title = "Power Surge: Overdrive",
  icon = "zap",
  group = "Power Surge",
  keys = { "ctrl+alt+shift+p" },
  available = function(cx)
    return focused_nvim(cx) ~= nil
  end,
  run = function(cx)
    run_in_nvim(cx, "overdrive()")
  end,
})

tern.command({
  id = "toggle",
  title = "Power Surge: Toggle",
  icon = "zap",
  group = "Power Surge",
  keys = { "ctrl+alt+shift+s" },
  available = function(cx)
    return focused_nvim(cx) ~= nil
  end,
  run = function(cx)
    run_in_nvim(cx, "toggle()")
  end,
})

tern.bind("ctrl+alt+shift+e", function(cx)
  run_in_nvim(cx, "overdrive()")
end)
