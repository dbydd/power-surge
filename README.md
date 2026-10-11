# power-surge

Sparks on every text change. A combo meter climbs while you type, the fountain gets
sharper, and the screen shakes once the combo runs hot. Type `surge` in insert mode for
the easter egg.

```lua
{
  "power-surge",
  dir = "~/source/power-surge",
  event = "VeryLazy",
  opts = {},
}
```

## What it does

| Where | Effect |
|---|---|
| Text change | 2 to 4 particles per change, more as the level climbs |
| Combo | 5 changes per level, up to level 6, reset after 1.2 s of quiet |
| Level 3+ | sharper glyphs (`✳ ✷ ↯ ⚡`), wider fountain |
| Level 4 to 6 | a toast, and the viewport shakes |
| `surge` typed in insert | a 120-particle burst, a background flash, a shake |

## Commands

| Command | Effect |
|---|---|
| `:PowerSurge` | toggle |
| `:PowerSurge on` / `off` | set the state |
| `:PowerSurge overdrive` | fire the easter egg by hand |

## Design notes

- **Stable extmark per particle.** One `nvim_buf_set_extmark` with an `id` moves a
  particle; `nvim_buf_del_extmark` retires it. There is no namespace clear and redraw.
- **One timer, only while particles are alive.** The 45 fps loop stops itself when the
  last particle dies.
- **Colors are links.** `PowerSurge1`–`6` link to standard highlight groups, so the
  effect reads right in every theme; `ColorScheme` re-links them.
- **Glyphs are text.** No image protocol, no font feature: it works in every UI, a Tern
  surface included.
- **The flash is window-local.** `winhighlight` gets a `PowerSurgeFlash` patch, then the
  window's own value comes back.

## Options

Every default lives in `defaults` at the top of `lua/power-surge.lua`. The interesting
ones:

```lua
opts = {
  fps = 45,
  max_particles = 160,
  burst = { 2, 4 },
  combo = { window_ms = 600, step = 5, max_level = 6, decay_ms = 1200 },
  shake = { enabled = true, from_level = 5, rows = 2 },
  flash = { enabled = true, pulses = 2 },
  overdrive = { word = "surge", burst = 120 },
  exclude_filetypes = { "TelescopePrompt", "lazy", "mason" },
}
```
