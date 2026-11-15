# Themes

A theme is one `.toml` file: an [Omarchy](https://omarchy.org) `colors.toml`, plus optional
viewSEG tables. Any Omarchy theme's `colors.toml` works as it is, in either of its forms
(the named colours of `everforest-dark.toml`, or the terminal form with `color0` ..
`color15`).

- **Shipped:** every theme of Omarchy, and Everforest Light (below). *View > Theme* lists
  them, dark ones first, each with a swatch of its background, text and accent colours;
  resting the pointer on one shows the program in it until the menu closes, and a click
  keeps it. *Follow system* uses `everforest-dark.toml` and `everforest-light.toml` for a
  dark or a light desktop, and is the default.
- **Your own:** copy one to `<config>/themes/<name>.toml` (`viewSEG --paths` prints
  `<config>`), edit it, and choose it under *View > Theme*. A file there with the name of
  a shipped one replaces it. `VIEWSEG_THEME=<name>` (or a path) picks one at start;
  `VIEWSEG_THEME=dark` or `light` forces the mode.
- **Only colours are needed.** Every colour on screen (panels, bars, text, borders,
  selection, plots, trace and fill defaults, the map's points, the series palette) is
  derived from them; `[roles]` sets any of them directly. `[fonts]` names the font files
  (in `../fonts/`) and sizes; `[metrics]` the rounding, padding and spacing.
  `everforest-dark.toml` explains each key.
- **Mistakes never stop the program:** an unknown key, a bad value or a missing colour
  is reported in the Messages window (20 problems at most per file) and replaced by the
  built-in Everforest value. A theme file is read when viewSEG starts (and again when
  chosen, if it changed since); one over 64 KiB, or anything but a plain file, is not
  read.
  Omarchy's keys for other programs (`hyprland_*`, `active_border_color`, ...) are
  ignored without a word.

## Readable in every theme

Some palettes are made for a terminal or a desktop, not for a program full of small
text and marks on a plot: a yellow that cannot be read on a light background, a
selection the colour of the popup it is in, a hover colour equal to the selection's.
So viewSEG moves a derived colour (never the file's own) where it would fail these
limits, and leaves it alone where it does not:

| What | Against | At least |
|---|---|---|
| Text | windows, popups, bars, buttons and inputs, a selected or hovered item | contrast 4.5 (WCAG AA) |
| Secondary text, the accent, ok, warning, error and information colours | the same | contrast 3 |
| Disabled items | windows and popups | contrast 2 |
| A selected or hovered item | the window, popup or button it is on | contrast 1.08 |
| The plot's traces, fills, a hovered and a selected trace | the plot, on paper and in the theme's colours | contrast 3 |
| A hovered or a selected trace | the traces; each other | a colour difference (CIE76) of 25; 30 |
| The map's sources | its receivers, on paper and in the theme's colours | a colour difference of 40 |
| The map's sources and receivers | the hovered and the selected points (larger, outlined) | a colour difference of 20 |

Text and status colours are lightened on a dark theme and darkened on a light one;
secondary text that is brighter than the text is dimmed; a selection that does not
show is moved toward the text colour. The marks (`selected`, `highlight`, `source`,
`receiver`) are taken from the theme's other colours when its own are too close, and
from Everforest's (or a set of strong colours) when none of its colours will do, as
in the grey themes (Vantablack, White). Each file says in its header which roles
viewSEG moves in it. The seismic colour maps (grey, red-white-blue, viridis,
red-black) are data colours and do not change with the theme.

## Where each theme comes from

The files are Omarchy's `colors.toml`, copied from Omarchy 4.0.0.alpha (Osaka Jade, which
has none there: from Omarchy's repository, `omacom/omarchy` at `master`). Omarchy is ©
David Heinemeier Hansson under the MIT licence (`licences/themes/Omarchy-LICENSE.txt`).
Where a palette comes from another project, that project and its licence are named
below; its licence text is in `licences/themes/`. "Not checked" means its licence could
not be read; nothing else is claimed for it. Where Omarchy names no source, the source
given is what its theme files point to (the Neovim colour scheme it installs), not a
statement of Omarchy's.

| File | Theme | Mode | Palette from | Licence |
|---|---|---|---|---|
| `catppuccin.toml` | Catppuccin (Mocha) | dark | Catppuccin, `catppuccin/catppuccin` | MIT, © 2021 Catppuccin |
| `catppuccin-latte.toml` | Catppuccin Latte | light | Catppuccin, `catppuccin/catppuccin` | MIT, © 2021 Catppuccin |
| `ethereal.toml` | Ethereal | dark | Omarchy (by bjarneo) | Omarchy's MIT |
| `everforest-dark.toml` | Everforest Dark | dark | Everforest by sainnhe, `sainnhe/everforest`, as Omarchy has it | MIT, © 2019 sainnhe |
| `everforest-light.toml` | Everforest Light | light | Everforest by sainnhe, `sainnhe/everforest` (light, medium; not in Omarchy) | MIT, © 2019 sainnhe |
| `flexoki-light.toml` | Flexoki Light | light | Flexoki by Steph Ango, `kepano/flexoki` | MIT, © 2023 Steph Ango |
| `gruvbox.toml` | Gruvbox | dark | Gruvbox Material by sainnhe, `sainnhe/gruvbox-material` (by its colours; Omarchy's Neovim scheme is `ellisonleao/gruvbox.nvim`) | MIT, © 2020 sainnhe |
| `hackerman.toml` | Hackerman | dark | Omarchy (by bjarneo) | Omarchy's MIT |
| `jade-horse.toml` | Jade Horse | dark | Omarchy | Omarchy's MIT |
| `kanagawa.toml` | Kanagawa | dark | Kanagawa by Tommaso Laurenzi, `rebelot/kanagawa.nvim` | MIT, © 2021 Tommaso Laurenzi |
| `last-horizon.toml` | Last Horizon | dark | Last Horizon by HANCORE, `HANCORE-linux/omarchy-lasthorizon-theme` | MIT, © 2025 HANCORE |
| `lumon.toml` | Lumon | dark | Omarchy (`omacom/lumon.nvim`) | Omarchy's MIT |
| `lupine.toml` | Lupine | light | Omarchy | Omarchy's MIT |
| `matte-black.toml` | Matte Black | dark | Matte Black by Taha Nejad, `tahayvr/matteblack.nvim` | MIT, © 2025 Taha Nejad |
| `miasma.toml` | Miasma | dark | Miasma by xero, `xero/miasma.nvim` | CC0 1.0 |
| `nord.toml` | Nord | dark | Nord by Sven Greb, `nordtheme/nord` | MIT, © 2016-present Sven Greb |
| `osaka-jade.toml` | Osaka Jade | dark | Omarchy (its Neovim scheme is `ribru17/bamboo.nvim`, MIT) | Omarchy's MIT; the palette's own source not checked |
| `retro-82.toml` | Retro 82 | dark | Retro 82 by OldJobobo, `OldJobobo/omarchy-retro-82-theme` | not checked (the repository has no licence file; its Neovim scheme `OldJobobo/retro-82.nvim` is CC0 1.0) |
| `ristretto.toml` | Ristretto | dark | Monokai Pro's Ristretto filter (monokai.pro) | not checked (Monokai Pro is a commercial theme; its Neovim port `loctvl842/monokai-pro.nvim` is MIT for its code) |
| `rose-pine.toml` | Rosé Pine (Dawn) | light | Rosé Pine, `rose-pine/rose-pine-palette` | MIT, © mvllow |
| `solitude.toml` | Solitude | dark | Solitude by HANCORE, `HANCORE-linux/omarchy-solitude-theme` | MIT, © 2026 HANCORE |
| `starship.toml` | Starship | dark | Omarchy | Omarchy's MIT |
| `tokyo-night.toml` | Tokyo Night | dark | Tokyo Night by Enkia, `enkia/tokyo-night-vscode-theme` (Omarchy's Neovim scheme is `folke/tokyonight.nvim`, Apache 2.0) | MIT, © 2018-present Enkia |
| `vantablack.toml` | Vantablack | dark | Omarchy (by bjarneo) | Omarchy's MIT |
| `white.toml` | White | light | Omarchy (by bjarneo) | Omarchy's MIT |

What changed in viewSEG's copies: each has a `name` and a header saying where it is
from; Omarchy's keys for other programs are left out; Last Horizon, Solitude and White
have `orange` and `brown` written out as viewSEG derives them (their files have none);
Osaka Jade is turned from the terminal form into the named keys, with the bright
yellow as its yellow (its `color3` is a green). No other colour is changed.
