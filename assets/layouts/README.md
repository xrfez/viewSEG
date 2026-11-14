# Layouts

A layout is how the windows are arranged: where each is docked and how large, which float
and where. Each `.nif` file here is a preset that ships with viewSEG; *View > Layout >
Load* lists them under "Presets":

- **Wide plot:** the Files window over the Records window at the left; the Seismic window
  across the rest of the width, the Headers, Jobs and Messages windows as tabs under it.
- **Side by side:** the Files window over the Records window at the left, the Seismic
  window at full height beside them, the Headers window over the Jobs and Messages windows
  at the right.

*View > Layout > Save as...* keeps the arrangement on screen under a name of your own, in
`<config>/layouts/<name>.nif` (`viewSEG --paths` prints `<config>`); a layout of yours with
the name of a preset hides the preset. *Reset* puts the windows back as they are at a first
start, and *Export...* and *Import...* write and read a layout file anywhere, to take it to
another computer. The arrangement when viewSEG closes is kept in `<config>/layout.nif` and
restored at the next start.

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
