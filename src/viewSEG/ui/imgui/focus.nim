## The click that brings a window forward does only that: a click selects a
## trace, shows a file or shows a record only in a window that already had
## the keyboard focus when the mouse button went down.
##
## Dear ImGui focuses a window as soon as a button goes down over it, so by
## the time the window's own code runs, a window just clicked into is
## focused already. `FocusClicks` keeps whether it was focused at the end of
## the frame before, and latches that when a button goes down over it.
##
## Use: `watch` right after `igBegin` (inside the window), `acts` where a
## click would act, `settle` just before `igEnd`.

import imguin/cimgui

type
  FocusClicks* = object
    ## Whether a window's clicks may act.
    before: bool  ## the window had the focus at the end of the last frame
    pressed: bool ## it had it when a mouse button last went down over it

proc watch*(fc: var FocusClicks) =
  ## Notes a press over the window this frame, and whether the window had
  ## the focus before it. Call right after `igBegin`.
  const flags = ImGui_HoveredFlags_RootAndChildWindows.cint or
    ImGui_HoveredFlags_AllowWhenBlockedByActiveItem.cint
  if igIsWindowHovered(flags):
    for b in [ImGui_MouseButton_Left, ImGui_MouseButton_Right, ImGui_MouseButton_Middle]:
      if igIsMouseClicked_Bool(b.cint, false): fc.pressed = fc.before

func focused*(fc: FocusClicks): bool {.inline.} = fc.before
  ## Whether the window had the focus at the end of the last frame.

func acts*(fc: FocusClicks): bool {.inline.} = fc.pressed
  ## Whether the click going on (pressed this frame, or released this frame
  ## after a press over the window) started in a window that had the focus.

proc settle*(fc: var FocusClicks) =
  ## Notes whether the window has the focus now. Call just before `igEnd`.
  fc.before = igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint)

proc blur*(fc: var FocusClicks) =
  ## Forgets a focus the window no longer has. Call when it is not drawn.
  fc.before = false
  fc.pressed = false

proc handBack*(wasOpen: var bool; open: bool; title: string) =
  ## A modal opened from the window titled `title` was drawn this frame
  ## (`open`: it is showing). When it has just closed, the window that asked
  ## gets the focus back and comes to the front, not whichever window ImGui
  ## picks. Keep `wasOpen` with the window's state.
  if wasOpen and not open: igSetWindowFocus_Str(title.cstring)
  wasOpen = open
