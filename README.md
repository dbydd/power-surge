# power-surge

Sparks on every text change in Neovim. A combo meter climbs while you type, the fountain
gets sharper, and the screen shakes once the combo runs hot. The Tern half turns it into
a command, a chord, and an easter egg.

## The two halves

| Path | What it is |
|---|---|
| `lua/power-surge.lua` | The Neovim plugin: particles, combo meter, easter egg |
| `tern/` | The Tern plugin: palette commands, chords, and Tern-side controls |

The particles live in Neovim, because that is where text changes happen. The Tern half
drives them: each action types a `:lua` command into the focused Neovim pane.

## Neovim

```lua
{
  "dbydd/power-surge",
  event = "VeryLazy",
  opts = {},
}
```

| Where | Effect |
|---|---|
| Text change | 3 to 6 particles, plus 3 per combo level |
| Combo | 5 changes per level, up to level 6, reset after 1.2 s of quiet |
| Counter | Tern's tab title carries `⚡12 SURGE`; Tern's whole window glows as the level climbs |
| Counter (plain nvim) | `require'power-surge'.statusline()` returns the same segment for lualine |
| Level 3+ | sharper glyphs (`✦ ✷ ↯ ⚡ ★`), a wider fountain |
| Level 5, 6 | a toast, and the viewport shakes |
| `surge` typed in insert mode | a 120-particle burst, a background flash, a shake |
| `<leader>up` | toggle |

```vim
:PowerSurge on | off | toggle | overdrive
```

## Tern

```sh
tern plugin install github.com/dbydd/power-surge/tern
```

The Neovim half is spawned by [neotern](https://github.com/arg3t/neotern) (installed here as
`ntern`); the Tern half recognizes that pane by its state file.

| Action | Chord | Effect |
|---|---|---|
| Power Surge: Overdrive | `ctrl+alt+shift+p` | the easter egg, in the focused Neovim pane |
| Power Surge: Toggle | `ctrl+alt+shift+s` | turn the particles on or off |
| Toggle Files Pane | `ctrl+alt+shift+f` | Tern's own file browser |
| Overdrive | `ctrl+alt+shift+e` | the bind, for muscle memory |

The Neovim half publishes the combo to `/tmp/power-surge/<cwd>.json` (throttled to 120 ms);
the Tern half polls it, retitles the tab, and installs a CSS glow whose ring tightens with
the level. It polls at 200 ms while a combo is live, 1 s while it fades, and sleeps after a
minute of nothing until a window event wakes it.

Both commands show up in the palette, and both are available only while the focused pane
runs `nvim` or `ntern`.

## Design notes

- **Stable extmark per particle.** One `nvim_buf_set_extmark` with an `id` moves a
  particle; `nvim_buf_del_extmark` retires it. There is no namespace clear and redraw.
- **One timer, only while particles are alive.** The 45 fps loop stops itself when the
  last particle dies.
- **Colors are links.** `PowerSurge1`–`6` link to standard highlight groups, so the effect
  reads right in every theme; `ColorScheme` re-links them.
- **Glyphs are text.** No image protocol, no font feature: it works in every UI, a Tern
  surface included, where each particle is one styled cell.
- **The flash is window-local.** `winhighlight` gets a `PowerSurgeFlash` patch, and the
  window's own value comes back.

## Options

Every default lives in `defaults` at the top of `lua/power-surge.lua`:

```lua
opts = {
  fps = 45,
  max_particles = 240,
  burst = { 3, 6 },
  spread = 1.2,
  combo = { window_ms = 600, step = 5, max_level = 6, decay_ms = 1200 },
  shake = { enabled = true, from_level = 5, rows = 2 },
  flash = { enabled = true, pulses = 2 },
  overdrive = { word = "surge", burst = 120 },
  exclude_filetypes = { "TelescopePrompt", "lazy", "mason" },
}
```
