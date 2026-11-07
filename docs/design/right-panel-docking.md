# Design: tiling the right-hand panels

Status: **PR 1 implemented** (arrangement, Move and Fill menu, persistence).
**PR 2 not started** (dragging a panel's header to re-dock it). Kept as the
design record; update *What shipped differently* when either lands.

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

### PR 2: dragging

A `DragGesture` on the header's title, in the region's coordinate space, rather
than SwiftUI's `draggable` / `dropDestination`: the web view and the terminal
register their own drag types and can swallow a drop meant for SwiftUI, and a
gesture that began on the header keeps receiving the pointer wherever it goes.
A ghost of the header follows the pointer, and the zone under it — an edge band
of the panel beneath, its centre, or a strip along the region's edge — is
highlighted from a pure `DockLayout.dropTarget`. Releasing commits through the
same `moving` / `swapping` the menu uses; Esc cancels. It is off while one panel
is on screen.

## Known limits

- A click inside the browser's web view does not reach the store, so it does not
  make Browser the panel in front. The browser becomes the focused panel through
  its header, or by being opened; a tool becomes it by taking focus. This only
  matters for which panel the next one opens beside.
- Heights in `SidePanel.dockMinimum` are a first guess, to be tuned by eye.

## What shipped differently

*(To be filled in when the pull requests land.)*
