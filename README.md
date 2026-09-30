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
`blit.input`, `blit.hit`, `blit.theme`, `blit.context`, `blit.widget`. A submodule can also be
imported directly, e.g. `use w: blit.widget;`.

## Text & glyph sources

Text comes from a glyph source, a record of functions over the source's own
state (`blit.glyph.GlyphSource`). blit owns UTF-8 decoding, layout, the glyph
cache and the atlas, and asks the source only for what a face knows:

```mach
pub rec GlyphSource {
    self:   ptr;
    line:   fun(ptr, f32) LineMetrics;              # (self, scale)
    glyph:  fun(ptr, u32, f32, *Glyph) bool;        # (self, codepoint, scale, out)
    kern:   fun(ptr, u32, u32, f32) f32;            # (self, left, right, scale), or nil
    raster: fun(ptr, u32, f32, *u8, usize) bool;    # (self, codepoint, scale, coverage, stride)
}
```

- **Metrics are floats** in pixels at the scale asked for: `LineMetrics` is
  ascent, descent and gap, and a `Glyph` is its advance, the rect its bitmap
  covers relative to the pen on the baseline (y down), and the bitmap's size in
  texels. Scale is the interface scale (`ctx.scale`, 1.0 by default), so text at
  200% is rasterised at that size, not stretched.
- **Glyphs come on demand.** A codepoint is measured the first time it is laid
  out and rasterised the first time it is drawn, then cached per scale.
  Measuring never rasterises.
- **Codepoints, not bytes.** Text is UTF-8. A codepoint the source lacks draws
  as U+FFFD, or `?` when it lacks that too. Control codepoints take no space and
  a newline starts the next line.
- **Bitmap by default.** `blit.bitmap.source()`, the built-in 8x8 font, is the
  default, so a context needs no configuration. `blit.context.set_glyph_source`
  plugs in another between frames, such as a TrueType face from the host. blit
  itself never depends on one.

`blit.context.text_width` and `line_height` measure at the context's scale, and
`blit.font.advance` steps one codepoint at a time for layout built outside
blit.

## Theme & scale

Every color and length a widget draws with comes from a theme, a plain record
(`blit.theme.Theme`) of colors and unscaled pixel lengths: surfaces (`panel`,
`window`, `dock`, `header`, `header_hot`), `edge`, `text` and `text_dim`,
`accent`, `warn`, control states (`control`, `control_hot`, `control_on`,
`track`, `handle`, `handle_on`), and the metrics `row`, `gap`, `pad`,
`handle_w`, `bar_w`, `thumb_min`, `corner` and `edge_w`. No widget holds a
color or a size of its own.

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

Beyond the v0 widgets, `blit.widget.dropdown` is a select whose options open in
a popup over later widgets, `blit.widget.begin_window`/`end_window` is a
draggable, collapsible titled window, `blit.widget.begin_popup`/`end_popup`
opens an overlay column, and `blit.widget.region_clicked` hit-tests an arbitrary
rect for consumer-drawn affordances.

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

## Rendering

blit emits one vertex stream that draws both solid rectangles and text through
a single shader per texture. Solid quads sample a white block every atlas page
carries, so `color * texel` is the flat color; glyph quads sample the glyph's
cell.

- **Atlas.** `blit.context.atlas_of(?ctx)` is the glyph atlas: `page_count`
  pages, each an RGBA8 square of `blit.atlas.PAGE_SIDE` (512) texels at
  `page_pixels(at, i)`. Pages open as glyphs arrive and never resize. Each has a
  `page_version` bumped on every write and a `page_dirty` rect: upload the dirty
  rect of each changed page before drawing, then `page_clean` it. Every glyph
  has a transparent gutter, so linear filtering is safe. The built-in font at
  whole scales looks sharpest with nearest.
- **Spans.** `run_count`/`run_at` split the draw list into spans that each
  sample one texture: a consumer image (`tex`), or atlas page `page` when `tex`
  is nil.
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
- **Per frame.** Fill an `Input` (`mx`, `my`, `down`, `wheel`), `begin`,
  widgets, `end`, then upload `draw_verts` / `draw_count` and draw each span as
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

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
