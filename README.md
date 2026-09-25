# blit

An immediate-mode GUI library in Mach.

Widgets accumulate a draw list of colored, textured triangles and report
interaction. The consumer feeds input each frame, runs the widgets, and uploads
and renders the resulting vertices — blit stays out of the windowing and
rendering.

```mach
use blit;

# once, at startup (fallible calls return err[allocator.Error]):
val built: err[allocator.Error] = blit.font.build_atlas(?a);
if (sel built.err) { ... }
# upload blit.font.atlas_pixels() as an RGBA8 texture (see Rendering)

# per frame:
blit.context.begin(?ctx, in, screen_w, screen_h);
val panel: blit.widget.Block = blit.widget.begin_panel(?ctx, 8.0::f32, 8.0::f32, 200.0::f32);
blit.widget.text(?ctx, "controls");
if (blit.widget.button(?ctx, "step")) { ... }
blit.widget.checkbox(?ctx, "running", ?running);
blit.widget.slider_f(?ctx, "rate", ?rate, 0.0::f32, 1.0::f32);
blit.widget.end_panel(?ctx, panel);
blit.context.end(?ctx);
# upload blit.context.draw_verts(?ctx) / draw_count(?ctx) and draw as triangles.
```

`use blit;` binds the surface; reach everything through its submodule:
`blit.draw`, `blit.font`, `blit.input`, `blit.hit`, `blit.context`, `blit.widget`. A
submodule can also be imported directly, e.g. `use w: blit.widget;`.

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
a single shader and texture. Solid quads sample a reserved white texel, so
`color * texel` is the flat color; glyph quads sample the glyph's cell.

- **Atlas.** `blit.font.build_atlas(?a)` rasterizes the font once and returns
  the allocator's refusal as `err[allocator.Error]`;
  `blit.font.atlas_pixels()` returns RGBA8, `ATLAS_W`×`ATLAS_H` (128×48). Use
  nearest filtering.
- **Vertex.** `blit.draw.Vert` is 8 `f32`, 32-byte stride: `aPos` (vec2) at 0,
  `aUV` (vec2) at 8, `aColor` (vec4) at 16. Positions in pixels, uv in [0, 1],
  straight rgba.
- **Shader.** One `vec2 uScreen` uniform:
  ```glsl
  gl_Position = vec4(aPos.x / uScreen.x * 2.0 - 1.0,
                     1.0 - aPos.y / uScreen.y * 2.0, 0.0, 1.0);
  FragColor   = aColor * texture(atlas, aUV);
  ```
- **Per frame.** Fill an `Input` (`mx`, `my`, `down`), `begin`, widgets, `end`,
  then upload `draw_verts` / `draw_count` and draw `GL_TRIANGLES` with
  `SRC_ALPHA` / `ONE_MINUS_SRC_ALPHA` blending.

## Build & test

```
mach dep pull .
mach build .
mach test .
```

`demo/harness/` is its own project with a path dependency on this checkout. It
drives a headless frame end to end through a bare `use blit;` and prints the
vertex count. It takes std from this checkout's `dep/std`, so pull the root first:

```
mach dep pull demo/harness
mach build demo/harness
demo/harness/out/linux-x86_64/debug/bin/harness
```

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
