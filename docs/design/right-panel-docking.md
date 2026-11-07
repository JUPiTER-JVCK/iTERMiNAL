# Design: tiling the right-hand panels

Status: **implemented** in two changes: PR 1 (#86: arrangement, Move and Fill
menu, persistence) and PR 2 (dragging a panel's header to re-dock it). Kept as
the design record; see *What shipped differently* at the end.

## Goal

The region down the right showed one panel at a time, behind a strip of tabs.
Browser, Files, Notes, the HTTP client and the two bundled tools should instead
be arrangeable the way a code editor's panes are: beside or below one another,
moved to any edge, and made to fill the region or the whole window — without
losing what they hold, and remembered across launches.

Out of scope: the terminal area, the bottom dock, more than one copy of a
panel, and panels in a window of their own.

## What exists today

- `RightPanelView` drew one panel, `store.visiblePanel`, under a strip of
  `PanelTabChip`s. `openPanels` was a `Set<SidePanel>`; order was the enum's.
- The region's width is one number, `AppSettings.rightPanelWidth`, dragged with
  `PanelResizeHandle`, which also holds terminals at their size
  (`SeamDrag`) so btop and superfile are not resized every frame.
- The panels' state is on the store (`panelBrowserTabs`, `panelFiles`,
  `panelNotes`, `panelHTTPClient`, `toolSessions`), not in the views. The
  browser's `WKWebView` and a tool's terminal are AppKit views, which have one
  superview; moving a SwiftUI view to a new parent rebuilds it.
- `state.json` is decoded all-or-nothing and has no version field.

## Approach

### An arrangement is a tree

`DockLayout.swift` (Foundation only, like `TabOrder`): a `DockNode` is a panel
(`.leaf`) or a split along an axis whose children carry a weight each. Every
edit — insert beside a panel or along a region edge, remove, move, swap, resize
— takes a tree and returns one in normal form: at least two children per split,
no split directly inside one of the same axis, weights that are positive and sum
to 1, each panel once. `DockGeometry.swift` lays a tree out in a rectangle,
works out the region's minimum size, applies a divider drag, and picks the side
for a newly opened panel. Both are checked in `scripts/input-logic-check`.

Leaves are `SidePanel` raw values, so the files do not import SwiftUI.

### One flat list, not nested split views

`DockRegionView` computes every panel's rectangle from the tree and draws all of
them as siblings in one `ZStack`, keyed by panel, with a frame and an offset.
Nested `HSplitView`s would put a panel at a different depth for each
arrangement, and SwiftUI treats a view at a new place as a new view: the browser
would reload and a tool would be handed a fresh terminal each time one was
moved. Here a move changes a rectangle.

Dividers are drawn after the panels so their grab area is above the web view or
terminal beside them. Each is the existing `PanelResizeHandle`; the arrangement
being dragged is local `@State` and the store is written once, when the drag
ends.

A fill takes the other panels out of the tree while it lasts, as switching tabs
did. Their models and any tool process stay alive.

### Store

`openPanels` is now read off `dockLayout`, so the two cannot disagree, and the
`didSet` that stops a tool when its panel goes is on `dockLayout`. `dockFill` is
the panel standing alone, or nil. It is independent of `rightPanelExpanded`:

| | `dockFill` | `rightPanelExpanded` |
|---|---|---|
| tiled | nil | false |
| fill region | the panel | false |
| fill window | the panel | true |

The existing methods keep their names and meanings (`ScreenshotScenes` calls
them and is only compiled by the manual screenshots workflow).

A new panel goes beside the one in front if that panel is at least 720pt wide
and both fit at their minimums, otherwise below it (`DockLayout.smartEdge`).
The default region is narrower than 720, so panels stack there.

Minimum sizes live on `SidePanel.dockMinimum`. A tool's 640pt width still sets
the region's floor, and several tiled side by side add up, which can exceed the
1200pt cap on the region's width — the range handed to the region's own resize
handle is clamped so that is not a trap.

### Persistence

`PanelStateSnapshot` gains two optional fields, `dockLayout` and `dockFill`.
`openPanels` and `frontPanel` are still written, so a file from this build still
reads in an older one (which shows the panels as tabs).

`DockLayoutField` decodes without ever throwing: a layout that is malformed, or
from a newer version, is "no layout", and the arrangement is rebuilt from
`openPanels`. A file from before tiling gets the same rebuild: the open panels in
a column, the one that was in front first, filling the region — so an upgrade
looks the same, and tiling is a choice from the menu.

### Menu

The ··· button in a panel's header opens Move (left, right, top, bottom edge of
the region) and Fill and arrange (tiled, fill region, fill window). It appears
once two panels are open. There is no new keyboard shortcut; "Reset Panel
Layout" is a command-palette row only.

## Implementation order

1. `DockLayout` and `DockGeometry`, with checks. *(PR 1)*
2. Snapshot fields, store, restore and migration. *(PR 1)*
3. `DockRegionView`, and `RightPanelView` as a wrapper over it. *(PR 1)*
4. The Move and Fill menu, and the palette row. *(PR 1)*
5. Drag a panel's header onto another panel's edge. *(PR 2)*

### Dragging a panel's header

A `DragGesture` on the title and the room after it (it takes 6 points of
movement to start, so a click still brings the panel to the front), rather than
SwiftUI's `draggable` / `dropDestination`: the web view and the terminal
register their own drag types and can swallow a drop meant for SwiftUI, and a
gesture that began on the header keeps receiving the pointer wherever it goes.
The gesture reports the pointer in the window's coordinates and the region
subtracts its own origin, read the same way, so both are in one space.

Where a panel would land is a pure function, `DockLayout.dropTarget`, checked
off a Mac. From the pointer's place in the region:

- Within 16 points of the region's edge: along that whole side
  (`.regionEdge`). This wins even over the dragged panel's own area, so a panel
  can be sent to a side from wherever it is.
- Otherwise over some other panel (the seam between two counts as the one beside
  it): within a band of its edge, a third of its width or height but at most 96
  points, it goes beside that panel on that side (`.beside`), and near two sides
  it goes to the one it is further into the band of; in the middle it swaps
  places (`.swap`).
- Over the dragged panel, or outside the region: nowhere.

`DockLayout.dropping` carries a target out with the same `moving` / `swapping`
the Move menu uses, so a drag and a menu choice end in the same arrangement, and
`dropHighlight` gives the area to light.

`DockDragModel` holds the drag and is kept in `@State` by the region, which keeps
it without watching it; only `DockDropOverlay` observes it, so the pointer moving
redraws a highlight and a ghost of the title, not the panels. The overlay dims the
dragged panel, lights the target in the accent colour, and is never hit-tested.
Escape cancels while a drag is under way, by a local key monitor that exists only
for the length of a drag, so it reaches the terminal the rest of the time; the
region resets the model if it goes away mid-drag.

Only a panel with a header of its own can be dragged — that is, when two or more
share the region. A lone panel, or one filling the region, has the strip of tabs.
The Move menu stays as the way to arrange without a pointer.

## Known limits

- Dragging needs a pointer. The Move menu does the same without one.
- Which panel is in front follows clicks, headers, opening a panel and a tool's
  terminal taking focus. It does not follow the keyboard: tabbing into a panel, or
  a shortcut that moves focus there, leaves the one that was in front as it was.
  It only matters for which panel the next one opens beside.
- Heights in `SidePanel.dockMinimum` are a first guess, to be tuned by eye.

### Which panel is in front

A panel opened next goes beside the one in front, and a panel's header is brighter
when it is. The first version set it from a header's tap, from opening a panel and
from a tool's terminal taking focus, and left a click inside the browser, Files,
Notes or the HTTP client doing nothing. SwiftUI gestures cannot hear a click inside
the browser's web view or a terminal, which take the mouse themselves, so
`DockClickFocus` does it the other way: each panel carries an invisible AppKit view
behind it, filling its rectangle (`DockLeafMarker`), and one local monitor on the
app's mouse-downs asks which of those rectangles the click fell in, in the window's
own coordinates, and calls `focusPanel`. The monitor only listens, so the click goes
on to what it was aimed at, and it exists only while the region is on screen.

## What shipped differently

- PR 1: the plan was to guard `closeFocusedPane` so a tool hidden by a fill would
  not capture ⇧⌘W. That would have closed the whole tab when focus was stale, so
  the store instead releases focus from a tool when a fill hides it, and
  `closeFocusedPane` is unchanged.
- Which panel is in front: PR 1 documented the gap as "a click inside the browser's
  web view", which understated it; a click in Files, Notes or the HTTP client did
  nothing either. Fixed in a later change (see above).
- PR 2: the plan had the drag in the region's named coordinate space. It reads the
  pointer in the window's coordinates instead and subtracts the region's origin,
  since nothing in the codebase had used a named space with `DragGesture` and a
  compile cost a cycle to find out.
