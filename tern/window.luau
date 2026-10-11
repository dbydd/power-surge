-- power-surge, Tern half: sparks on every text change get a palette command, chords, and
-- Tern's own Files pane as the file browser.
--
-- The particles live in Neovim (`power-surge`), because that is where text changes happen.
-- This half drives them: each action types a `:lua` command into the focused Neovim pane,
-- so nothing else has to travel between the two.
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

-- Tern's own Files pane is the file browser. `files` toggles it; the chord gives Neovim
-- users the same muscle memory they have for <leader>e.
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
