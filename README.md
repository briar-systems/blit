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
val panel: usize = blit.widget.begin_panel(?ctx, 8.0::f32, 8.0::f32, 200.0::f32);
blit.widget.text(?ctx, "controls");
if (blit.widget.button(?ctx, "step")) { ... }
blit.widget.checkbox(?ctx, "running", ?running);
blit.widget.slider_f(?ctx, "rate", ?rate, 0.0::f32, 1.0::f32);
blit.widget.end_panel(?ctx, panel);
blit.context.end(?ctx);
# upload blit.context.draw_verts(?ctx) / draw_count(?ctx) and draw as triangles.
```

`use blit;` binds the surface; reach everything through its submodule:
`blit.draw`, `blit.font`, `blit.input`, `blit.context`, `blit.widget`. A
submodule can also be imported directly, e.g. `use w: blit.widget;`.

## Clipping & sub-surfaces

Clipping is geometric and CPU-side, so blit stays out of the backend. Push a
clip rect with `blit.context.push_clip(?ctx, x0, y0, x1, y1)` — intersected with
the active rect — and restore it with `pop_clip`. Quads fully outside the rect
are dropped and partial ones are shrunk with their uvs interpolated, and a
clipped-out widget never becomes hot.

`blit.context.begin_surface(?ctx, x, y, w, h, scroll_x, scroll_y)` opens a
clipped region with its own scrolled local coordinate space: emit content at
local coordinates and read the returned `Surface`'s `local_mx`/`local_my`/
`inside` to hit-test custom content against `blit.input`. Close it with
`end_surface`.

Beyond the v0 widgets, `blit.widget.dropdown` is an inline accordion select,
`blit.widget.begin_window`/`end_window` is a draggable, collapsible titled
window, and `blit.widget.region_clicked` hit-tests an arbitrary screen rect for
consumer-drawn affordances.

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

The `[artifact.harness]` bin drives a headless frame end to end. It imports the
library entry as `use blit.blit;`, because inside this project a bare `use blit;`
binds the artifact being built.

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
