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
  IconProject* = "\u{EB30}" ## nf-cod-project
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
  IconFft* = "\u{EB03}" ## nf-cod-graph
  IconSpectrogram* = "\u{EBE3}" ## nf-cod-graph_scatter
  IconEnvelope* = "\u{EBAD}" ## nf-cod-graph_left
  IconPhase* = "\u{EBD5}" ## nf-cod-compass
  IconCorrelation* = "\u{EBCB}" ## nf-cod-arrow_swap
  IconVibrator* = "\u{EB34}" ## nf-cod-radio_tower
  IconFk* = "\u{EC30}"  ## nf-cod-map_vertical
  IconRuler* = "\u{EA96}" ## nf-cod-symbol_ruler
  IconLayers* = ""     ## nf-cod-layers
  IconTarget* = ""     ## nf-cod-target
  IconLocation* = ""   ## nf-cod-location
  IconQuit* = "\u{EA6E}" ## nf-cod-sign_out
  IconStop* = "\u{EAD7}" ## nf-cod-debug_stop
  IconRemove* = "\u{EB3B}" ## nf-cod-remove
  IconRefresh* = ""    ## nf-cod-refresh
  IconReset* = "\u{EAD2}" ## nf-cod-debug_restart
  IconHome* = "\u{EB06}" ## nf-cod-home
  IconSync* = "\u{EA77}" ## nf-cod-sync
  IconSurvey* = "\u{EB01}" ## nf-cod-globe
  IconSliders* = "\u{EB52}" ## nf-cod-settings
  IconMemory* = "\u{EA98}" ## nf-cod-archive
  IconLoading* = "\u{EB19}" ## nf-cod-loading
  IconLayout* = "\u{EBEB}" ## nf-cod-layout
  IconArrowUp* = ""    ## nf-cod-arrow_up
  IconArrowDown* = ""  ## nf-cod-arrow_down
  IconTrash* = ""      ## nf-cod-trash
  IconCopy* = ""       ## nf-cod-copy
  IconClearAll* = ""   ## nf-cod-clear_all
  IconTasks* = ""      ## nf-cod-tasklist
  IconList* = ""       ## nf-cod-list_flat
  IconGoTo* = ""       ## nf-cod-go_to_file
  IconExport* = ""     ## nf-cod-export
  IconHistory* = ""    ## nf-cod-history
  IconRecordBack* = "" ## nf-cod-triangle_left
  IconRecordNext* = "" ## nf-cod-triangle_right
  IconRecords* = ""    ## nf-cod-list_ordered
  IconNew* = ""        ## nf-cod-circle_filled
  IconWriting* = ""    ## nf-cod-edit
  IconFollow* = ""     ## nf-cod-debug_step_into
  IconAgent* = ""      ## nf-cod-robot
  IconUndo* = "\u{EAE2}" ## nf-cod-discard
  IconRedo* = "\u{EBB0}" ## nf-cod-redo
  IconTray* = "\u{EB09}" ## nf-cod-inbox
  IconMinimize* = "\u{EABA}" ## nf-cod-chrome_minimize
  IconPin* = "\u{EB2B}" ## nf-cod-pin

  AllIcons* = [IconOpenFile, IconOpenFiles, IconOpenFolder, IconFolder, IconProject, IconSave,
    IconSettings, IconLog, IconMap, IconFilter, IconEye, IconEyeOff, IconZoomIn,
    IconZoomOut, IconFit, IconPlay, IconStep, IconPrevious, IconNext, IconWarning,
    IconError, IconInfo, IconClose, IconCheck, IconTheme, IconTable, IconPlot, IconPulse,
    IconFft, IconSpectrogram, IconEnvelope, IconPhase, IconCorrelation, IconVibrator, IconFk,
    IconRuler,
    IconLayers, IconTarget, IconLocation, IconQuit, IconStop, IconRemove, IconRefresh,
    IconReset, IconHome, IconSync, IconSurvey, IconSliders, IconMemory, IconLoading,
    IconLayout, IconArrowUp, IconArrowDown, IconTrash, IconCopy, IconClearAll, IconTasks,
    IconList, IconGoTo, IconExport, IconHistory, IconRecordBack, IconRecordNext,
    IconRecords, IconNew, IconWriting, IconFollow, IconAgent, IconUndo, IconRedo,
    IconTray, IconMinimize, IconPin]
    ## for tests: every glyph above must be in the UI font

func codepoint*(icon: string): int =
  ## The code point of a one-glyph icon string (three UTF-8 bytes).
  assert icon.len == 3
  (icon[0].int and 0x0f) shl 12 or (icon[1].int and 0x3f) shl 6 or (icon[2].int and 0x3f)
