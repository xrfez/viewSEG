# viewSEG on Windows

What makes viewSEG look and behave like a Windows program, what was checked,
what is proposed, and what to check on a Windows machine. The build:
`nim winRelease` cross-compiles `bin/viewSEG.exe` with zig from Linux
(README.md, "Packaging"); `nim -d:packageTargets=windows package` puts it in
`dist/` with its `assets/`. How the parts fit: docs/architecture.md,
"Windows: what makes the window look native".

## What is done

### The title bar and the frame (`platform/chrome`, `ui/imgui/frames`)

Every window viewSEG opens gets its frame from the theme, through DWM window
attributes on its `HWND`:

| | Windows 10 1809 to 1909 | Windows 10 20H1 and later | Windows 11 |
|---|---|---|---|
| Dark or light title bar, as the theme's `mode` | attribute 19 | attribute 20 | attribute 20 |
| Title bar colour: the theme's `bar` (the menu bar's colour, so the two read as one band) | | | `DWMWA_CAPTION_COLOR` |
| Title colour: the theme's `text` | | | `DWMWA_TEXT_COLOR` |
| Border colour: the theme's `border` | | | `DWMWA_BORDER_COLOR` |
| Corners | | | round |

- The version comes from `RtlGetVersion`. When it cannot be read, every
  attribute is tried and Windows refuses the ones it does not know, which
  does no harm. Windows 10 1803 and older get nothing; nothing here can fail
  on any Windows 10.
- The frame follows the **theme**, not Windows' own light/dark setting: a light
  theme on a dark Windows has a light title bar. With View > Theme > Follow
  system the two agree.
- **Every window**: the main window, and each window Dear ImGui opens when a
  panel is dragged out of the main window, or a menu or tooltip goes past its
  edge. The SDL3 backend's `Platform_CreateWindow` is wrapped, so a new window
  gets its frame before it is first shown. Those windows have no Windows title
  bar (viewSEG draws its own), so they get the dark mode and **square
  corners** only: Windows 11 would otherwise clip the corners viewSEG draws
  and add a second border inside its own.
- **Again when the theme changes** (also while View > Theme previews one).
  A shown window is told to redraw its frame at once (`SWP_FRAMECHANGED`):
  Windows 10 repaints a changed title bar only then.
- **Kept through Windows' own changes.** On `WM_SETTINGCHANGE`
  "ImmersiveColorSet", which Windows sends for a light/dark switch and also
  for an accent colour or other personalisation change, SDL sets the
  *system's* dark mode on every window again, and tells viewSEG only when
  the light/dark setting itself changed. Each window is therefore subclassed
  (`SetWindowSubclass`) and gets the theme's look back right after SDL has
  handled that message.
- **Mica is not used.** viewSEG paints the whole of each window opaque
  (Dear ImGui and OpenGL), so the Mica backdrop could show only in the title
  bar, which the caption colour paints over. A translucent backdrop would
  need every panel drawn with alpha over a transparent OpenGL surface: much
  work for a look that does not suit a data viewer.

### Icons (`platform/chrome.setWindowIcons`)

SDL loads the executable's icon once, at the system's large size (32 pixels
at 100 %), and Windows scales that one image down for the title bar. viewSEG
now gives each framed window both icons at the sizes its screen wants (16 and
32 pixels at 100 %, 24 and 48 at 150 %), taken from the icon file's own images,
and again when the window moves to a screen of another scale. The taskbar,
Alt+Tab and Explorer read the same resource (`res/viewSEG.ico`: 16, 24, 32,
48, 64 and 256 pixels).

### The tray (`ui/imgui/shell`, Window menu)

- viewSEG's icon is in the notification area, with a menu: **Show viewSEG**,
  **Open file...**, **Quit** (SDL3's tray). Window > **Icon in the tray**
  (on by default) takes it away or puts it back.
- Window > **Minimize to the tray** (off by default): minimizing the main
  window hides it, and the windows dragged out of it, from the taskbar;
  Show viewSEG brings it back as it was (maximized stays maximized).
- **No ghost icon.** The icon is removed before the rest of the quit (File >
  Quit, closing the window, the tray's Quit), when an exception ends the
  program on the main thread (SDL's own quit runs) or on any other thread (a
  hook on Nim's unhandled exception removes it before the program ends),
  at Ctrl+C in a console build (the first one
  quits cleanly, the second at once) and on a crash: a fatal signal (an
  access violation, an abort) first removes the icon (`platform/trayguard`),
  then Nim writes its message and the program ends. Only a kill from outside
  (Task Manager's End task) leaves the icon until the pointer passes over it:
  nothing runs in the program then.
- On Linux the same tray uses AppIndicator (libayatana-appindicator3 through
  GTK), shown by bars with a StatusNotifier host (waybar, KDE, GNOME with
  the AppIndicator extension). SDL makes its tray whether or not anything
  will show it, so viewSEG first asks the session bus (off the UI thread)
  whether the StatusNotifier watcher is there with a host. With none (no
  session bus, or plain GNOME), no tray is made, Messages says once that
  there is no tray icon, Window > Minimize to the tray cannot be ticked, and
  a minimize never hides the window: it is asked again at each minimize, so
  a bar that went away is noticed too.

### The first window

On a screen too small for the default window (1280 x 800 at the screen's
scale, in 90 % of the work area), the first window opens **maximized**: on a
1080p laptop at 150 % (1280 x 688 usable at that scale) and on a 1366 x 768
screen at 100 %. Restored, it is 90 % of the work area, centred. On a 4K
laptop at 150 % it opens at 1920 x 1200 pixels, centred. A window placed
before opens where it was (as before).

## Checked, already right

- **Per-monitor DPI v2**: in the manifest (`PerMonitorV2`, with `true/pm` for
  older Windows 10), and SDL3 declares it too when its hint is unset. Text is
  baked at each monitor's scale (Dear ImGui 1.92, `ui/imgui/dpi`).
- **No console window**: the executable is a GUI program (PE subsystem 2;
  `tests/twinchrome.nim` reads it); `-d:console` makes a console build (3).
- **File dialogs**: SDL 3.4 uses the system's `IFileDialog` (the Explorer
  dialog with the navigation pane, in the system's light or dark mode), and
  `FOS_PICKFOLDERS` for folders; the old common dialog only if that fails.
- **Shortcuts**: the menus show `Ctrl+O`, `Ctrl+Shift+Z` on Windows and Linux
  (Dear ImGui shows `Cmd` on macOS and matches it there).
- **Visual styles** for the tray menu and native dialogs (Common Controls 6
  in the manifest); the tray menu follows Windows' dark mode (SDL).

## Proposed, not done

- **The UI font.** viewSEG draws its interface in JetBrains Mono Nerd Font
  Propo, bundled: the program's own look on every system, with the icons in
  the same font, and the layouts measured with it. Windows' own interface
  font is Segoe UI Variable (11) or Segoe UI (10). A theme can use it now,
  with no code change: `[fonts]` with `ui = "C:/Windows/Fonts/segoeui.ttf"`,
  `heading = "C:/Windows/Fonts/segoeuib.ttf"` and
  `icons = "JetBrainsMonoNerdFontPropo-Regular.ttf"` (the icons merged from
  the bundled font). Segoe UI Variable (`SegUIVar.ttf`) is a variable font,
  which the font loader reads at its default weight only. Proposal: keep the
  bundled font as the default; if Segoe UI looks better to you, a shipped
  "Windows" theme variant (or a font setting) is a small task.
- **Icons at 125 %**: the icon file has no 20 and 40 pixel images, so Windows
  scales the 24 and 48 pixel ones there. Hand-drawn 20 and 40 pixel images
  would be sharper; add them to `res/viewSEG.ico`.
- **The tray icon's size**: SDL loads it with `LoadIcon` (32 pixels, scaled
  by the shell to 16 or 24). Sharp enough; `LoadIconMetric` in SDL would be
  exact (an upstream change).
- **The first frame**: the main window is shown before the theme is loaded,
  so for a moment its title bar is SDL's (the system's light or dark), then
  the theme's. Showing the window only after its first frame would hide
  that.
- **Windows' accent colour**: a theme could take Windows' accent colour (the
  colour of focus, links and the current tab) instead of its own: an option
  for the theme files, later.

## What to check on Windows

Use a copy with its `assets/` folder next to it (the package from `dist/`,
or `bin/viewSEG.exe` with `assets/` beside its `bin/` folder). For a first
start, use a fresh portable copy (an empty `config/` folder next to the
executable) or `viewSEG.exe --reset-windows`.

1. **Start**: no console window. The title bar has the theme's colours
   (Everforest Dark: bar `#21272c`, title `#d3c6aa`, border `#475258`) and
   round corners on Windows 11; dark on Windows 10 with a dark theme.
   Messages says "Window frames: Windows 11 (build ...)" or "Windows 10".
2. **View > Theme**: a light theme, then a dark one: the title bar changes at
   once, without clicking elsewhere or resizing (Windows 10 especially).
3. **Windows' light/dark switch** (Settings > Personalization > Colors), with
   the theme on Follow system: viewSEG and its title bar follow; with a fixed
   theme the title bar keeps the theme's mode.
4. **Windows' accent colour** (Settings > Personalization > Colors > Accent
   color), with a light viewSEG theme on a dark Windows: the title bar stays
   light, and its minimize, maximize and close buttons stay dark on light
   (Windows 10: the bar must not turn dark).
5. **A panel dragged out** of the main window (the Map's tab, out past the
   edge): its window has square corners and one border, no white flash when
   it opens. A menu or tooltip that goes past the main window's edge: square,
   no Windows border around it.
6. **Icons**: sharp in the title bar, the taskbar and Alt+Tab at 100 %, 125 %
   and 150 %; still sharp after moving the window to a monitor of another
   scale.
7. **Tray**: the icon is in the notification area (perhaps under the `^`
   overflow); a left or right click opens the menu Show viewSEG, Open
   file..., Quit, dark when Windows is dark. Open file... opens the file
   dialog over the window.
8. **Window > Minimize to the tray**: minimize: the window and any dragged-out
   panels leave the taskbar; the tray's Show viewSEG brings them back, still
   maximized if they were.
9. **Quit** from the tray, from File > Quit and by closing the window: the
   icon is gone at once (pass the pointer over where it was).
10. **The first window** on a 1080p laptop at 150 %: maximized; on a 4K laptop
   at 150 %: a large window (1920 x 1200 pixels) in the middle.
11. **File > Open file / Open folder**: the Explorer dialog with the
    navigation pane, in Windows' mode.
12. Anything that still looks like a non-Windows program: say what and where.
