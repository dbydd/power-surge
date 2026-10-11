-- power-surge, Tern half.
--
-- Two jobs:
--
-- 1. The combo counter lives in Tern's chrome, not behind the caret: the tab's title carries
--    `⚡ 12 SPARK`, and a glow sheet pulses the whole window as the combo climbs. Neovim
--    publishes the combo to one small JSON per working directory (`/tmp/power-surge/<sha>.json`);
--    this half reads the file for the tab it is titling, because pane content is not a window API.
-- 2. The controls: palette commands and chords that drive the Neovim half.
--
-- The file is the whole rendezvous. A fixed path both halves can open without agreeing on
-- $HOME, and the file says everything: Neovim writes it on every change, writes `level = 0`
-- when the combo decays, and writes once more as it exits. So a file that says `level > 0`
-- means a live Neovim with a live combo, and no shared clock is needed to believe it.
local STATE_DIR = "/tmp/power-surge"

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

--- macOS resolves /tmp through /private/tmp, and a pane's cwd may carry either spelling.
local function without_private(path)
  if path:sub(1, 9) == "/private/" then
    return path:sub(9)
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

-- A glow over the whole window, one rule per level: the higher the combo, the tighter and
-- brighter the ring. Rewritten only when the level changes.
local GLOW = [[
.tn-stage::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  box-shadow: inset 0 0 %dpx %dpx var(--accent);
  opacity: %.2f;
}
]]

local applied_level = nil

local function apply_glow(level)
  if level == applied_level then
    return
  end
  applied_level = level
  if level <= 0 then
    tern.css("power-surge", "")
    return
  end
  tern.css("power-surge", string.format(GLOW, 12 * level, 3 * level, math.min(0.45, 0.08 * level)))
end

--- The tab title: reads the state file for the tab's own directory, so no tab can see another
--- tab's combo, and answers nil the moment the file says the combo is over. Pure, because Tern
--- caches a formatter's answer against its input: nothing set here reaches the poll.
tern.chrome.tab_title(function(tab)
  local s = state_for(tab.cwd)
  local level = s and tonumber(s.level) or 0
  if level <= 0 then
    return nil
  end
  local combo = tonumber(s.combo) or 0
  local name = tostring(s.name or "")
  local label = name ~= "" and name or "combo"
  local out
  if tab.name and tab.name ~= "" then
    out = string.format("%s  ⚡%d", tab.name, combo)
  else
    out = string.format("%s  ⚡%d %s", tab.title, combo, label)
  end
  return out
end)

-- Polling. A formatter's answer is cached per input, and the input (the tab) does not change
-- when the combo does, so a changed answer has to be followed by `chrome.refresh` on its own.
-- The cost is one small `read` per tick for the focused directory.
local POLL_MS = 500
local seen_level, seen_combo, seen_name = nil, nil, nil

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

--- Reads the focused directory's state and redraws the chrome when the answer moved.
local function look(cx)
  local s = state_for(focused_cwd(cx))
  local level = s and tonumber(s.level) or 0
  local combo = s and tonumber(s.combo) or 0
  local name = s and tostring(s.name or "") or ""
  if level == seen_level and combo == seen_combo and name == seen_name then
    return
  end
  seen_level, seen_combo, seen_name = level, combo, name
  apply_glow(level)
  tern.chrome.refresh()
end

local function tick(cx)
  look(cx)
  tern.timer(POLL_MS, tick)
end

tern.on("focus", function()
  tern.chrome.refresh()
end)

-- Armed when this module runs: on window start and again after a plugin reload, which is the
-- only way this half is restarted. A reload drops the old load's timers, so there is exactly
-- one chain, and it re-arms itself from here on.
tern.timer(POLL_MS, tick)


--- Commands: the easter egg and the toggle, aimed at the focused pane.
---
--- `pane.program` reports the shell, never the editor running inside it, so a pane counts as
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
    if run_in_nvim(cx, "overdrive()") then
      cx:toast("info", "⚡ OVERDRIVE")
    end
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

tern.command({
  id = "files",
  title = "Toggle Files Pane",
  icon = "folder",
  group = "Power Surge",
  keys = { "ctrl+alt+shift+f" },
  run = function(cx)
    cx:command("files")
  end,
})

tern.bind("ctrl+alt+shift+e", function(cx)
  run_in_nvim(cx, "overdrive()")
end)
