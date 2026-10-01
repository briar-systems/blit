# blit

An immediate-mode GUI library in Mach.

Widgets accumulate a draw list of colored, textured triangles and report
interaction. The consumer feeds input each frame, runs the widgets, and uploads
and renders the resulting vertices — blit stays out of the windowing and
rendering.

```mach
use blit;

# once, at startup (fallible calls return err[allocator.Error]):
val made: err[allocator.Error] = blit.context.init(?ctx, ?a);
if (sel made.err) { ... }

# per frame:
blit.context.begin(?ctx, in, screen_w, screen_h);
val panel: blit.widget.Block = blit.widget.begin_panel(?ctx, 8.0::f32, 8.0::f32, 200.0::f32);
blit.widget.text(?ctx, "controls");
if (blit.widget.button(?ctx, "step")) { ... }
blit.widget.checkbox(?ctx, "running", ?running);
blit.widget.slider_f(?ctx, "rate", ?rate, 0.0::f32, 1.0::f32);
blit.widget.end_panel(?ctx, panel);
blit.context.end(?ctx);
# upload the atlas pages that changed (see Rendering), then
# blit.context.draw_verts(?ctx) / draw_count(?ctx), and draw as triangles.
```

`use blit;` binds the surface; reach everything through its submodule:
`blit.draw`, `blit.glyph`, `blit.bitmap`, `blit.font`, `blit.atlas`,
`blit.input`, `blit.hit`, `blit.field`, `blit.theme`, `blit.context`, `blit.text`, `blit.widget`, `blit.chart`. A submodule can also be
imported directly, e.g. `use w: blit.widget;`.

## Text & glyph sources

Text comes from glyph sources, records of functions over each source's own
state (`blit.glyph.GlyphSource`). blit owns UTF-8 decoding, line breaking, the
glyph cache and the atlas, and asks a source only for what a face knows:

```mach
pub rec GlyphSource {
    self:   ptr;
    line:   fun(ptr, f32) LineMetrics;                        # (self, scale)
    glyph:  fun(ptr, u32, f32, *Glyph) bool;                  # (self, glyph id, scale, out)
    kern:   fun(ptr, u32, u32, f32) f32;                      # (self, left id, right id, scale), or nil
    raster: fun(ptr, u32, f32, *u8, usize) bool;              # (self, glyph id, scale, coverage, stride)
    shape:  fun(ptr, *u32, usize, f32, *Shaped, usize) usize; # (self, run, n, scale, out, cap), or nil
}
```

- **Glyph ids, with an optional shaper.** Everything past shaping is keyed on
  glyph id. A shaping source (ligatures, combining marks, complex scripts)
  turns a line's codepoints into `Shaped` glyphs: an id, the cluster it came
  from, an advance with kerning included and an offset. A source with `shape`
  nil has glyph ids that are its codepoints, one to one, kerned pair by pair
  through `kern`, as the bitmap font and a simple TrueType face do. Such a
  source only adds `shape: nil` to the record it filled before.
- **Metrics are floats** in pixels at the scale asked for: `LineMetrics` is
  ascent, descent and gap, and a `Glyph` is its advance, the rect its bitmap
  covers relative to the pen on the baseline (y down), and the bitmap's size in
  texels. Scale is a text style's size times the interface scale (`ctx.scale`,
  1.0 by default), so text at 200% is rasterised at that size, not stretched.
- **Glyphs come on demand.** A glyph is measured the first time it is laid
  out and rasterised the first time it is drawn, then cached by source, glyph
  id and scale. Measuring never rasterises.
- **Codepoints, not bytes.** Text is UTF-8. A codepoint a non-shaping source
  lacks draws as U+FFFD, or `?` when it lacks that too. A shaper falls back
  itself, its glyph id 0 being the missing glyph. Control codepoints take no
  space and a newline starts the next line.
- **Bitmap by default.** `blit.bitmap.source()`, the built-in 8x8 font, is
  source 0, so a context needs no configuration. `blit.context.set_glyph_source`
  replaces source 0 between frames, such as with a TrueType face from the host,
  and `add_glyph_source` holds more. blit itself never depends on one.
- **The atlas evicts.** When every page is full, the page least recently drawn
  from is cleared and refilled. A page drawn from this frame is never evicted,
  so a glyph drawn this frame is never dropped, and a glyph whose page was
  evicted is rasterised again when it is next drawn.

### Text styles

A style (`blit.font.Style`) names a glyph source and a size relative to that
source's own, so one face serves body text, headings and small print. Style 0,
`blit.font.STYLE_BODY`, is source 0 at size 1.0. Register more with
`blit.context.add_style`, change one with `set_style`, and draw in one with
`push_style`/`pop_style`. Every text call, `text_at`, `text_span`, `glyph`,
`text_width`, `line_height`, and every widget that draws text, uses the
current style, and every frame starts in the body style.

```mach
val heading: opt[u32] = blit.context.add_style(?ctx, blit.font.Style{source: 0, size: 2.0::f32});
blit.context.push_style(?ctx, heading.some);
blit.widget.text(?ctx, "Simulation");
blit.context.pop_style(?ctx);
```

`blit.context.text_width_n` measures a byte range, and `glyph_advance` steps
one codepoint at a time for layout built outside blit, without a shaper's
ligatures.

### Truncation and rich spans

`blit.text.fit` cuts one line to a width with an ellipsis at the end
(`CUT_END`), at the start for paths (`CUT_START`) or in the middle
(`CUT_MIDDLE`), as byte offsets into the caller's string, and `fit_at` draws
it. The ellipsis is U+2026 when the style's source has it, else `...`.

A rich line is a run of `blit.text.Span`s, each text in its own style and
color, on one shared baseline: `spans_at` draws it, `spans_width` and
`spans_line` measure it, and `blit.widget.rich` draws it at the cursor.

```mach
var sp: [4]blit.text.Span;
sp[0] = blit.text.Span{s: "gen ",   style: blit.font.STYLE_BODY, color: t.text_dim};
sp[1] = blit.text.Span{s: "13",     style: bold,                 color: t.text};
sp[2] = blit.text.Span{s: "  pop ", style: blit.font.STYLE_BODY, color: t.text_dim};
sp[3] = blit.text.Span{s: "9,252",  style: bold,                 color: t.text};
blit.widget.rich(?ctx, ?sp[0], 4);
```

## Theme & scale

Every color and length a widget draws with comes from a theme, a plain record
(`blit.theme.Theme`) of colors and unscaled pixel lengths: surfaces (`panel`,
`window`, `dock`, `header`, `header_hot`), `edge`, three text tiers `text`,
`text_dim` and `text_faint` (hints and placeholders),
`accent` and `accent_text` (text on an accent fill), `warn`, control states (`control`, `control_hot`, `control_on`,
`track`, `handle`, `handle_on`), the text selection highlight `select`, and the
metrics `row`, `gap`, `pad`, `handle_w`, `bar_w`, `thumb_min`, `corner`,
`edge_w` and `caret_w`, and for charts a `series` palette of
`blit.theme.SERIES` colors, `grid`, `line_w`, `tick` and `area`. No widget
holds a color or a size of its own.

```mach
var look: blit.theme.Theme = blit.theme.default();
look.accent = blit.draw.rgba(0.37::f32, 0.83::f32, 0.63::f32, 1.0::f32);
look.corner = 3.0::f32;
blit.context.set_theme(?ctx, look);
blit.context.set_scale(?ctx, 2.0::f32);
```

- **Zero configuration.** A context draws with `blit.theme.default()` until
  `set_theme` swaps in another, and `theme_of` hands back the live one to
  adjust in place. `warn` is there for consumers drawing their own content in
  the same palette. No widget uses it.
- **One scale.** `set_scale` multiplies every theme length and the size text is
  laid out and rasterised at (see glyph sources), so 2.0 doubles the whole
  interface, layout and hit rects included, for a HiDPI display or a user's
  choice. Lengths you pass (panel and window widths, dock sizes, your own
  geometry) stay in pixels. `blit.context.px(?ctx, v)` scales them to match.
  `blit.widget.row_gap(?ctx)`, `text_row_height` and `control_row_height`
  report the spacing at the current theme and scale.
- **Rows fit their text.** A control row is `row` tall, or a line of text plus
  `pad` above and below if that is taller, so a larger glyph source never
  overflows its rows.
- **Corners from quads.** `corner` rounds controls and containers with one
  quad per pixel row of each rounded end (`blit.context.fill`), so rounding
  needs nothing of the renderer and clips like any quad. The default is square,
  one quad per rect.

## Docked containers

Alongside floating windows, `blit.widget.begin_dock`/`end_dock` attach a panel
to a screen edge (`blit.context.Side`: left, right, top or bottom). Each dock
takes a strip from the frame's free area, so docks opened in turn stack inward,
and `blit.context.free_area` reports what they leave for the rest of the screen,
such as a world view. Call docks at the root.

A dock's body is a scroll region. `blit.widget.begin_scroll`/`end_scroll` open
one at the layout cursor on its own: its column is clipped and scrolls by the
wheel (`Input.wheel`, pixels, positive turned away from the user) and by a
draggable scrollbar when its content is taller than it. The wheel goes to the
innermost region holding the topmost claim under the cursor.
`blit.widget.section(?ctx, title, ?open)` is a collapsible heading that returns
whether the rows beneath it should be placed.

## Keyboard, focus & text fields

The keyboard is plain data in `Input` like the mouse, so blit still never
touches a window. Each frame the consumer empties it (`blit.input.clear_keys`)
and fills it in arrival order: `type_text(?in, cp)` for each typed codepoint and
`press_key(?in, code, mods)` for each key press or repeat (releases are not
events). A key that types a printable ASCII character is that character, letters
in uppercase (`'A'`, `'7'`, `' '`); every other key is a `KEY_*` constant
(`KEY_ENTER`, `KEY_ESCAPE`, `KEY_BACKSPACE`, `KEY_DELETE`, the arrows,
`KEY_HOME`, `KEY_END`, ...). Modifiers are `MOD_SHIFT`, `MOD_CTRL`, `MOD_ALT`
and `MOD_SUPER` bits, and `blit.input.shortcut(mods)` is ctrl, or super as
darwin's command, without alt. A frame holds up to `EVENT_CAP` events.

- **Focus.** One widget at a time holds the keyboard, by id across frames
  (`blit.context.focus`, `focused`, `unfocus`). A press that lands anywhere
  else takes it back, and so does a frame that does not draw the holder.
  `blit.context.typing(?ctx)` is true exactly while a widget holds it: read it
  before `begin` to keep the consumer's own key bindings quiet for the keys that
  frame will type into a field.
- **Clipboard hand-off.** blit never reads the system clipboard. After `end`,
  `blit.context.copied(?ctx)` is text a copy or cut left for the consumer to put
  on the clipboard (nil when none), and `wants_paste(?ctx)` asks for the
  clipboard's text, which the consumer hands to the next frame as `in.paste`.
- **Text field.** `blit.widget.text_field(?ctx, ?f, hint)` edits a
  `blit.field.Field`: UTF-8 in a buffer the consumer owns, with a caret, a
  selection, a maximum length in characters and a per-field filter.
  ```mach
  var buf:  [64]u8;
  var name: blit.field.Field;
  blit.field.init(?name, ?buf[0], 64, 24, nil); # 24 characters, any printable
  # per frame, inside a panel:
  val did: u8 = blit.widget.text_field(?ctx, ?name, "name");
  if ((did & blit.field.ENTERED) != 0) { ... }
  ```
  A press on the field focuses it and puts the caret under the cursor. It takes
  typed text, backspace and delete, left, right, home and end (shift extends
  the selection), shortcut A to select all, shortcut C, X and V through the
  clipboard hand-off, and enter or escape, which end the edit and give the
  keyboard back. It returns this frame's `EDITED`, `ENTERED` and `ESCAPED` bits.
  The edit model in `blit.field` needs no context, so it can be driven
  directly.

## Clipping & sub-surfaces

Clipping is geometric and CPU-side, so blit stays out of the backend. Push a
clip rect with `blit.context.push_clip(?ctx, x0, y0, x1, y1)` — intersected with
the active rect — and restore it with `pop_clip`. Quads fully outside the rect
are dropped and partial ones are shrunk with their uvs interpolated, and a
clipped-out widget never becomes hot.

`blit.context.begin_surface(?ctx, x, y, w, h, scroll_x, scroll_y)` opens a
clipped region with its own scrolled local coordinate space: emit content and
place widgets at local coordinates, and read the returned `Surface`'s
`local_mx`/`local_my`/`inside` to hit-test custom content against `blit.input`.
Close it with `end_surface`.

Coordinates compose one way:

- **Every rect you pass is local.** Geometry, widgets, `region_clicked`,
  `push_clip` and `begin_surface` all take coordinates in the current local
  space, which is screen space shifted by the current origin. At the root the
  origin is zero, so local and screen coordinates are the same there.
- **Surfaces nest.** A surface's origin is its parent's origin plus
  `(x - scroll_x, y - scroll_y)`, so a surface opened inside another is placed
  relative to the outer surface's content.
- **A child never draws outside its parent.** Clips are kept in screen space
  and every new clip, including a surface's region, is intersected with the
  active one, whatever rect you pass.
- **A layer is a new root.** Inside `push_layer` (and so inside a popup) the
  origin is zero and the clip is the whole screen.
- **The cursor is screen space.** `ctx.in.mx`/`my` and `input_visible` are in
  screen pixels. Use a `Surface`'s `local_mx`/`local_my` for the cursor in its
  local space.

## Widgets & layout

Every widget places itself at the layout cursor, spans the column, advances
the cursor and emits only quads, so each one clips and scrolls like any
geometry and works inside surfaces, docks and windows alike. A widget takes
the same ids every frame whatever it shows, so later widgets keep their hit
identity.

- **Layout.** `advance(?ctx, h)` moves past a row placed by hand and
  `space(?ctx, h)` leaves room. `cell_x0`/`cell_x1(?ctx, i, n)` split the
  column into n equal cells, gaps between, for widgets that take a rect, such
  as `button_at(?ctx, label, x0, y0, x1, y1, on)`. `begin_columns(?ctx, n)`,
  `next_column` and `end_columns` lay whole widgets side by side and resume
  below the tallest column.
- **Sections.** `section(?ctx, title, ?open)` is a heading with a caret,
  pointing right when closed and down when open, that returns whether to place
  the rows beneath it.
- **Buttons.** `button` spans the column, `buttons(?ctx, ?labels[0], n)` is a
  row of n, and `button_grid(?ctx, ?labels[0], n, cols, on)` wraps them cols
  to a row with button `on` drawn chosen. Both return the index clicked, or n.
- **Choices.** `segmented(?ctx, ?labels[0], n, ?choice)` picks one of n,
  `toggle(?ctx, label, ?state)` is an on/off switch across the row, and
  `checkbox` a box beside its label.
- **Sliders.** `slider(?ctx, label, reading, ?v, lo, hi)` shows the caller's
  formatted `reading` of the value beside its label, and `slider_f` is the
  same without one.
- **Text.** `text` is one line, and `note(?ctx, s)` is dim text wrapped at
  spaces to the column's width.
- **Lists.** `list(?ctx, ?l, ?items[0], count, query, h)` is a scrolling list
  `h` pixels tall. Clicking an item selects it (`List.selected`, the count for
  none), and only the items holding `query`, ignoring ASCII case, are shown,
  so a search box the caller keeps narrows it.

`demo/panel/` builds a docked application panel from these widgets alone, in
the shape of an application's side panel (a header, then run, view and files
sections), and drives it headlessly through `blit.input`.

Beyond the v0 widgets, `blit.widget.dropdown` is a select whose options open in
a popup over later widgets, `blit.widget.begin_window`/`end_window` is a
draggable, collapsible titled window, `blit.widget.begin_popup`/`end_popup`
opens an overlay column, and `blit.widget.region_clicked` hit-tests an arbitrary
rect for consumer-drawn affordances.

## Charts

`blit.chart` plots plain arrays into a rect you give it, in the current local
space, and returns a `Hover` for the value under the cursor:

```mach
var energy: [64]f32;   # filled by you, oldest first
var income: [64]f32;
var series: [2]blit.chart.Series;
series[0] = blit.chart.Series{values: ?energy[0], fill: 1};
series[1] = blit.chart.Series{values: ?income[0], fill: 0};
val hov: blit.chart.Hover = blit.chart.line(?ctx, x, y, w, h, ?series[0], 2, 64, blit.chart.options());
if (hov.hot != 0) { ... }   # hov.index, hov.series, hov.value

blit.chart.bars(?ctx, x, y, w, h, ?net[0], count, blit.chart.options());
blit.chart.sparkline(?ctx, x, y, w, h, ?energy[0], 64);
```

- **Line.** One or more series share x: sample `i` of every series sits at the
  same x, the first at the plot's left edge and the last at its right. A series
  with `fill` set fills the area between its line and zero.
- **Bars.** One bar per value in equal slots, up from zero when positive and
  down when negative.
- **Sparkline.** A compact line fitted to its values, with no axes, for a row or
  a cell.
- **Axes.** `Options.y` is the value range, fixed when `lo < hi` and otherwise
  fitted to the values and widened to whole ticks (bars always hold zero).
  `Options.x` is what the first and last sample stand for, labelling x, and the
  sample index when not fixed. Ticks step by 1, 2 or 5 times a power of ten and
  labels come from the glyph source, with k, M, G or T for large steps.
  `Options.axes = 0` gives the whole rect to the plot.
- **Hover.** A chart takes one id in call order and claims its plot, so it
  reads out only when it is the topmost claimant under the cursor, like any
  widget. A line reports the sample nearest the cursor and the series nearest it
  there, bars report the slot under the cursor, and both draw a read-out of the
  value inside the plot. A sparkline reports and marks its sample.
- **Crisp at any scale.** A line is one quad per screen pixel column, the
  polyline swept by a square brush of `line_w`, so no sample is ever skipped
  when samples outnumber pixels. Columns, rules, bars and labels land on whole
  screen pixels, and every length is a theme metric at the context's scale.
- **Plain quads.** Charts emit through the painter like every widget, clipped to
  their rect and to any clip or sub-surface they sit in, and allocate nothing
  beyond their vertices.

## Layers & input routing

Paint order and input order come from one key, so the widget that receives a
click is always the one visibly on top.

- **Layers.** `blit.context.push_layer` raises subsequent geometry and claims
  onto an overlay above everything on lower layers, in screen coordinates with
  the clip reset to the screen. `pop_layer` returns. `end()` composes the draw
  list by layer, keeping call order within a layer, so a popup opened early in
  the frame still paints over a window called after it. `run_at` reports each
  span's `layer`.
- **Claims.** Interactive widgets call `blit.context.claim(?ctx, id, x0, y0,
  x1, y1)`, which records the rect with the key (layer, then claim order) and
  returns whether the widget is hovered. Containers call `reserve_claim` before
  their children and `fill_claim` at their end, so their empty areas stop input
  instead of letting it reach what they cover.
- **Routing.** Frame N's input goes only to the topmost of frame N-1's claims
  under frame N's cursor, resolved once in `begin`. If the topmost claimant
  disappears, nothing is hovered for one frame rather than the click reaching
  whatever was beneath it.
- **A press in the first frame a widget exists does nothing.** Which widget is
  on top can only be known from rects that already exist, so routing uses the
  previous frame's claims. A widget that appears this frame has no claim there
  yet, so it becomes hoverable and clickable from the next frame. A popup opened
  by a click cannot be pressed in the same frame it opens. The next press always
  comes at least one frame later, since it needs the button to go up and down
  again. In tests, hover for one frame before the first press. This is chosen:
  the alternatives (a second pass over the widgets, or letting some widgets jump
  the queue) would make some widgets special.
- **Popups.** A press anywhere outside an open popup dismisses it (`Popup.dismissed`)
  and is consumed: it does not activate the widget underneath.

## Images & grids

blit draws textures it does not own. A consumer texture is named by an opaque
`u64` handle, whatever the renderer understands (a GL texture name, an index
into its own table). blit never creates, owns or binds one, it only passes the
handle through to the draw list's spans. `0` is reserved for the atlas.

- **Image.** `blit.draw.Image` is a handle, a source rect in uv and a filter.
  `blit.draw.region(tex, tw, th, x, y, w, h, filter)` builds one from a rect in
  texels, `whole(tex, filter)` covers the texture.
- **Drawing.** `blit.context.image_at(?ctx, img, x0, y0, x1, y1, tint)` stretches
  the region into a rect, clipped like any geometry with its uvs cut to match.
  `blit.widget.image(?ctx, img, w, h)` places it at the layout cursor.
- **Grids.** `blit.widget.Grid` is a row-major field of cells, each colored by
  the consumer (`colors`) or by mapping `values` through a `Palette` of equal
  steps from `lo` to `hi`. `grid_at` fills a rect with it and `grid` places it
  at the cursor. Cells are solid quads on the atlas, so a small field needs no
  texture. A large one is better uploaded as a texture and drawn with
  `FILTER_NEAREST`.

## Rendering

blit emits one vertex stream that draws both solid rectangles and text through
a single shader per texture. Solid quads sample a white block every atlas page
carries, so `color * texel` is the flat color; glyph quads sample the glyph's
cell.

- **Atlas.** `blit.context.atlas_of(?ctx)` is the glyph atlas: `page_count`
  pages, each an RGBA8 square of `blit.atlas.PAGE_SIDE` (512) texels at
  `page_pixels(at, i)`. Pages open as glyphs arrive and never resize, and past
  `blit.atlas.PAGE_MAX` (16) the least recently drawn one is cleared and
  reused, wholly dirty. Each has a
  `page_version` bumped on every write and a `page_dirty` rect: upload the dirty
  rect of each changed page before drawing, then `page_clean` it. Every glyph
  has a transparent gutter, so linear filtering is safe. The built-in font at
  whole scales looks sharpest with nearest.
- **Spans.** `run_count`/`run_at` split the draw list into spans that each
  sample one texture, so every quad's texture is its span's. A `Run` is plain
  integers: `tex` (u64), `page` (u32), `layer` (u32), `start` and `count`
  (vertices, usize), `filter` (u32). When `tex` is `blit.draw.ATLAS` (0), bind atlas
  page `page`. Otherwise `tex` is the consumer's own texture handle, passed
  through untouched, and `filter` asks for `FILTER_NEAREST` (0) or
  `FILTER_LINEAR` (1) sampling. On the atlas `filter` is always
  `FILTER_NEAREST` and how to sample it stays the renderer's choice. Draw
  spans in order, rebinding only when `tex`, `page` or `filter` differ from
  the previous span.
- **Color.** Colors are straight rgba as authored. When the target encodes sRGB
  on write, call `blit.context.set_srgb(?ctx, 1)`: every color is then emitted
  in linear light, so the encoding brings it back to what was authored. Alpha is
  never converted.
- **Vertex.** `blit.draw.Vert` is 8 `f32`, 32-byte stride: `aPos` (vec2) at 0,
  `aUV` (vec2) at 8, `aColor` (vec4) at 16. Positions in pixels, uv in [0, 1],
  straight rgba.
- **Shader.** One `vec2 uScreen` uniform:
  ```glsl
  gl_Position = vec4(aPos.x / uScreen.x * 2.0 - 1.0,
                     1.0 - aPos.y / uScreen.y * 2.0, 0.0, 1.0);
  FragColor   = aColor * texture(atlas, aUV);
  ```
- **Per frame.** Fill an `Input` (`mx`, `my`, `down`, `wheel`, the keyboard
  events and any `paste`), `begin`, widgets, `end`, hand `copied` to the
  clipboard and answer `wants_paste`, then upload `draw_verts` / `draw_count` and draw each span as
  `GL_TRIANGLES` with its texture bound and `SRC_ALPHA` / `ONE_MINUS_SRC_ALPHA`
  blending.

## Build & test

```
mach dep pull .
mach build .
mach test .
```

`demo/harness/` is its own project with a path dependency on this checkout. It
drives a headless frame end to end through a bare `use blit;` and prints the
vertex count and atlas pages. It takes std from this checkout's `dep/std`, so
pull the root first:

```
mach dep pull demo/harness
mach build demo/harness
demo/harness/out/linux-x86_64/debug/bin/harness
```

`demo/panel/` builds and runs the same way.

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
