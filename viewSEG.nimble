# Package

version       = "0.1.0"
author        = "Joshua Fenner"
description   = "High-performance SEG-Y / SEG-D viewer built on parseSEG and processSEG"
license       = "MIT"
srcDir        = "src"
bin           = @["viewSEG"]


# Dependencies

requires "nim >= 2.4.0"
requires "https://github.com/xrfez/parseSEG >= 0.11.0"
requires "https://github.com/xrfez/processSEG >= 0.4.0"
