-- power-surge, Tern half: the easter egg gets a palette command, chords, and (when Tern
-- exposes it) the Files pane.
--
-- The particles live in Neovim (`power-surge`), because that is where text changes happen.
-- This half only drives it: every action types a `:lua` command into the focused Neovim
-- pane, so nothing else has to travel between the two.
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

tern.bind("ctrl+alt+shift+e", function(cx)
  run_in_nvim(cx, "overdrive()")
end)

-- Temporary: find out which built-in id toggles Tern's own Files pane.
tern.command({
  id = "probe",
  title = "Power Surge: Probe File Ids",
  icon = "zap",
  group = "Power Surge",
  run = function(cx)
    for _, id in ipairs({ "files_toggle", "toggle_files", "show_files", "files", "files:toggle", "open_files", "files_pane" }) do
      local ok, err = pcall(function()
        cx:command(id)
      end)
      if ok then
        cx:toast("success", "FOUND " .. id)
        return
      end
      cx:toast("error", id, tostring(err))
    end
  end,
})
