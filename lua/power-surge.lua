-- power-surge: sparks on every text change, with a combo meter and an overdrive easter egg.
--
-- Every particle is one stable extmark: a single `nvim_buf_set_extmark` with an `id`
-- moves it, and `nvim_buf_del_extmark` retires it. One frame is O(particles), never a
-- clear-and-redraw of the namespace.
--
-- Colors are highlight links to standard groups, so the effect follows any colorscheme.
-- Glyphs are text, so it works in every UI, Tern surface included.
local M = {}

local defaults = {
  enabled = true,
  fps = 45, -- frames per second while particles are alive
  max_particles = 240,
  burst = { 3, 6 }, -- particles per change, before the level bonus
  per_level = 3, -- extra particles per combo level
  gravity = 0.34, -- rows per frame, added every frame
  kick = 0.7, -- sideways speed, scaled by level
  drag = 0.94, -- sideways decay per frame
  life = { 26, 44 }, -- frames a particle lives
  spread = 1.2, -- columns of jitter at the spawn row, scaled by level
  combo = {
    window_ms = 600, -- a longer gap than this starts a new combo
    step = 5, -- changes per level
    max_level = 6,
    decay_ms = 1200, -- idle time before the meter falls back to zero
  },
  shake = { enabled = true, from_level = 5, rows = 2 },
  flash = { enabled = true, pulses = 2 },
  counter = { enabled = true }, -- the ⚡ combo counter at the end of the cursor's line
  overdrive = {
    word = "surge", -- typed in insert mode, this word fires the easter egg
    burst = 120,
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

-- One row per combo level: sharper glyphs and a wider fountain as the combo climbs.
--- One row per combo level: sharper glyphs and a wider fountain as the combo climbs.
local TIERS = {
  { name = "", glyphs = { "•", "∙" } },
  { name = "", glyphs = { "✦", "•" } },
  { name = "SPARK", glyphs = { "✦", "✧", "•" } },
  { name = "SURGE", glyphs = { "✷", "✦", "✧" } },
  { name = "OVERDRIVE", glyphs = { "⚡", "✷", "↯" } },
  { name = "UNSTOPPABLE", glyphs = { "⚡", "↯", "✷", "★" } },
}

local HL = { "PowerSurge1", "PowerSurge2", "PowerSurge3", "PowerSurge4", "PowerSurge5", "PowerSurge6" }

-- Links, not colors: the effect follows any theme. The tiers climb from muted to loud.
local LINKS = {
  PowerSurge1 = "Comment",
  PowerSurge2 = "Function",
  PowerSurge3 = "DiagnosticInfo",
  PowerSurge4 = "DiagnosticWarn",
  PowerSurge5 = "DiagnosticError",
  PowerSurge6 = "Special",
  PowerSurgeFlash = "ErrorMsg",
}

local BOLD = { PowerSurge4 = true, PowerSurge5 = true, PowerSurge6 = true }

local state = {
  cfg = defaults,
  ns = nil,
  timer = nil,
  decay = nil,
  counter = nil, -- { buf, id } of the combo counter, while one is shown
  particles = {},
  combo = 0,
  level = 0,
  last_ms = 0,
  typed = "",
  winhl = {},
  wired = false,
}

local uv = vim.uv or vim.loop

local function now()
  return uv.now()
end

local function define_hl()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true, bold = BOLD[group] })
  end
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

local function drop(p)
  if vim.api.nvim_buf_is_valid(p.buf) then
    pcall(vim.api.nvim_buf_del_extmark, p.buf, state.ns, p.id)
  end
end

--- The combo counter: one extmark at the end of the cursor's line, rewritten in place.
local function show_counter(win, buf, combo, level)
  if not state.cfg.counter.enabled
    or not vim.api.nvim_buf_is_valid(buf)
    or vim.api.nvim_win_get_config(win).relative ~= ""
  then
    return
  end
  local name = tier(level).name
  local text = ("⚡ %d"):format(combo)
  if name ~= "" then
    text = text .. "  " .. name
  end
  local row = unpack(vim.api.nvim_win_get_cursor(win))
  local opts = {
    virt_text = { { text, HL[math.min(#HL, level)] } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  }
  if state.counter and state.counter.buf == buf then
    opts.id = state.counter.id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, state.ns, row - 1, 0, opts)
  if ok then
    state.counter = { buf = buf, id = id }
  end
end

local function hide_counter()
  local c = state.counter
  state.counter = nil
  if c and vim.api.nvim_buf_is_valid(c.buf) then
    pcall(vim.api.nvim_buf_del_extmark, c.buf, state.ns, c.id)
  end
end

local function clear_particles()
  for _, p in ipairs(state.particles) do
    drop(p)
  end
  state.particles = {}
end

--- Place the particle and remember the mark id so later frames move it in place.
local function place(p, first)
  if not vim.api.nvim_buf_is_valid(p.buf) then
    return false
  end
  local opts = {
    virt_text = { { p.glyph, p.hl } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  }
  -- A placed particle is moved by its own id; a new one gets an id from nvim.
  if not first and p.id then
    opts.id = p.id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, p.buf, state.ns, math.max(0, math.floor(p.row)), math.max(0, math.floor(p.col)), opts)
  if not ok then
    state.last_err = tostring(id)
    return false
  end
  p.id = id
  return true
end

local function spawn(buf, row, col, count, level)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = state.cfg
  local t = tier(level)
  local lines = vim.api.nvim_buf_line_count(buf)
  for _ = 1, count do
    if #state.particles >= cfg.max_particles then
      return
    end
    local p = {
      buf = buf,
      row = row,
      col = math.max(0, col + (math.random() * 2 - 1) * cfg.spread * level),
      dx = (math.random() * 2 - 1) * cfg.kick * level,
      dy = -0.15 * math.random() * level,
      life = math.random(cfg.life[1], cfg.life[2]),
      glyph = t.glyphs[math.random(#t.glyphs)],
      hl = HL[math.min(#HL, level)],
    }
    if p.row >= 0 and p.row < lines and place(p, true) then
      state.particles[#state.particles + 1] = p
    end
  end
end

local function stop()
  if state.timer then
    state.timer:stop()
    state.timer = nil
  end
end

local function step()
  local cfg = state.cfg
  local alive = {}
  for _, p in ipairs(state.particles) do
    p.life = p.life - 1
    p.dy = p.dy + cfg.gravity
    p.dx = p.dx * cfg.drag
    p.row = p.row + p.dy
    p.col = p.col + p.dx
    local lines = vim.api.nvim_buf_is_valid(p.buf) and vim.api.nvim_buf_line_count(p.buf) or 0
    -- Clamp, never drop: a particle that leaves the buffer is invisible for good, which reads
    -- as "nothing happened" near the top or bottom of a short file.
    p.row = math.max(0, math.min(lines - 1, p.row))
    p.col = math.max(0, p.col)
    if p.life > 0 and place(p, false) then
      alive[#alive + 1] = p
    else
      drop(p)
    end
  end
  state.particles = alive

  if now() - state.last_ms > cfg.combo.decay_ms and state.level > 0 then
    state.combo = 0
    state.level = 0
    hide_counter()
  end
  -- The counter outlives the last particle: keep ticking until the combo decays.
  if #state.particles == 0 and state.level == 0 then
    stop()
  end
end

local function start()
  if state.timer then
    return
  end
  local timer = uv.new_timer()
  state.timer = timer
  timer:start(0, math.max(16, math.floor(1000 / state.cfg.fps)), function()
    vim.schedule(function()
      if not state.timer then
        return
      end
      if not state.cfg.enabled then
        clear_particles()
        stop()
        return
      end
      step()
    end)
  end)
end

--- Nudge the viewport by a row or two, then put it back. Skips short buffers.
local function shake(win)
  local cfg = state.cfg.shake
  if not cfg.enabled or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local buf = vim.api.nvim_win_get_buf(win)
  local total = vim.api.nvim_buf_line_count(buf)
  local height = vim.api.nvim_win_get_height(win)
  if total <= height + 2 then
    return
  end
  local delta = math.random() < 0.5 and -cfg.rows or cfg.rows
  local top = math.max(1, math.min(total - height, view.topline + delta))
  if top == view.topline then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = top })
  end)
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = view.topline })
      end)
    end
  end, 50)
end

--- Pulse the window background through `winhighlight`; the window gets its own value back.
local function flash(win)
  if not state.cfg.flash.enabled or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local original = state.winhl[win]
  if original == nil then
    original = vim.api.nvim_get_option_value("winhighlight", { win = win })
    state.winhl[win] = original
  end
  local patched = original == "" and "Normal:PowerSurgeFlash" or original .. ",Normal:PowerSurgeFlash"
  local function pulse(n)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    pcall(vim.api.nvim_set_option_value, "winhighlight", patched, { win = win })
    vim.defer_fn(function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      pcall(vim.api.nvim_set_option_value, "winhighlight", original, { win = win })
      if n > 1 then
        vim.defer_fn(function()
          pulse(n - 1)
        end, 70)
      end
    end, 80)
  end
  pulse(math.max(1, state.cfg.flash.pulses))
end

--- The easter egg: a full burst, a flash, a shake.
function M.overdrive()
  local cfg = state.cfg
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  if excluded(buf) then
    return false
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  state.level = cfg.combo.max_level
  spawn(buf, row - 1, col, cfg.overdrive.burst, cfg.combo.max_level)
  start()
  flash(win)
  shake(win)
  vim.notify("⚡ OVERDRIVE", vim.log.levels.WARN, { title = "power-surge" })
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

  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local count = math.random(cfg.burst[1], cfg.burst[2]) + (level - 1) * cfg.per_level
  spawn(buf, row - 1, col, count, level)
  show_counter(win, buf, state.combo, level)
  start()

  if level > previous then
    if level >= cfg.shake.from_level then
      shake(win)
    end
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
    state.combo = 0
    state.level = 0
    clear_particles()
    hide_counter()
    stop()
  end
  vim.notify("power-surge " .. (state.cfg.enabled and "on" or "off"), vim.log.levels.INFO, { title = "power-surge" })
  return state.cfg.enabled
end

function M.toggle()
  return M.set_enabled(not state.cfg.enabled)
end

--- Live counters, for the statusline and for tests.
function M.status()
  return {
    error = state.last_err,
    combo = state.combo,
    level = state.level,
    particles = #state.particles,
    running = state.timer ~= nil,
    enabled = state.cfg.enabled,
  }
end

function M.clear()
  clear_particles()
  hide_counter()
  state.combo = 0
  state.level = 0
  stop()
end

--- @param opts table?
function M.setup(opts)
  reconfigure(opts)
  state.ns = state.ns or vim.api.nvim_create_namespace("power-surge")
  define_hl()

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
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_hl })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      callback = function(args)
        for i = #state.particles, 1, -1 do
          if state.particles[i].buf == args.buf then
            table.remove(state.particles, i)
          end
        end
      end,
    })
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
      desc = "power-surge: sparks on every text change",
    })
  end
  return M
end

return M
