## What the map's Layers list is made of, as the settings keep it: the
## groups its layers are in. A module of its own, without dependencies, so
## that the settings (`core/settings`) and the map's state (`core/mapstate`)
## both name them.
##
## **Groups.** The survey files (SPS, SEG P1) are the **Preplot**: the
## sources and receivers the survey planned. What the seismic files say of
## themselves (their traces' own positions, as their headers give them or
## as a join with the survey files made them) is **Recorded**. Planned
## against recorded reads at a glance; each group is shown or hidden as
## one, and each of its layers on its own.

type
  MapGroup* = enum
    ## A group of the map's layers.
    mgPreplot = "Preplot"
      ## the survey files: the sources and receivers the survey planned
    mgRecorded = "Recorded"
      ## what the seismic files say: their traces' own positions
