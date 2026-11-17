# Your vendor header maps

Put your own vendor header maps (`*.nif`) here. viewSEG searches this folder first, before
the maps that ship in the release's `vendormaps/` folder: when one of your maps and a
shipped map fit a file equally well, yours is used.

See `vendormaps/README.md` next to the program for what a vendor header map is.
`vendormaps/WRITING-A-MAP.md` there is the guide to writing one. A map dropped here while
viewSEG runs is read when you choose File > Reload vendor maps.
