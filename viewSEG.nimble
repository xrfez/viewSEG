# Package

version       = "0.1.0"
author        = "Joshua Fenner"
description   = "High-performance SEG-Y / SEG-D viewer built on parseSEG and processSEG"
license       = "MIT"
srcDir        = "src"
bin           = @["viewSEG"]


# Dependencies

requires "nim >= 2.4.0"
requires "https://github.com/xrfez/parseSEG >= 0.15.0"
requires "https://github.com/xrfez/processSEG >= 0.6.0"
requires "https://github.com/dinau/imguin >= 1.92.9.0"
requires "https://github.com/dinau/sdl3_nim >= 3.4.18.0"
