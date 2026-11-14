## Named Nerd Font glyphs used by the shell, as UTF-8 strings to splice into
## labels (`IconOpenFile & "  Open file..."`). All are Codicons (the VS Code
## icon set, `nf-cod-*`), so they share one line weight and size; the names in
## the comments are Nerd Fonts' (glyphnames.json, v3.5.1). They lie in the
## Basic Multilingual Plane because imguin builds ImGui with 16-bit `ImWchar`:
## the Material Design range (U+F0001 and up) is out of reach.
##
## The bundled faces (JetBrainsMono Nerd Font) contain them. A theme that names
## a font without icons can add `icons = "<a Nerd Font>.ttf"` under `[fonts]`.

const
  IconOpenFile* = ""   ## nf-cod-file
  IconOpenFiles* = ""  ## nf-cod-files
  IconOpenFolder* = "" ## nf-cod-folder_opened
  IconFolder* = ""     ## nf-cod-folder
  IconSave* = ""       ## nf-cod-save
  IconSettings* = ""   ## nf-cod-settings_gear
  IconLog* = ""        ## nf-cod-output
  IconMap* = ""        ## nf-cod-map
  IconFilter* = ""     ## nf-cod-filter
  IconEye* = ""        ## nf-cod-eye
  IconEyeOff* = ""     ## nf-cod-eye_closed
  IconZoomIn* = ""     ## nf-cod-zoom_in
  IconZoomOut* = ""    ## nf-cod-zoom_out
  IconFit* = ""        ## nf-cod-screen_full
  IconPlay* = ""       ## nf-cod-play
  IconStep* = ""       ## nf-cod-debug_step_over
  IconPrevious* = ""   ## nf-cod-chevron_left
  IconNext* = ""       ## nf-cod-chevron_right
  IconWarning* = ""    ## nf-cod-warning
  IconError* = ""      ## nf-cod-error
  IconInfo* = ""       ## nf-cod-info
  IconClose* = ""      ## nf-cod-close
  IconCheck* = ""      ## nf-cod-check
  IconTheme* = ""      ## nf-cod-color_mode
  IconTable* = ""      ## nf-cod-table
  IconPlot* = ""       ## nf-cod-graph_line
  IconPulse* = ""      ## nf-cod-pulse
  IconLayers* = ""     ## nf-cod-layers
  IconTarget* = ""     ## nf-cod-target
  IconLocation* = ""   ## nf-cod-location
  IconQuit* = ""       ## nf-cod-close

  AllIcons* = [IconOpenFile, IconOpenFiles, IconOpenFolder, IconFolder, IconSave,
    IconSettings, IconLog, IconMap, IconFilter, IconEye, IconEyeOff, IconZoomIn,
    IconZoomOut, IconFit, IconPlay, IconStep, IconPrevious, IconNext, IconWarning,
    IconError, IconInfo, IconClose, IconCheck, IconTheme, IconTable, IconPlot, IconPulse,
    IconLayers, IconTarget, IconLocation]
    ## for tests: every glyph above must be in the UI font

func codepoint*(icon: string): int =
  ## The code point of a one-glyph icon string (three UTF-8 bytes).
  assert icon.len == 3
  (icon[0].int and 0x0f) shl 12 or (icon[1].int and 0x3f) shl 6 or (icon[2].int and 0x3f)
