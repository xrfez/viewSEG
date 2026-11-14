# viewSEG quick start

viewSEG is a viewer for SEG-Y and SEG-D seismic data with quality-control tools. It needs
no installation and no internet connection.

**Status:** early development. The window, the File menu, the folders below, and one
record on screen as wiggles or greyscale density, with zoom, pan, gain, sorting and a
cursor readout, work.

## Start it

1. Unpack the archive anywhere you can write to: your home folder, a project drive or a USB
   stick.
2. Run the program in the unpacked folder:
   - Windows: `viewSEG.exe`;
   - Linux: `./viewSEG`.

It needs a 64-bit PC with AVX2 (Intel from 2013, AMD from 2017) and OpenGL 3.3.

If it cannot start, for example because the graphics driver has no OpenGL 3.3, a message
box says what failed, and the same text is saved as `startup-failure.log` in the logs
folder (`viewSEG --paths` shows where it is).

## Open data

**File** menu, or the shortcuts:

| Action | Shortcut |
|---|---|
| Open a file | Ctrl+O |
| Open several files | Ctrl+Shift+O |
| Open a folder | Ctrl+Alt+O |
| Quit | Ctrl+Q |

## Look at a record

An opened file shows its first record in the Plot window: traces across, time down, as
black wiggles with their positive lobes filled, on white paper, with automatic gain (AGC
on shot and receiver records). Where the traces are closer together than 4 pixels (a
whole shot of a few thousand traces, say), the plot shows greyscale density instead, and
says so in the strip ("density: traces under 4 px"); zoom in on the traces to see the
wiggles. The row of labels over the traces is the display header (receiver line and point
by default).

| To | Mouse | Keys |
|---|---|---|
| Zoom in or out about the pointer | wheel | `+` / `-` |
| Zoom in time only | Ctrl + wheel | Ctrl + Up / Down |
| Zoom across the traces only | Shift + wheel, or the sideways wheel | Ctrl + Right / Left |
| Pan | drag with the left or middle button | arrows (a tenth of the view; with Shift, a whole view) |
| Pan with a scroll bar | drag its thumb; click the bar for a whole view; or the wheel over it | |
| Zoom to a box | drag with the right button | |
| Fit the whole record | the fit button | Ctrl+0 |
| Go back to the view before | the back button | Backspace, or Alt+Left |
| Cancel a drag | | Esc |

Keys act while the Plot window has the focus: click in it first.

**Display.** The first buttons in the strip choose how traces are drawn: greyscale
density, wiggles, or wiggles over density. The two after them fill the wiggles' positive
lobes (right of the trace) and negative lobes (left of it): either, both or none. The
settings button (the gear) holds the **trace overlap**, how far the strongest amplitudes
swing a trace, in trace spacings (1 reaches the next trace; anything stronger is clipped
there), and the colours: paper (black on white; negative fills red), the theme's colours,
or your own.


**Gain.** The drop-down in the strip picks the gain type, and its settings are in the
same list: Automatic (AGC on shot and receiver records, none on stacked data), None,
Fixed (one scale for every record, so records compare), Normalized (every trace, or the
record, to the same level), Exponential (more gain later in the record: dB per second,
or a power of time), Float (the scale follows what is in view) and AGC. Beside it, the
gain amount in dB works with every type: type a value, click - or +, or press `]` and
`[` (keypad `*` and `/`); the picture brightens or darkens at once.

The view never goes past the data: panning and zooming stop at the first and last trace
and at the record's start and end, and zoomed out as far as it goes the record fills the
plot. Whenever part of the record is out of view, a scroll bar shows how much and where:
under the plot for the traces, right of it for the time. The time axis shows the times
only; its unit is in the ms/in box and in the status bar. Making the window larger or
smaller keeps the scale and shows more or less of the record, from the same top-left
corner (an axis that showed the whole record goes on showing all of it).

**Sort.** Three buttons in the strip put the traces in another order: **Line/Station**
(receiver line, then station), **By Flag** (the same, with each station's components side
by side, in order) and **By Component** (the traces grouped by component, each group by
line, then station). The button of the order in use is highlighted; click it again for
the file's order. For an order of your own, right-click the plot and choose **Sort by
keys...**: pick the header fields to sort by, the first first, each ascending or
descending, and click Sort. Sorting never changes the file, and the display header and
the status bar follow the order shown.

**Scales.** The two boxes over the plot state the zoom as traces per inch and ms per inch.
Type a value and press Enter to set it; zooming any other way updates them. The settings
button (the gear) switches to per cm, or time as inches per second, and calibrates the
screen: the scales assume 96 pixels per inch times the display scale until you enter the
monitor's diagonal or make a bar on the screen as long as a ruler held to it says.

**Readout.** The status bar along the bottom reads out what lies under the pointer: the
time, the trace and channel, receiver and source line and point, FFID, offset, the
amplitude as displayed, and the record's UTC time. Right-click the status bar to choose
the fields and their order.

## The folders next to the program

| Folder | What it holds |
|---|---|
| `config/` | your settings, and your own vendor header maps in `config/vendormaps/` |
| `logs/` | one log file per session |
| `vendormaps/` | the vendor header maps that ship with viewSEG |
| `assets/` | themes, fonts and colour maps |
| `licences/` | the licences of viewSEG and of the software it includes |
| `docs/` | this guide |

While `config/` exists and can be written to, viewSEG keeps everything inside its own folder
(portable mode). Without it, viewSEG uses your per-user folders; `config/README.md` lists
them.

## Command line

```
viewSEG --version     the version
viewSEG --paths       the folders in use (settings, logs, cache, assets, vendor maps)
```

On Windows these print only when the output is redirected, for example
`viewSEG.exe --paths > paths.txt`.

## Vendor header maps

Manufacturer-specific header blocks are decoded by vendor header maps (`*.nif` files). Put
your own in `config/vendormaps/`; `vendormaps/README.md` explains what they are.
