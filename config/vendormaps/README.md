# Your vendor header maps

Put your own vendor header maps (`*.nif`) here. viewSEG searches the open project's
`vendormaps` folder first, then this one, then the maps that ship in the release's `vendormaps`
folder beside the program: of two maps of one name the earlier folder's is used, and when two
maps fit a file equally well, the one found first.

See `vendormaps/README.md` next to the program for what a vendor header map is.
`vendormaps/WRITING-A-MAP.md` there is the guide to writing one. A map dropped here while
viewSEG runs is read when you choose File > Reload vendor maps.
