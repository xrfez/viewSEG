# Fonts

viewSEG draws its interface with **JetBrainsMono Nerd Font**: JetBrains Mono 2.304,
patched by Nerd Fonts with icon sets (viewSEG uses its Codicons). Which files are
loaded is set in the theme file (`[fonts]` in `../themes/*.toml`), so a font can be
swapped without rebuilding.

| File | Used for | SHA-256 |
|---|---|---|
| `JetBrainsMonoNerdFontPropo-Regular.ttf` | labels, menus, buttons, icons | `8a2803de76ad18ed82f465dfd17130032c34c031b263179d3047a547c7caa460` |
| `JetBrainsMonoNerdFontMono-Regular.ttf` | tables, numbers, the status bar | `f2a5ea6cfab397445ffab00c0370927b66d61e560a05db5db271b42006381c1a` |
| `JetBrainsMonoNerdFontPropo-Bold.ttf` | headings, table headers | `a391d2887d63add54d87a715fe257e522120eb4f1df52d104fa17984fcb68021` |

- **Source:** <https://github.com/ryanoasis/nerd-fonts>, tag `v3.5.1` (commit
  `b894ea7803af6aade63d60a4381e006098ec9c4d`), directory
  `patched-fonts/JetBrainsMono/Ligatures/`, files downloaded unchanged from
  `https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.5.1/patched-fonts/JetBrainsMono/Ligatures/<file>`.
- **Licence:** SIL Open Font License 1.1 (JetBrains Mono: `licences/JetBrainsMono-OFL.txt`;
  the Nerd Fonts patches and icon sets: `licences/NerdFonts-LICENSE.md`, which points to
  the per-icon-set licences: Codicons CC BY 4.0, Font Awesome CC BY 4.0, Material Design
  Apache 2.0, and others, listed in Nerd Fonts' `license-audit.md`).
- "Propo" is the proportional variant (icons at their natural width), "Mono" the strictly
  monospaced one (icons one cell wide). ImGui does no ligature shaping, so the ligature
  build draws the same glyphs as the no-ligature one.

To update: download the same three files from a newer tag, update the table above, and
run the tests (`tests/tfonts.nim` checks that every icon viewSEG uses is in the UI font).
