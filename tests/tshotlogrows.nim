## Which rows the Shot log grid marks, lists and scrolls to (`view/shotlogrows`), as the
## Headers window's Trace tab follows the pointer: the selection first; with none, and
## "Follow the pointer" on, the pointer's rows; with it off only the selection, and the
## grid never scrolls by itself. "Only selected" lists the selected rows that the other
## filters leave in, and filtering never changes the selection.
##
## Seen to fail: with the selection used only past a hundred rows, `selection_first`
## took the pointer's row; with `scrollsTo` ignoring the option, `off_never_scrolls`
## scrolled with it off; with `onlySelected` not asking the other filters,
## `only_selected_and_filters` listed row 7. With `nextShown` taking `col + 1`,
## `tab_skips_a_hidden_column` landed on the ignored column 4.

import viewSEG/view/shotlogrows

proc main*() =
  block selection_first:
    let c = chosenRows([4, 2, 4], [9], true)
    doAssert c.by == rbSelection and c.rows == @[2, 4], $c
    doAssert c.isChosen(2) and not c.isChosen(9)

  block pointer_only_with_the_option:
    doAssert chosenRows([], [9, 8], true).rows == @[8, 9]
    doAssert chosenRows([], [9, 8], true).by == rbPointer
    doAssert chosenRows([], [9], false).by == rbNone
    doAssert chosenRows([3], [9], false).rows == @[3], "the selection shows with it off"

  block off_never_scrolls:
    let a = chosenRows([3], [], false).scrollKey(1)
    let b = chosenRows([5], [], false).scrollKey(2)
    doAssert not scrollsTo(a, b, false), "a changed selection moved the grid with it off"
    doAssert scrollsTo(a, b, true)
    doAssert not scrollsTo(b, b, true), "an unchanged choice scrolled again"
    doAssert not scrollsTo(a, chosenRows([], [], true).scrollKey(0), true)
    # the same row chosen again by another click is a change
    doAssert scrollsTo(chosenRows([5], [], true).scrollKey(2),
      chosenRows([5], [], true).scrollKey(3), true)

  block tab_skips_a_hidden_column:
    # the columns shown when column 4 is ignored: Tab never lands on it
    let shown = [0, 1, 2, 3, 5, 6]
    doAssert nextShown(shown, 3) == 5
    doAssert nextShown(shown, -1) == 0 and nextShown(shown, 0) == 1
    doAssert nextShown(shown, 6) == -1, "past the last shown column"
    doAssert nextShown([], 0) == -1
    doAssert nextShown([2, 5], 2) == 5 and nextShown([2, 5], 3) == 5

  block only_selected_and_filters:
    let rows = onlySelected([7, 2, 2, 50], 10, proc (r: int): bool = r == 7)
    doAssert rows == @[2], $rows
    doAssert onlySelected([], 10, proc (r: int): bool = false).len == 0
    doAssert countText(2, 1200) == "2 of 1200 rows" and countText(1, 1) == "1 of 1 row"

when isMainModule:
  main()
