# Themes

A theme is one `.toml` file: an [Omarchy](https://omarchy.org) `colors.toml`, plus optional
viewSEG tables. Any Omarchy theme's `colors.toml` works as it is, in either of its forms
(the named colours of `everforest-dark.toml`, or the terminal form with `color0` ..
`color15`).

- **Shipped:** `everforest-dark.toml` (Omarchy's Everforest) and `everforest-light.toml`
  (upstream Everforest light, medium contrast). *View > Theme > Follow system* uses them
  for a dark or a light desktop.
- **Your own:** copy one to `<config>/themes/<name>.toml` (`viewSEG --paths` prints
  `<config>`), edit it, and choose it under *View > Theme*. A file there with the name of
  a shipped one replaces it. `VIEWSEG_THEME=<name>` (or a path) picks one at start;
  `VIEWSEG_THEME=dark` or `light` forces the mode.
- **Only colours are needed.** Every colour on screen (panels, bars, text, borders,
  selection, plots, trace and fill defaults, the series palette) is derived from them;
  `[roles]` sets any of them directly. `[fonts]` names the font files (in `../fonts/`)
  and sizes; `[metrics]` the rounding, padding and spacing. `everforest-dark.toml`
  explains each key.
- **Mistakes never stop the program:** an unknown key, a bad value or a missing colour
  is reported in the Messages window and replaced by the built-in Everforest value.
