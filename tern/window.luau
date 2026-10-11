-- power-surge, Tern half.
--
-- Two jobs:
--
-- 1. The combo counter lives in Tern's chrome, not behind the caret: the tab's title
--    carries `⚡ 12 SPARK`, and a glow sheet pulses the whole window as the combo climbs.
--    Neovim publishes the combo to one small JSON per working directory
--    (`~/.cache/power-surge/<sha>.json`); this half polls the file for the focused tab's
--    cwd, because pane content is not a window API.
-- 2. The controls: palette commands and chords that drive the Neovim half.
-- A fixed path both halves can open: the Neovim half writes it, this half reads it.
local STATE_DIR = "/tmp/power-surge"
local POLL_MS = 200

local surge = { level = 0, combo = 0, name = "", at = 0 }

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

--- A state file matches a tab when their directories agree, either as absolute paths or
--- after the `~` shortening Tern uses in some places.
local function matches(file, tab_cwd)
  if file == nil or tab_cwd == nil or tab_cwd == "" then
    return false
  end
  local raw = file.cwd
  if raw == nil or raw == "" then
    return false
  end
  raw = raw:gsub("/+$", "")
  local cwd = tab_cwd:gsub("/+$", "")
  if raw == cwd then
    return true
  end
  return display(raw, file.home) == cwd
end

--- Read the state file for `cwd`; the file is the source of truth for the combo.
local function read_state(cwd)
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

--- The file is the whole truth: Neovim writes it on every change and writes `level = 0` when
--- the combo decays, so this half never has to guess staleness
--- (and the two processes do not share a clock).
local function refresh_state(cwd)
  local s = read_state(cwd)
  if s then
    surge = {
      level = tonumber(s.level) or 0,
      combo = tonumber(s.combo) or 0,
      name = tostring(s.name or ""),
      at = tonumber(s.at) or 0,
    }
  else
    surge = { level = 0, combo = 0, name = "", at = 0 }
  end
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

local applied_level = -1
local last_cwd = nil
local last_cwd = nil

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

--- The tab title, refreshed by the poll below.
tern.chrome.tab_title(function(tab)
  last_cwd = tab.cwd
  refresh_state(tab.cwd)
  apply_glow(surge.level)
  if surge.level <= 0 then
    return nil
  end
  local label = surge.name ~= "" and surge.name or "combo"
  if tab.name and tab.name ~= "" then
    return string.format("%s  ⚡%d", tab.name, surge.combo)
  end
  return string.format("%s  ⚡%d %s", tab.title, surge.combo, label)
end)

-- Polling. It always runs, slowly when nothing is happening: a formatter's answer is cached
-- per input, so a title that changed must be followed by `refresh` on its own.
local POLL_MS = 200 -- while a combo is live
local IDLE_MS = 1000 -- while the last one is fading
local SLEEP_TICKS = 60 -- ~a minute of nothing, then the loop stops until the next event
local live = false
local idle_ticks = 0
-- Upvalues the loop compares against; declared before it so the closure sees them.
local combo_seen, level_seen, name_seen = -1, -1, nil
local running = false

local function tick()
  refresh_state(last_cwd)
  local level = surge.level
  local changed = (combo_seen ~= surge.combo) or (level_seen ~= level) or (name_seen ~= surge.name)
  combo_seen, level_seen, name_seen = surge.combo, level, surge.name
  apply_glow(level)
  if changed then
    tern.chrome.refresh()
  end
  live = level > 0
  idle_ticks = live and 0 or (idle_ticks + 1)
  if idle_ticks > SLEEP_TICKS then
    running = false
    return
  end
  running = true
  tern.timer(live and POLL_MS or IDLE_MS, tick)
end

--- Called when something may have started a combo: restarts the loop if it slept.
local function wake()
  if running then
    return
  end
  running = true
  idle_ticks = 0
  tern.timer(60, tick)
end

--- Commands: the easter egg and the toggle, aimed at the focused Neovim pane.
local function focused_nvim(cx)
  local focused = cx.session:focused()
  if focused == nil then
    return nil
  end
  for _, pane in ipairs(cx.session:panes()) do
    if pane.pane == focused then
      local program = pane.program or ""
      if string.match(program, "neotern") or string.match(program, "nvim") then
        return pane.pane
      end
      return nil
    end
  end
  return nil
end

local function run_in_nvim(cx, lua)
  local pane = focused_nvim(cx)
  if pane == nil then
    cx:toast("info", "Power Surge rides in a Neovim pane", "Open neotern, then try again")
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
      wake()
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
    wake()
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
  if run_in_nvim(cx, "overdrive()") then
    wake()
  end
end)
