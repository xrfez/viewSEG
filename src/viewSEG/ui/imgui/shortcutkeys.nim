## A shortcut row's chord token (`core/shortcuts`) as a Dear ImGui chord, so
## handling code can test the key the table names instead of typing it again.

import std/strutils
import imguin/cimgui
import ../../core/shortcuts

func imguiKey*(name: string): ImGuiKey =
  case name
  of "F": ImGui_Key_F
  of "K": ImGui_Key_K
  of "R": ImGui_Key_R
  of "M": ImGui_Key_M
  of "P": ImGui_Key_P
  of "G": ImGui_Key_G
  of "C": ImGui_Key_C
  of "Backspace": ImGui_Key_Backspace
  of "Escape": ImGui_Key_Escape
  of "Enter": ImGui_Key_Enter
  of "F1": ImGui_Key_F1
  else: ImGui_Key_None

func imguiChord*(token: string): cint =
  ## `token` ("F", "Ctrl+G", "Escape") as a key chord. 0 when it names no key.
  var rest = token
  var mods = 0
  if rest.startsWith("Ctrl+"):
    mods = mods or ImGui_Mod_Ctrl.cint
    rest = rest.substr("Ctrl+".len)
  if rest.startsWith("Shift+"):
    mods = mods or ImGui_Mod_Shift.cint
    rest = rest.substr("Shift+".len)
  if rest.startsWith("Alt+"):
    mods = mods or ImGui_Mod_Alt.cint
    rest = rest.substr("Alt+".len)
  let key = imguiKey(rest)
  if key == ImGui_Key_None: 0.cint else: cint(mods) or key.cint

proc pressed*(id: string; flags: cint = 0): bool =
  ## Whether row `id`'s chord was pressed. `flags` are Dear ImGui's input
  ## flags (repeat, routing); 0 is the focused window, once.
  let chord = imguiChord(chordOf(id))
  if chord == 0: return false
  igShortcut_Nil(chord, flags)

proc plotShortcut*(chord: cint; flags: cint; over: bool): bool =
  ## `chord` for the plot. While it has the focus, the focused route. While
  ## the pointer is over it and a menu click left the focus on another
  ## window, the key still acts on the plot.
  if chord == 0: return false
  var route = flags
  if over and not igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
    route = route or ImGui_InputFlags_RouteGlobal.cint or
      ImGui_InputFlags_RouteOverFocused.cint
  igShortcut_Nil(chord, route)

proc plotPressed*(id: string; over: bool; flags: cint = 0): bool =
  ## Row `id`'s chord for the plot: the focused route, or, while the pointer
  ## is over the plot, even if a menu click left the focus elsewhere.
  plotShortcut(imguiChord(chordOf(id)), flags, over)
