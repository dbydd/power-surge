# power-surge

A combo meter that never gets between you and the text. Type, and the meter climbs; the
screen flare is Tern's own, so nothing is drawn at the cursor and the viewport never moves.
The Neovim half keeps the combo and shows it in a corner float; the Tern half turns that
combo into a command, a chord, and an easter egg.

## The two halves

| Path | What it is |
|---|---|
| `lua/power-surge.lua` | The Neovim plugin: the combo, its float counter, the easter egg |
| `tern/` | The Tern plugin: Tern's own cursor effects, driven by the combo; palette commands and chords |

Text changes happen in Neovim, so the combo is counted there. Tern owns the screen effect,
so the level is published to it: one small JSON per working directory, polled by the Tern
half.

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
| Text change | the combo climbs; nothing is drawn in the buffer |
| Combo | 5 changes per level, up to level 6, reset after 1.2 s of quiet |
| Counter | a small non-focusable float in the corner, closed when the combo decays |
| Level 3+ | the float names the tier: `SPARK`, `SURGE`, `OVERDRIVE`, `UNSTOPPABLE` |
| Level 5, 6 | a notification, and (in Tern) the loudest cursor effects |
| `surge` typed in insert mode | the easter egg: max level for one burst |
| `<leader>up` | toggle |

```vim
:PowerSurge on | off | toggle | overdrive
```

## Tern

```sh
tern plugin install github.com/dbydd/power-surge/tern
```

The screen effect is Tern's own: `cursor.trail` (off, warp, comet, blaze, sparks, echo) and
`cursor.pulse` (off, ripple, sonic_boom, box_ripple, box_boom). The combo only picks which
pair is playing, and puts your own values back when it dies:

| Combo level | `cursor.trail` | `cursor.pulse` |
|---|---|---|
| 1–2 | yours | yours |
| 3 | `comet` | `ripple` |
| 4 | `blaze` | `box_ripple` |
| 5 | `sparks` | `sonic_boom` |
| 6 | `sparks` | `box_boom` |

| Action | Chord | Effect |
|---|---|---|
| Power Surge: Overdrive | `ctrl+alt+shift+p` | the easter egg, in the focused Neovim pane |
| Power Surge: Toggle | `ctrl+alt+shift+s` | turn the meter on or off |
| Overdrive | `ctrl+alt+shift+e` | the bind, for muscle memory |

Both commands show up in the palette, and both are available only while the focused pane
has a Neovim writing its state file (the pane whose `nvim` you last opened).

## Design notes

- **Nothing is drawn in the buffer.** No extmarks at the cursor, no viewport moves, no
  window flash: the combo lives in a corner float and in Tern's cursor effects, so it never
  competes with the text you are typing.
- **The counter float is inert.** `focusable = false`, `style = "minimal"`, its own
  `noautocmd` window, closed on decay; it never enters a buffer, a jump list or the cursor.
- **The screen effect is the terminal's.** Tern already draws cursor trails and pulses; the
  combo escalates which one is playing instead of painting over the terminal.
- **The user's settings are restored.** The baseline pair is read once and kept in the
  plugin's key-value store, so a combo that dies, a reload, or even a crash mid-combo leaves
  the terminal exactly as the user had it.

## Options

Every default lives in `defaults` at the top of `lua/power-surge.lua`:

```lua
opts = {
  combo = { window_ms = 600, step = 5, max_level = 6, decay_ms = 1200 },
  counter = {
    enabled = true,
    at = "bottom-right", -- or "cursor"
    render = nil, -- function(combo, level, name) -> string
    tern = true,
    tern_dir = "/tmp/power-surge",
    tern_interval_ms = 120,
  },
  overdrive = { word = "surge" },
  exclude_filetypes = { "TelescopePrompt", "lazy", "mason" },
}
```
