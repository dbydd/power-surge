-- power-surge: a combo meter that never gets between you and the text.
--
-- The counter is a small floating window in a corner: nothing is drawn in the buffer, the
-- cursor is untouched, the viewport never moves. The screen effects are Tern's own (its
-- `cursor.trail` and `cursor.pulse`), driven by the Tern half of this plugin from the state
-- file written here — so this half stays a plain Neovim plugin.
local M = {}

local defaults = {
  enabled = true,
  combo = {
    window_ms = 600, -- a longer gap than this starts a new combo
    step = 5, -- changes per level
    max_level = 6,
    decay_ms = 1200, -- idle time before the meter falls back to zero
  },
  counter = {
    enabled = true,
    -- The float, in the spirit of power-mode's combo box: rounded border, a bar that drains
    -- as the combo nears its decay, four corners to pick from.
    position = "bottom-right", -- top-right | top-left | bottom-right | bottom-left
    width = 20,
    height = 3,
    linger_s = 2, -- the box stays this long after the combo dies, then hides
    render = nil, -- function(combo, level, name, bar) -> { string }; replaces the default box
    tern = true, -- publish the combo for the Tern half (tern/window.luau reads it)
    -- A rendezvous both processes can open without agreeing on $HOME: one small JSON per cwd.
    tern_dir = "/tmp/power-surge",
    tern_interval_ms = 120, -- how often the state file is rewritten while typing
  },
  overdrive = {
    word = "surge", -- typed in insert mode, this word fires the easter egg
  },
  exclude_buftypes = { "prompt", "nofile", "quickfix", "terminal", "help" },
  exclude_filetypes = {
    "TelescopePrompt",
    "checkhealth",
    "lazy",
    "mason",
    "noice",
    "qf",
    "snacks_input",
    "snacks_picker_input",
  },
}

--- One row per combo level: the name the meter shows as the combo climbs.
local TIERS = {
  { name = "" },
  { name = "" },
  { name = "SPARK" },
  { name = "SURGE" },
  { name = "OVERDRIVE" },
  { name = "UNSTOPPABLE" },
}

local HL = "PowerSurgeCounter"

local state = {
  cfg = defaults,
  decay = nil, -- timer that retires an idle combo
  published = nil, -- when the Tern state file was last written
  tern_dir_made = false,
  combo = 0,
  level = 0,
  last_ms = 0,
  typed = "",
  hidden = true, -- the float's visibility; the window and buffer stay for the next combo
  hide_timer = nil,
  buf = nil,
  win = nil,
  base_row = 1,
  base_col = 0,
  last_render = nil, -- the drawn text, so an unchanged frame costs no buffer write
  wired = false,
}

local uv = vim.uv or vim.loop

local function now()
  return uv.now()
end

local function reconfigure(opts)
  state.cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function level_of(combo)
  local cfg = state.cfg.combo
  local level = math.floor(combo / math.max(1, cfg.step)) + 1
  return math.max(1, math.min(cfg.max_level, level))
end

local function tier(level)
  return TIERS[math.min(#TIERS, math.max(1, level))]
end

local function excluded(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return true
  end
  local bo = vim.bo[buf]
  return vim.tbl_contains(state.cfg.exclude_buftypes, bo.buftype)
    or vim.tbl_contains(state.cfg.exclude_filetypes, bo.filetype)
end

local function label()
  local t = tier(state.level)
  return ("⚡%d%s"):format(state.combo, t.name ~= "" and (" " .. t.name) or "")
end

--- Close the counter float but keep the buffer, so the next keystroke reopens it instantly.
local function close_counter()
  if state.hide_timer then
    state.hide_timer:stop()
    state.hide_timer = nil
  end
  state.hidden = true
  state.last_render = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

--- Where the float sits, power-mode style: a corner of the editor, clear of the statusline.
local function compute_position(cfg)
  local w, h = cfg.width, cfg.height
  local row, col
  if cfg.position == "top-right" then
    row, col = 1, vim.o.columns - w - 2
  elseif cfg.position == "top-left" then
    row, col = 1, 2
  elseif cfg.position == "bottom-left" then
    row, col = vim.o.lines - h - 3, 2
  else
    row, col = vim.o.lines - h - 3, vim.o.columns - w - 2
  end
  return math.max(0, row), math.max(0, col)
end

--- Draw the counter float, power-mode's combo box: a rounded box that opens on the first
--- keystroke, shows the streak and the decay bar, and lingers a moment after the combo dies.
--- Never focusable, never entering the buffer, never touching the cursor or the viewport.
local function show_counter()
  local cfg = state.cfg.counter
  if not cfg.enabled then
    close_counter()
    return
  end
  if state.hide_timer then
    state.hide_timer:stop()
    state.hide_timer = nil
  end
  state.hidden = false

  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = vim.api.nvim_create_buf(false, true)
  end

  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    state.base_row, state.base_col = compute_position(cfg)
    local ok, win = pcall(vim.api.nvim_open_win, state.buf, false, {
      relative = "editor",
      row = state.base_row,
      col = state.base_col,
      width = cfg.width,
      height = cfg.height,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
      zindex = 100,
    })
    if not ok then
      return
    end
    state.win = win
    state.last_render = nil
    vim.wo[state.win].winhighlight = "Normal:PowerSurgeCounter,NormalFloat:PowerSurgeCounter,FloatBorder:PowerSurgeCounter"
  end

  -- The decay bar: how much of the combo window is left before the meter falls to zero.
  local cfg_combo = state.cfg.combo
  local left = math.max(0, cfg_combo.decay_ms - (now() - state.last_ms))
  local bar_width = math.max(1, cfg.width - 4)
  local filled = math.floor(math.min(1, left / cfg_combo.decay_ms) * bar_width)
  local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
  local name = tier(state.level).name
  local lines = cfg.render
      and cfg.render(state.combo, state.level, name, bar)
    or { ("⚡ %d %s"):format(state.combo, name), "  " .. bar }

  local opts = {
    relative = "editor",
    row = state.base_row,
    col = state.base_col,
    width = cfg.width,
    height = cfg.height,
  }
  pcall(vim.api.nvim_win_set_config, state.win, opts)

  local text = table.concat(lines, "\n")
  if text ~= state.last_render then
    state.last_render = text
    vim.bo[state.buf].modifiable = true
    local padded = {}
    for i = 1, cfg.height do
      padded[i] = lines[i] or ""
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, padded)
    vim.bo[state.buf].modifiable = false
  end
end

--- Publish the combo to Tern, which plays its own cursor effects for it. The write is
--- throttled: one small file, a few times a second while typing.
local function publish(force)
  local cfg = state.cfg.counter
  if not cfg.tern then
    return
  end
  local t = now()
  if not force and t - (state.published or 0) < cfg.tern_interval_ms then
    return
  end
  state.published = t
  local dir = cfg.tern_dir
  if not state.tern_dir_made then
    state.tern_dir_made = true
    pcall(vim.fn.mkdir, dir, "p")
  end
  -- One file per working directory: the Tern half matches it to the focused pane's cwd.
  local slug = vim.fn.sha256(vim.fn.getcwd()):sub(1, 16)
  local path = dir .. "/" .. slug .. ".json"
  local payload = vim.json.encode({
    cwd = vim.fn.getcwd(),
    home = vim.env.HOME, -- Tern shows the home directory as `~`; it needs the prefix to match
    combo = state.combo,
    level = state.level,
    name = tier(state.level).name,
    at = t,
  })
  pcall(vim.fn.writefile, { payload }, path)
end

--- The last word, so a closed editor cannot leave a live combo on Tern's screen: the file is
--- the Tern half's only signal, and it outlives the process that wrote it.
local function publish_dead()
  state.combo = 0
  state.level = 0
  publish(true)
end

--- Retire the combo after `decay_ms` of silence: the float leaves and Tern's effects go back
--- to the user's own, without waiting for the next keystroke.
local function arm_decay()
  if state.decay then
    state.decay:stop()
  end
  local cfg = state.cfg.combo
  state.decay = uv.new_timer()
  state.decay:start(cfg.decay_ms + 50, 0, function()
    vim.schedule(function()
      state.decay = nil
      if not state.cfg.enabled or state.level == 0 then
        return
      end
      if now() - state.last_ms >= cfg.decay_ms then
        state.combo = 0
        state.level = 0
        publish(true)
        -- The box lingers a moment, power-mode's disappear delay, then hides itself. A new
        -- keystroke cancels this from `show_counter`.
        local linger = (state.cfg.counter.linger_s or 0) * 1000
        if linger <= 0 then
          close_counter()
        elseif not state.hide_timer then
          state.hide_timer = uv.new_timer()
          state.hide_timer:start(linger, 0, function()
            vim.schedule(close_counter)
          end)
        end
      end
    end)
  end)
end

--- The easter egg: max level for one burst, in the float and in Tern's effects.
function M.overdrive()
  local buf = vim.api.nvim_get_current_buf()
  if excluded(buf) then
    return false
  end
  state.level = state.cfg.combo.max_level
  state.combo = math.max(state.combo, state.level * state.cfg.combo.step)
  state.last_ms = now()
  show_counter()
  publish(true)
  arm_decay()
  return true
end

local function on_change()
  local cfg = state.cfg
  if not cfg.enabled then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if excluded(buf) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end

  local t = now()
  state.combo = (t - state.last_ms <= cfg.combo.window_ms) and state.combo + 1 or 1
  state.last_ms = t

  local level = level_of(state.combo)
  local previous = state.level
  state.level = level

  show_counter()
  publish(false)
  arm_decay()

  if level > previous then
    local name = tier(level).name
    if name then
      vim.notify(("⚡ %s ×%d"):format(name, state.combo), level >= 5 and vim.log.levels.WARN or vim.log.levels.INFO, {
        title = "power-surge",
      })
    end
  end
end

local function on_typed(char)
  local word = state.cfg.overdrive.word
  if char == "" or word == "" or not state.cfg.enabled then
    return
  end
  state.typed = (state.typed .. char):sub(-#word)
  if state.typed == word then
    state.typed = ""
    vim.schedule(M.overdrive)
  end
end

function M.enabled()
  return state.cfg.enabled == true
end

function M.set_enabled(value)
  state.cfg.enabled = value and true or false
  if not state.cfg.enabled then
    close_counter()
    publish_dead()
    if state.decay then
      state.decay:stop()
      state.decay = nil
    end
  end
  vim.notify("power-surge " .. (state.cfg.enabled and "on" or "off"), vim.log.levels.INFO, { title = "power-surge" })
  return state.cfg.enabled
end

function M.toggle()
  return M.set_enabled(not state.cfg.enabled)
end

--- Live counters, for tests and for a user's own statusline.
function M.status()
  return {
    combo = state.combo,
    level = state.level,
    enabled = state.cfg.enabled,
    float = state.win ~= nil and vim.api.nvim_win_is_valid(state.win),
  }
end

function M.clear()
  state.combo = 0
  state.level = 0
  close_counter()
  publish(true)
end

--- @param opts table?
function M.setup(opts)
  reconfigure(opts)
  if not state.wired then
    state.wired = true
    local group = vim.api.nvim_create_augroup("power_surge", { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, { group = group, callback = on_change })
    vim.api.nvim_create_autocmd("InsertCharPre", {
      group = group,
      callback = function()
        on_typed(vim.v.char)
      end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = publish_dead })
    vim.api.nvim_create_user_command("PowerSurge", function(args)
      local what = args.args == "" and "toggle" or args.args
      if what == "on" then
        M.set_enabled(true)
      elseif what == "off" then
        M.set_enabled(false)
      elseif what == "toggle" then
        M.toggle()
      elseif what == "overdrive" then
        M.overdrive()
      else
        vim.notify("power-surge: on | off | toggle | overdrive", vim.log.levels.ERROR, { title = "power-surge" })
      end
    end, {
      nargs = "?",
      complete = function()
        return { "on", "off", "toggle", "overdrive" }
      end,
      desc = "power-surge: a combo meter in a corner float",
    })
  end
  return M
end

return M
