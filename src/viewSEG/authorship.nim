## Who wrote viewSEG, in one place: Help > About, agent control's `state` and the
## Windows version information (`platform/winres`) all use these strings. No
## imports beyond the standard library, so every layer may use it. The licence is the
## repository's own LICENSE file, read at compile time so the two cannot drift.

import std/strutils

const
  ProgramAuthor* = "Joshua Fenner"
  AuthorEmail* = "Joshua.R.Fenner@gmail.com"
  CopyrightYear* = "2026"
  CopyrightLine* = "Copyright © " & CopyrightYear & " " & ProgramAuthor
  RepositoryUrl* = "https://github.com/xrfez/viewSEG"
  LicenseText* = staticRead("../../LICENSE").strip.replace("\r\n", "\n")
    ## the whole licence

func licenseDisclaimer*(text: string): string =
  ## The warranty paragraph of an MIT licence ("THE SOFTWARE IS PROVIDED ..."), on one line;
  ## "" when `text` has none.
  let at = text.find("THE SOFTWARE IS PROVIDED")
  if at >= 0: text[at .. ^1].splitWhitespace.join(" ") else: ""

const LicenseDisclaimer* = licenseDisclaimer(LicenseText)
