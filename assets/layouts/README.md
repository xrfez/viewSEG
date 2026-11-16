# Layouts

A layout is how the windows are arranged: where each is docked and how large, which float
and where. Each `.nif` file here is a preset that ships with viewSEG; the *Window* menu
lists them:

- **Wide plot:** the Files window over the Records window and the Map at the left; the
  Seismic window across the rest of the width, the Headers, Jobs and Messages windows as
  tabs under it.
- **Side by side:** the Files window over the Records window at the left, the Seismic
  window at full height beside them, the Map (the Headers window a tab beside it) over the
  Jobs and Messages windows at the right.
- **Plot and map:** the Files window over the Records window at the left; the Seismic
  window and the Map side by side, as large as each other, the Headers, Jobs and Messages
  windows as tabs under them.

A layout saved before the Map came names no map: the Map then joins the Headers window's
place.

*Window > Save layout as...* keeps the arrangement on screen under a name of your own, in
`<config>/layouts/<name>.nif` (`viewSEG --paths` prints `<config>`); a layout of yours with
the name of a preset hides the preset. *Window > Reset the windows* puts the windows back
as they are at a first start, and *File > Export > Export layout...* and *File > Import >
Import layout...* write and read a layout file anywhere, to take it to another computer.
The arrangement when viewSEG closes is kept in `<config>/layout.nif` and restored at the
next start.

A layout file holds Dear ImGui's own layout text as a string, in a small NIF document. It
names each window by an identity of its own, not by its title (the Seismic window is
`plot`), so a layout keeps working when a window is named anew:

```
(.nif27)
(.vendor "viewSEG")
(layout
 (version 1)
 (name "Wide plot")
 (imgui "..."))
```
