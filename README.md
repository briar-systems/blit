# blit

An immediate-mode GUI library in Mach.

Widgets accumulate an indexed draw list of colored, textured triangles and
report interaction. The consumer feeds input each frame, runs the widgets, and
uploads and renders the resulting vertices and indices, so blit stays out of
the windowing and rendering.

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
# upload the atlas pages that changed (see Rendering), then the vertices and
# indices, and draw each run with its texture and scissor.
```

`use blit;` binds the surface; reach everything through its submodule:
`blit.draw`, `blit.path`, `blit.icon`, `blit.glyph`, `blit.bitmap`, `blit.font`, `blit.atlas`,
`blit.input`, `blit.layout`, `blit.hit`, `blit.band`, `blit.interact`, `blit.field`, `blit.edit`, `blit.theme`, `blit.context`, `blit.state`, `blit.text`, `blit.widget`, `blit.menu`, `blit.controls`, `blit.textarea`, `blit.chart`, `blit.payload`, `blit.dnd`, `blit.driver`. A submodule can also be
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
  `blit.widget.row_gap(?ctx)`, `text_row_height`, `control_row_height` and
  `control_height` (a control row without its gap) report the spacing at the
  current theme and scale.
- **Rows fit their text.** A control row is `row` tall, or a line of text plus
  `pad` above and below if that is taller, so a larger glyph source never
  overflows its rows.
- **Rounded corners.** `corner` rounds controls and containers through
  `blit.context.fill`, a feathered rounded rect (see Shapes & paths). The
  default is square, one quad per rect.

## Docked containers

Alongside floating windows, `blit.widget.begin_dock(?ctx, key, ?d)`/`end_dock`
attach a panel to a screen edge (`blit.context.Side`: left, right, top or bottom). Each dock
takes a strip from the frame's free area, so docks opened in turn stack inward,
and `blit.context.free_area` reports what they leave for the rest of the screen,
such as a world view. Call docks at the root.

A dock's body is a scroll region. `blit.widget.begin_scroll(?ctx, key, ?s, h)`/`end_scroll`
open one as the next item of the layout on its own: its column is clipped and scrolls by the
wheel (`Input.wheel`, pixels, positive turned away from the user) and by a
draggable scrollbar when its content is taller than it. The wheel goes to the
innermost region holding the topmost claim under the cursor.
`blit.widget.section(?ctx, title, ?open)` is a collapsible heading that returns
whether the rows beneath it should be placed.

## Input & the host contract

blit never touches a window. Each frame the consumer fills a
`blit.input.Input`, plain data written against the hardest host (a desktop
window with an IME, high-resolution wheels and several pointer buttons), and
hands it to `begin`. A simpler host leaves what it lacks zeroed.

```mach
var in: blit.input.Input;
blit.input.init(?in, ?a);           # once: the events grow in storage `in` owns
# per frame:
blit.input.clear_keys(?in);
in.time    = clock_seconds();       # the host's monotonic clock, as f64
in.present = 1;                     # 0 while the pointer is off the surface
in.mx      = x;
in.my      = y;
in.down    = blit.input.BUTTON_LEFT; # BUTTON_* bits held after the frame's last event
in.mods    = blit.input.MOD_SHIFT;   # MOD_* bits held this frame
in.wheel   = dy_pixels;             # both wheels in pixels
in.wheel_x = dx_pixels;
blit.input.press_button(?in, blit.input.BUTTON_LEFT, bx, by); # then every event, in arrival order
blit.input.type_text(?in, cp);
blit.context.begin(?ctx, in, w, h);
# ... widgets ...
blit.context.end(?ctx);
# blit.input.free(?in) at shutdown
```

- **Time.** `in.time` is the host's monotonic clock in seconds, and
  `blit.context.dt(?ctx)` is the time since the previous frame (0 on the
  first). Double clicks, caret blink and every other timed behaviour need it:
  a host that never advances `in.time` gets single clicks only and a caret
  that does not blink.
- **Pointer.** `down` and `prev_down` are bitmasks of `BUTTON_LEFT`,
  `BUTTON_RIGHT`, `BUTTON_MIDDLE`, `BUTTON_X1` and `BUTTON_X2`, and
  `blit.input.pressed`, `released` and `held` take the button. The context
  carries `prev_down` across frames. With `present` 0 nothing is hovered and
  `in_rect` misses. Widgets act on the left button through `blit.interact`
  (see Interaction).
- **Button events.** A host that only samples the buttons sets `down` and
  nothing more, and a press and release that both land between two frames are
  then lost. A host that sees each one also adds it as it arrives,
  `press_button(?in, button, x, y)` and `release_button(?in, button, x, y)`
  with the cursor where it happened, and still sets `down` to the buttons held
  after the last of them. `begin` hands them to widgets in order, at most one
  change of a button per frame, holding the rest back and asking for the next
  frame through `next_frame`, so a quick click is a press in one frame and a
  release in the next, and a double click is a click, then a press. A frame
  that applies one sees the cursor where it happened, so `pressed` and
  `released` keep their per-frame meaning.
- **Keyboard events.** `type_text(?in, cp)` for each typed codepoint,
  `press_key(?in, code, mods)` for each key press or repeat,
  `release_key(?in, code, mods)` for each release and `compose(?in, text,
  caret)` for the IME's composition in progress (an empty one ends it; the
  committed text arrives as typed text). They live in storage the `Input`
  owns, bound to an allocator by `init`, so a frame holds any number of them,
  and passing the `Input` by value copies only the view. A key that types a
  printable ASCII character is that character, letters in uppercase (`'A'`,
  `'7'`, `' '`); every other key is a `KEY_*` constant (`KEY_ENTER`,
  `KEY_ESCAPE`, `KEY_BACKSPACE`, `KEY_DELETE`, the arrows, `KEY_HOME`,
  `KEY_END`, ...). Modifiers are `MOD_SHIFT`, `MOD_CTRL`, `MOD_ALT` and
  `MOD_SUPER` bits, both held (`in.mods`) and carried by each key event, and
  `blit.input.shortcut(mods)` is ctrl, or super as darwin's command, without
  alt.
- **Back to the host.** After `end`, `blit.context.cursor(?ctx)` is the
  pointer shape to show (`CURSOR_ARROW`, `TEXT`, `HAND`, `MOVE`, `RESIZE_EW`,
  `RESIZE_NS`, `RESIZE_NWSE`, `RESIZE_NESW`, `NOT_ALLOWED`), which widgets set
  while hovered, and `ime_rect(?ctx)` is where to put the IME's candidate
  window, in screen pixels, none while nothing takes text.
- **Scheduling.** Widgets call `blit.context.wake_at(?ctx, t)` for a time they
  need a frame by (a hover delay, an animation, a caret blink). After `end`,
  `next_frame(?ctx)` is `some(0)` to draw again now (also while button events
  are held back), `some(t)` to draw by time `t`, or `none` to draw only on input, so an idle tool can sleep instead of
  redrawing every frame.

## Keyboard, focus & text fields

- **Focus.** One widget at a time holds the keyboard, by id across frames
  (`blit.context.focus`, `focused`, `unfocus`), so
  `focus(?ctx, blit.context.id_of(?ctx, key))` hands it to a widget from code.
  A press that lands anywhere else takes it back, and so does a frame that does
  not draw the holder.
  `blit.context.typing(?ctx)` is true exactly while a widget holds it: read it
  before `begin` to keep the consumer's own key bindings quiet for the keys that
  frame will type into a field.
- **Clipboard hand-off.** blit never reads the system clipboard. After `end`,
  `blit.context.copied(?ctx)` is text a copy or cut left for the consumer to put
  on the clipboard (nil when none), and `wants_paste(?ctx)` asks for the
  clipboard's text, which the consumer hands to the next frame as `in.paste`.
- **Text field.** `blit.widget.text_field(?ctx, key, ?f, hint)` edits a
  `blit.field.Field`: UTF-8 in a buffer the consumer owns, with a caret, a
  selection, a maximum length in characters and a per-field filter.
  ```mach
  var buf:  [64]u8;
  var name: blit.field.Field;
  blit.field.init(?name, ?buf[0], 64, 24, nil); # 24 characters, any printable
  # per frame, inside a panel:
  val did: u8 = blit.widget.text_field(?ctx, "name", ?name, "name");
  if ((did & blit.field.ENTERED) != 0) { ... }
  ```
  A press on the field focuses it and puts the caret under the cursor, or
  extends the selection to it with shift held. A double click selects a word
  and a triple click the line, and dragging extends the selection by
  characters, words or lines to match. Runs of clicks are counted by
  `blit.interact` (see `blit.context.set_double_click`).
  The field takes typed text, backspace and delete, left, right, home and end
  (shift extends the selection), word movement and deletion with
  `blit.input.MOD_WORD` (option on darwin, ctrl elsewhere) held with the
  arrows, backspace and delete, shortcut A to select all, shortcut Z to undo
  and shortcut shift Z or Y to redo, shortcut C, X and V through the clipboard
  hand-off, and enter or escape, which end the edit and give the keyboard
  back. It returns this frame's `EDITED`, `ENTERED` and `ESCAPED` bits.
  While focused the caret blinks every `blit.edit.BLINK` seconds, asking for
  the frames it needs through `next_frame`, and the field shows the IME's
  composition inline at the caret, underlined, and places the candidate window
  at the caret.
- **Field flags.** `f.flags` shapes a field, 0 after `init`:
  `blit.field.MASKED` draws `*` for every character, never copies and takes no
  composition (a password); `READ_ONLY` moves, selects and copies but refuses
  every edit; `COUNT` shows the length in characters, against `max` when set;
  `LINES` makes enter type a newline and home and end act on the line.
- **Undo.** Undo history lives in a second buffer the consumer owns, so a field
  without one has no undo:
  ```mach
  var hist: [4096]u8;
  blit.field.keep_history(?name, ?hist[0], 4096);
  ```
  Typing and single-character deletions coalesce into word-sized steps, any
  other edit or a caret movement ends a step, and the oldest steps are dropped
  when the buffer fills. `blit.field.set` clears the history.
- **Text area.** `blit.textarea.text_area(?ctx, key, ?f, ?view, h)` edits a
  field over many lines in a box `h` tall across the column. The text wraps at
  word boundaries, up and down move the caret by wrapped rows toward the column
  they started in, page up and page down by a box of rows, and the box scrolls
  by wheel and scrollbar and to keep the caret in view. Clicks, drags, the
  keyboard, undo, the clipboard, the caret and the composition behave as in
  the text field, enter types a newline (the area makes its field `LINES`) and
  escape ends the edit. A `COUNT` field shows its length on a row below.
  The `blit.textarea.TextArea` view keeps the scroll and the start of every
  wrapped row, laid out again only when the text, width, style or scale
  changes, so each frame draws only the rows in view of however long a text:
  ```mach
  var view: blit.textarea.TextArea;
  blit.textarea.init(?view, ?a);               # once
  blit.textarea.text_area(?ctx, "notes", ?notes, ?view, 200.0);
  blit.textarea.free(?view);                   # at shutdown
  ```
- **The edit model.** `blit.field` needs no context, so a field can be driven
  directly: `insert`, `paste`, `erase`, `key`, `undo`, `redo`, `select_word`,
  `select_line`, `word_left`, `word_right`, `place` and `move`.
  `blit.edit` holds what both text widgets share between the frame's input and
  a field (event routing, click and drag selection, the caret blink and masked
  drawing), for a consumer building a text widget of its own.

## Clipping & sub-surfaces

Push a clip rect with `blit.context.push_clip(?ctx, x0, y0, x1, y1)`,
intersected with the active rect, and restore it with `pop_clip`. Geometry
wholly outside the rect is dropped on the CPU, and the rest is kept whole: every
run of the draw list carries the clip rect it was drawn under, which the
renderer sets as its scissor (see Rendering). So any shape clips, rotated,
curved or feathered, and a clipped-out widget never becomes hot.

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
- **A band is a new root.** Inside `push_band` (and so inside a window, a dock
  or a popup) the origin is zero and the clip is the whole screen.
- **The cursor is screen space.** `ctx.in.mx`/`my` and `input_visible` are in
  screen pixels. `blit.context.local_mx(?ctx)`/`local_my` are the cursor in the
  current local space, as are a `Surface`'s `local_mx`/`local_my` and a hit's
  `mx`/`my`.

## Interaction

`blit.interact.hit(?ctx, id, x0, y0, x1, y1, buttons)` is how every widget
meets the pointer, built-in or not: it claims the rect in the current local
space (clipped and layered like geometry) and returns a `blit.interact.Hit`
for the `BUTTON_*` bits it answers to. Every built-in widget and chart calls
it, so a custom control behaves exactly like one.

```mach
val id: u64 = blit.context.id_of(?ctx, "node");
val h:  blit.interact.Hit = blit.interact.hit(?ctx, id, x0, y0, x1, y1,
    blit.input.BUTTON_LEFT | blit.input.BUTTON_RIGHT);
if (h.double)                                         { open_node(); }
or (h.clicked && h.button == blit.input.BUTTON_RIGHT) { open_menu(h.mx, h.my); }
if (h.held) { drag_by(h.dx, h.dy); }
```

- **Hover.** `hot` while it is the topmost claimant under the cursor.
- **Owning the pointer.** A press over it with one of its buttons makes it
  `active` until that button comes up, and `pressed` on that frame. A press
  while another button owns the pointer takes nothing. While active, `held`
  says the button is still down and `dx`/`dy` are the cursor's travel since the
  press, wherever the cursor goes. `released` is the frame the button comes up,
  over it or not, and `clicked` is a release over it. `button` is the
  `BUTTON_*` bit it acted on.
- **Double clicks.** The context keeps each button's last press
  (`blit.context.last_press`): its time, where it landed in screen space, the
  claimant it landed on and its run of clicks. A press on the same claimant
  within the double-click time and distance of the one before extends the run:
  `clicks` is 1, 2 or 3 for a single, double or triple click, and `double` is
  the second.
  `blit.context.set_double_click(?ctx, seconds, pixels)` sets the threshold
  (`DOUBLE_TIME`, 0.3 s, and `DOUBLE_DIST`, 6 unscaled pixels, by default), so
  a host can pass its platform's settings.
- **Hover only.** `buttons` 0 reports hover and the cursor and never owns the
  pointer, as a chart's read-out does.
- **Moving with a drag.** `blit.interact.drag(?ctx, id, ?dx, ?dy)` reports the
  same travel without claiming, for a part that moves with its drag (a title
  bar, a scrollbar thumb) and must place its rect before claiming it.
- **Focus.** A widget that takes the keyboard does it on `pressed` with
  `blit.context.focus(?ctx, id)`. Its id is `id_of(?ctx, key)` in the scope it
  was drawn in, so a caller that refuses a text field's entry (`ENTERED` with
  text it will not take) calls `focus` with that id to hand the keyboard
  straight back, and `focused(?ctx, id)` says whether it holds it.

## Drag and drop

`blit.dnd` lets any widget be a drag source or a drop target. Both ends take
the widget's own `blit.interact.Hit`, so a row, a tab or a window's title bar
becomes a source or a target by passing its hit along.

```mach
# a source: past a small move threshold its drag starts with a typed payload,
# a type tag and bytes the context copies
val h: blit.interact.Hit = blit.interact.hit(?ctx, id, x0, y0, x1, y1, blit.input.BUTTON_LEFT);
val d: blit.dnd.Drag = blit.dnd.source(?ctx, h, "layer", (?index)::ptr, $size_of(u64), x0, y0, x1, y1);
if (d.on) {
    # the source draws its own preview, on a layer above the interface
    val pv: blit.dnd.Preview = blit.dnd.begin_preview(?ctx);
    blit.context.quad(?ctx, pv.x0, pv.y0, pv.x1, pv.y1, ctx.theme.control_on);
    blit.dnd.end_preview(?ctx, pv);
}
if (d.missed) { float_off(); }

# a target: after drawing the widget, name the type it accepts over its rect
val t: blit.dnd.Drop = blit.dnd.target(?ctx, h, "layer", x0, y0, x1, y1);
if (t.dropped) { move_layer(@(t.data::*u64), here); }
```

- **Source.** `source` is called every frame with the widget's hit. Once the
  widget holds the pointer and has moved `payload.THRESHOLD` (4 unscaled
  pixels, `set_threshold` changes it) from the press, the drag starts. The
  payload is copied into storage the context owns, again every frame the drag
  is on, so a source can hand over a record on its stack, and the rect given
  is what the preview follows. `Drag.on` is true while its drag is in flight,
  and through the frame after it ends exactly one of `dropped` (a target took
  it), `missed` (released over no target) or `cancelled` (Escape) is set, so a
  dragged tab can become a window when no tab bar took it.
- **Target.** `target` reports a drag of its type over it when its hit is
  hot, the topmost claimant under the pointer, and draws the theme's accept
  highlight (the `select` tint under an `accent` outline) over the rect.
  `Drop.dropped` is the frame the button comes up over it, with the payload
  in `data` and `n` and the starting widget in `source`. A target accepting
  several types calls `target` once per type with the same hit. A target with
  nothing else to do claims its rect with `interact.hit` and no buttons.
- **Preview.** `begin_preview` opens a layer in the drag band, above every
  other band (see Layers & input routing), and returns the source's rect in
  screen pixels, kept under the pointer where the press grabbed it. The source draws anything there, and the layer claims nothing,
  so targets beneath still see the pointer.
- **Cancel.** Escape ends a drag at once, and the source cannot start another
  until its button comes up. A release over no target ends it as missed.
- **Anywhere.** The drag belongs to the context (`blit.payload`), not to its
  source, so it outlives the source's frames and reaches targets in any
  window, dock, popup or surface: the claim order that routes every hover
  decides which target is under the pointer. `carried(?ctx, kind)` peeks at a
  drag in flight, for a widget that shows where a drag would land before it
  is over a target.

## Widgets & layout

Every widget asks the layout for its rect, draws through the painter in it,
and moves the layout on, so each one clips and scrolls like any geometry and
works inside surfaces, docks and windows alike.

- **A stack of frames.** Layout is a stack of frames on the context
  (`blit.layout.Frame`): a content box, a pen, the axis items advance along,
  the gap between them and how they align across it. Every container (panel,
  window, popup, dock, scroll region, columns, stack) pushes its frame at its
  begin and pops it at its end, so a panel opened inside a window leaves the
  window's layout where it was. Outside any container, widgets lay out down a
  column over the screen.
- **Stacks.** `begin_stack(?ctx, key, s)`/`end_stack` open a horizontal or
  vertical stack as the next item of the current frame, and stacks nest.
  `blit.widget.stack(?ctx, axis)` gives the options at the theme's gap: adjust
  `gap`, `align` (`start`, `center`, `end` or `stretch`, across the axis), the
  stack's own `w` and `h` in its parent, and `item_w`/`item_h`, the rules its
  items take unless they set one.
  ```mach
  var bar: blit.layout.Stack = blit.widget.stack(?ctx, blit.layout.Axis.horizontal{});
  bar.align  = blit.layout.Align.center{};
  bar.item_w = blit.layout.fit();
  blit.widget.begin_stack(?ctx, "tools", bar);
  blit.widget.button(?ctx, "Open");
  blit.widget.button(?ctx, "Save");
  blit.widget.size_next(?ctx, blit.layout.fill(1.0::f32), blit.layout.auto());
  blit.widget.text_field(?ctx, "find", ?find, "find");
  blit.widget.end_stack(?ctx);
  ```
- **Sizing.** Each side of an item is `blit.layout.fixed(px)`, `fit()` (what its
  content needs), `fill(weight)` (a share of the space the other items leave)
  or `frac(f)` (a fraction of the space left), and `limit(s, min, max)` clamps
  any of them. `size_next(?ctx, w, h)` sizes the next item, `auto()` leaving a
  side to the item. Widgets that spanned the column (buttons, sliders,
  toggles, fields, dropdowns, sections, scroll regions) fill the width by
  default, and text, checkboxes, images and grids fit their content.
- **A hidden first frame.** A single pass cannot know a container's content
  before placing it, so a stack fitted to its content, a stack centered or
  end-aligned in its parent, and fill shares along a stack read what the
  stack measured last frame, kept in the state store under its id. A stack
  that would place anything by such a measure before it has one lays out its
  first frame only to measure: its geometry and claims, and its children's,
  are dropped (`blit.context.push_measure`/`pop_measure`), and it asks for
  the next frame at once, so `next_frame` is `some(0)`. A guess is never seen
  or clicked, as with Dear ImGui's hidden first frame for auto-fit windows.
  After that, a change of content settles one frame late.
- **Same line.** `same_line(?ctx)` puts the next item beside the last one in a
  column, for quick inline rows. The line is as tall as its tallest item.
- **By hand.** `place(?ctx, w, h, nat_w, nat_h)` places a control built
  outside blit as the next item, with its own rules and natural size, and
  returns its rect, and `begin_scroll_at` opens a scroll region over such a
  rect. `avail(?ctx)` is the space the next item may take, from the pen to the
  frame's far edges. `advance(?ctx, h)` moves past a row placed by hand
  and `space(?ctx, h)` leaves room. `cell_x0`/`cell_x1(?ctx, i, n)` split the
  column into n equal cells, gaps between, for widgets that take a rect, such
  as `button_at(?ctx, label, x0, y0, x1, y1, on)`. `begin_columns(?ctx, n)`,
  `next_column` and `end_columns` lay whole widgets side by side and resume
  below the tallest column.
- **Style.** The gaps between items and the padding containers keep come from
  the theme (`gap`, `pad`) at the context's scale.

This is a breaking change from the loose layout fields: `Context.ox`, `oy`,
`cx`, `cy` and `pw` are gone (read `avail` instead), as are the saved-layout
fields of `Popup`, `ScrollArea` and `DockArea`, and `Columns` holds its row
instead of `ox` and `pw`.

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
- **Lists.** `blit.list.show(?ctx, key, ?l, rows, h)` is a scrolling list `h`
  pixels tall, described each frame by a `blit.list.Rows`:
  `blit.list.rows(?labels[0], count)` fills one with labels alone, and its
  fields add the rest. `details` holds a secondary label per row, drawn
  right-aligned in the dim text color, with the label clipped short of it.
  `match(user, index, query)` decides which items are shown, defaulting to the
  items whose label holds `query`, ignoring ASCII case (`blit.widget.matches`,
  for a matcher to build on). `draw(ctx, user, row)` paints a row's content in
  place of the labels: the list still claims the row, paints its hover and
  selection face beneath and scrolls it, so a drawn row keeps hit, selection
  and scrolling, and anything the drawer claims sits above the row. The
  `blit.list.Row` it receives carries the item, the row's id and `Hit` (where
  a drag source or drop target for reordering attaches), its rect, whether it
  is selected and the text colors for that. `row_h` sets a row height other
  than the theme's. Clicking a row selects its item (`List.selected`, the
  count for none). With `List.marks` pointing at one byte per item the list is
  a multiple selection: a click selects an item alone, ctrl (command on
  darwin) toggles it, and shift selects the shown items from the last one
  clicked. A row's id is its item index under the list's, so it keeps its hit
  identity as the query or matcher changes.

`demo/panel/` builds a docked application panel from these widgets alone, in
the shape of an application's side panel (a header, then run, view and files
sections), and drives it headlessly through `blit.input`.

Beyond the v0 widgets, `blit.widget.dropdown` is a select whose options open in
a popup over later widgets, its open state kept in the state store under its
id, `blit.widget.begin_window`/`end_window` is a full window (see
Windows), `blit.widget.begin_popup(?ctx, key, open, x, y, w)`/`end_popup`
opens an overlay column, and `blit.widget.region_clicked(?ctx, key, x0, y0,
x1, y1)` is a left click on an arbitrary rect for consumer-drawn affordances,
the simplest use of `blit.interact.hit`.

## Windows

```mach
use blit;

# once: windows save and load with the state store
blit.widget.persist_windows(?ctx);

# per frame: the rect is where the window first opens, the store keeps the rest
var tools: blit.widget.Window = blit.widget.window("tools", 40.0::f32, 40.0::f32, 220.0::f32, 300.0::f32);
tools.min_w = 160.0::f32;
val w: blit.widget.WindowArea = blit.widget.begin_window(?ctx, tools);
if (w.body != 0) {
    blit.widget.button(?ctx, "go");
}
blit.widget.end_window(?ctx, w);

# reopen it after its close button closed it
blit.widget.window_state(?ctx, "tools").closed = 0;
```

- **Identity and state.** A window is its title's id (see Widget ids). Its
  place, size, stack order, and open, collapsed, pinned and locked flags are a
  `WindowState` the context's store keeps under that id, so reordering the
  calls never moves or restacks a window, and `persist_windows` saves and
  loads them with everything else the store persists, as `[window.<id>]`
  tables. `Window` is only what the call declares: the rect the window first
  opens at, its size bounds (`min_w`, `min_h`, `max_w`, `max_h`, 0 for none)
  and its flags. `window_state(?ctx, key)` reaches the state to open, close,
  pin or lock a window from code.
- **Chrome.** The titlebar drags the window and holds a collapse box on the
  left and a close button on the right. Grips just outside every edge and corner
  resize it within its bounds and ask for the matching resize cursor. A
  locked window neither moves nor resizes.
- **Body.** The body is a layout column (see Widgets & layout) in a scroll region
  under the titlebar, which scrolls by wheel and scrollbar when its widgets
  are taller than it. With `WINDOW_AUTO_SIZE` the window fits its widgets
  instead, within its bounds and without grips: as tall as they reach this
  frame, and as wide as the widest of them and its titlebar measured the frame
  before. An auto-sized window declared 0 wide lays out its first frame
  hidden, only to measure. Place widgets only while `body` is 1: a closed or
  collapsed window has none. The window's coordinates are screen pixels,
  wherever it is called.
- **Stacking.** Windows live in the windows band, above docks and beneath
  popups. A press anywhere on a window brings it to the front, whatever order
  the windows are called in, and a pinned window stays in front of every
  unpinned one.
- **Flags.** `WINDOW_NO_TITLE`, `WINDOW_NO_RESIZE`, `WINDOW_NO_MOVE`,
  `WINDOW_NO_BACKGROUND` (the body still stops input), `WINDOW_NO_CLOSE` and
  `WINDOW_AUTO_SIZE`, combined with `|`.

This is a breaking change: `begin_window` takes a `Window` declaration by
value and returns a `WindowArea`, `end_window` takes only that, and `Window`
no longer holds `open` or the window's live position.

## Small controls

`blit.controls` holds the small controls a tool expects, each placed at the
layout cursor across the column like `blit.widget`'s:

- **Radio buttons.** `radio(?ctx, label, ?choice, value)` is a circle beside
  its label that sets `@choice` to `value` when clicked, filled in the accent
  while chosen, so buttons sharing one choice make a group.
  `radios(?ctx, ?labels[0], n, ?choice)` stacks n of them, button i standing
  for i.
- **Progress bars.** `progress(?ctx, frac, text)` fills to `frac` of the
  column, and `progress_busy(?ctx, text)` sweeps a segment across it every
  `BUSY_PERIOD` seconds of `in.time` for work of unknown length. A busy bar
  asks for the frame its segment next moves a pixel in through `wake_at`, so
  it animates while drawn and an interface without one still reports `none`
  from `next_frame`. Either takes text to centre over the bar, nil for none.
- **Separators.** `separator(?ctx)` is a rule across the column in the
  theme's `edge` color, `edge_w` thick, and `separator_label(?ctx, label)` runs
  the rule on from a dim label.
- **Combo.** `combo(?ctx, label, ?selected, ?options[0], count)` is a select
  whose popup holds a filter field that takes the keyboard when it opens.
  Typing narrows the options to those holding the text, ignoring ASCII case,
  up and down move the highlight among them, and enter or a click picks one.
  Escape or a press outside closes it without a pick. `COMBO_ROWS` options
  show at once and the rest scroll. Its open state, filter, highlight and
  scroll live in the state store under its id, and its parts are reached by
  path: `pick/popup/filter` is the filter and `pick/popup/options` the list,
  each option an index under it.

## Widget ids

A widget's id is a 64-bit FNV-1a hash of its key folded into the seed of the
current id scope and finished with a 64-bit mixer, never its place in the call
order. A widget drawn only some frames, a clipped row or a reordered window
therefore moves no other widget's id, and the active drag, the focus holder and
the open dropdown stay where they
were. 0 is never an id: it means "no widget".

- **Labels are keys.** A labelled widget (`button`, `checkbox`, `toggle`,
  `slider`, `dropdown`, `section`, a window's title) is keyed by its label.
  Text after `##` is hashed but not drawn, so `"Save##toolbar"` shows `Save`
  and is a different widget from another `"Save"`. A label holding `###` is
  keyed by the text from `###` on alone, so what it shows can change without
  changing its id: `"Frames: 12###fps"` and `"Frames: 13###fps"` are one
  widget. Widgets without a label (`text_field`, `region_clicked`, popups,
  scroll regions, docks, lists and charts) take a key argument the same way.
- **Scopes.** `blit.context.push_id_str(?ctx, s)` and `push_id_int(?ctx, n)`
  open a scope and `pop_id(?ctx)` closes it, and a pop with no scope open is
  ignored. Windows, open popups and scroll regions (so docks and lists too)
  open their own scope for what they hold, so two windows can each hold a
  button called `ok`. Repeated rows built from one label, such as buttons in a
  loop, take `push_id_int` with their index. The stack grows from the
  context's allocator.
- **Parts.** A widget's internal parts (a window's title, collapse box, close
  button, resize grips and body, a scrollbar thumb, a popup's outside claim, a dropdown's options, a list's
  items) take ids derived from the widget's id with a fixed suffix or index.
- **Looking ids up.** `blit.context.id_of(?ctx, key)` is the id a widget with
  that label or key gets in the current scope, for `focus`, state lookups and
  tests. `blit.id.of_path(blit.id.ROOT, "Settings/Audio/volume")` names a
  widget from outside its scopes: each segment is a container's label or key
  (a window's title, a dock's, popup's, scroll region's or list's key, a
  `push_id_str` key) and the last is the widget's. A key holding `/` cannot
  be named by a path; use its id.
- **Collisions.** Two claims with one id in a frame are recorded:
  `blit.context.collisions(?ctx)` counts them after `end` and
  `collision_at(?ctx, i)` names each repeated id, until the next `begin`.

This is a breaking change from call-order ids: `blit.context.next_id` and
`Context.seq` are gone, and `begin_popup`, `begin_scroll`, `begin_dock`,
`blit.list.show`, `text_field`, `region_clicked`, `blit.chart.line`, `bars` and
`sparkline` take a key argument after the context.

## State store

State that must outlive a frame can live on the context, keyed by widget id.
`blit.state.get[T](?ctx, id)` returns the `T` that id keeps, zeroed the first
time it is asked for. One id can keep several types of state, each its own
entry, so a widget never reads another's bytes.

- **Lifetime.** The pointer is valid until `end`. Each `get` marks the entry
  reached, and `end` drops every entry no frame reached for `max_age` frames
  (`blit.state.MAX_AGE`, 60, by default; `set_max_age(?ctx, n)` changes it and
  0 keeps everything), so state for widgets that stopped drawing does not pile
  up. A `get` between frames counts toward the next frame.
  `pin[T](?ctx, id, 1)` keeps an entry however long it goes untouched, and
  `pin[T](?ctx, id, 0)` lets it age out again.
- **Failure.** Entries are allocator-backed and the store grows. When it cannot,
  `get` sets the context's oom (see `context.ok`) and hands back zeroed scratch
  state that every refused entry shares, never a dangling pointer. A state type
  is at most 1 KiB and 16-byte aligned, a compile error otherwise.
- **Persistence.** `register[T](?ctx, name, save, load)` makes `T` a persisted
  kind. `save(?ctx)` writes every entry of a registered kind into one TOML
  document, a `[<name>.<id>]` table per entry that the kind's save hook fills
  through `put_int`, `put_float`, `put_bool` and `put_str`. The text stays the
  context's until the next save. `load(?ctx, text)` reads such a document
  through `std.data.toml`, zeroes each entry and runs the kind's load hook over
  its table. Tables of unregistered kinds are skipped. A load hook copies any
  string it keeps, since the parsed document is freed when `load` returns.

The store is one owner, not the only one. Widgets that take a caller-owned
record (`Scroll`, `List`, `Field`) keep taking it, so an app can own
its state where it wants to.

## Menus

`blit.menu` draws a menu bar, the menus it drops, submenus and context menus.
A bar is the next item of the current layout frame, one row high across it.
Each menu's body runs every frame, open or not, so its items answer their
shortcuts while it is closed:

```mach
var bar:  blit.menu.Menu = blit.menu.begin_bar(?ctx, "main");
var file: blit.menu.Menu = blit.menu.begin_menu(?ctx, ?bar, "File");
var save: blit.menu.Item = blit.menu.of("Save");
save.shortcut = blit.menu.keys('S', blit.menu.MOD_PRIMARY);
if (blit.menu.item(?ctx, ?file, save)) { ... }
var recent: blit.menu.Menu = blit.menu.begin_menu(?ctx, ?file, "Recent");
blit.menu.item(?ctx, ?recent, blit.menu.of("notes.txt"));
blit.menu.end_menu(?ctx, ?recent);
blit.menu.end_menu(?ctx, ?file);
blit.menu.end_bar(?ctx, ?bar);

var cm: blit.menu.Menu = blit.menu.begin_context(?ctx, "canvas", x0, y0, x1, y1);
if (blit.menu.item(?ctx, ?cm, blit.menu.of("Cut"))) { ... }
blit.menu.end_menu(?ctx, ?cm);
```

- **Opening.** A bar header opens on a press, and while one is open, moving
  onto another opens that one. A submenu row opens its menu on hover. A context
  menu opens at the cursor on a right press over its region, or through
  `open_context`.
- **Items.** An `Item` carries a label, a `Shortcut` shown at its right, a
  check (`*u8`, flipped when it fires, nil when it is not checkable), an icon
  drawn before the label (text, such as a `blit.icon.STR_*` icon, nil for
  none) and a disabled flag.
- **Shortcuts.** An item fires when its key is pressed with exactly its
  modifiers, open or closed, and stays quiet while another widget holds the
  keyboard (`context.typing`). `MOD_PRIMARY` is the platform's command key:
  ctrl or super (see `input.shortcut`), shown as `Cmd` on darwin and `Ctrl`
  elsewhere.
- **Focus.** An open tree owns the keyboard: it takes the focus when it opens
  and gives it back to the previous holder the frame after it closes.
- **Keys.** The deepest open menu takes up and down (over enabled items),
  enter, right and left (into and out of submenus, and across a bar's headers)
  and escape.
- **Closing.** A click or enter on an item closes the whole tree, and so does
  a press of any button outside it, which is consumed.
- **Ids.** A bar's key, then each header and submenu label, then the item's
  label: `driver.find(?d, "main/File/Recent/notes.txt")`.

## Charts

`blit.chart` plots columns of values into a rect you give it, in the current
local space, and returns a `Hover` for the value under the cursor:

```mach
var energy: [64]f32;   # filled by you, oldest first
var income: [64]f32;
var series: [2]blit.chart.Series;
series[0]      = blit.chart.series(blit.chart.f32s(?energy[0]), 64);
series[0].fill = 1;
series[1]      = blit.chart.series(blit.chart.f32s(?income[0]), 64);
val hov: blit.chart.Hover = blit.chart.line(?ctx, "energy", x, y, w, h, ?series[0], 2, blit.chart.options());
if (hov.hot != 0) { ... }   # hov.index, hov.series, hov.x, hov.value

# profiler samples: u64 timestamps at uneven spacing, a counter that holds between them
var t:     [256]u64;
var bytes: [256]u64;
var heap:  blit.chart.Series = blit.chart.series(blit.chart.u64s(?bytes[0]), n);
heap.x     = blit.chart.u64s(?t[0]);
heap.shape = blit.chart.STEP;

blit.chart.bars(?ctx, "net", x, y, w, h, blit.chart.f32s(?net[0]), count, blit.chart.options());
blit.chart.sparkline(?ctx, "spark", x, y, w, h, series[0]);
```

- **Columns.** A `Column` is values of `F32`, `F64` or `U64` at `data + i *
  stride`, so packed arrays (`f32s`, `f64s`, `u64s`) and fields of an array of
  records (a stride of the record's size) plot alike, without copying.
- **Line.** Each series has its own `count` and, optionally, an `x` column of
  ascending positions, so spacing may be uneven and series need not share
  samples. Without `x`, sample `i` sits at `x = i`. `shape = STEP` holds each
  value until the next sample. A series with `fill` set fills the area between
  its line and zero.
- **Bars.** One bar per value in equal slots, up from zero when positive and
  down when negative. `Options.flush = 1` draws them with no gap.
- **Sparkline.** A compact series fitted to its values, with no axes, for a row
  or a cell. It keeps the series' x, shape and fill.
- **Exact values.** `Num` holds one exact value, `Num.f{f64}` or `Num.u{u64}`.
  An axis whose values are all u64 keeps an exact origin and steps its ticks in
  whole numbers, so timestamps and counters past 2^53 label and read out to the
  last digit. Hovers report `x` and `value` as `Num`.
- **Axes.** `Options.y` and `Options.x` are `Axis` records: fixed with
  `blit.chart.fixed(lo, hi)`, else fitted to the values. A fitted y axis is
  widened to whole ticks (linear bars always hold zero), a fitted x axis spans
  the samples edge to edge. `log = 1` spaces either axis by powers of ten, with
  a tick per decade or per few; values at or below zero sit at its floor. Bars
  label their first and last bar with a fixed `Options.x`, their index
  otherwise. Ticks step by 1, 2 or 5 times a power of ten and labels come from
  the glyph source, with k, M, G or T for large steps. `Options.axes = 0` gives
  the whole rect to the plot.
- **Hover.** A chart takes its id from its key and claims its plot, so it
  reads out only when it is the topmost claimant under the cursor, like any
  widget. A line reads, in each series, the sample nearest the cursor (for a
  step series the one whose value holds there) and reports the series nearest
  the cursor, bars report the slot under the cursor, and both draw a read-out
  of the value inside the plot. A sparkline reports and marks its sample.
- **Caller's cursor.** While a line chart is not hovered, `Options.cursor`
  places its vertical guide, marker and read-out at `cursor.x` on
  `cursor.series`. Feeding one chart's `Hover` (`x` and `series`) to the others
  keeps a cursor in step across charts, and a playhead is the same call.
- **Crisp at any scale.** A line is one quad per screen pixel column, the
  path swept by a square brush of `line_w`, so no sample is ever skipped when
  samples outnumber pixels. Columns, rules, bars and labels land on whole
  screen pixels, and every length is a theme metric at the context's scale.
- **Plain quads.** Charts emit through the painter like every widget, clipped to
  their rect and to any clip or sub-surface they sit in, and allocate nothing
  beyond their vertices and indices.

## Layers & input routing

Paint order and input order come from one key, so the widget that receives a
click is always the one visibly on top.

- **Bands.** Layers come in bands, listed bottom to top as data in
  `blit.band`: base content, docked content, floating windows, overlays,
  popups and menus, modals, tooltips and the drag preview. A layer is a band
  and a slot within it (`band.layer(b, slot)`, `band_of`, `slot_of`).
  `blit.context.push_band(?ctx, b, slot)` puts subsequent geometry and claims
  on a layer of band `b`, in screen coordinates with the clip reset to the
  screen, and `pop_band` returns. Each band picks the slot by its rule: a flat
  band shares one slot, a nesting band (popups, modals) stacks a child one
  slot above a parent of the same band, and an ordered band (windows) takes
  the slot given, a window's z. `end()` composes the draw list by layer,
  keeping call order within a layer, so a popup opened early in the frame
  still paints over a window called after it, and sibling popups share a
  layer. `run_at` reports each run's `layer`. `push_layer` and `pop_layer`
  remain, deprecated, as `push_band(?ctx, band.POPUPS, 0)` and `pop_band`.
- **Window order.** The context keeps the windows' z order:
  `blit.context.raise` hands out a z above every window and `note_z` notes
  one a window kept. Once z passes `Z_RENUMBER`, the windows renumber every
  z the store keeps, drawn this frame or not, and `restack` tells the context
  where they ended.
- **Channels.** A container that paints its background once its contents are
  known (a panel, window or popup) splits the runs drawn after it into
  channels: `ch = blit.context.split(?ctx, 2)`, `set_channel(?ctx, ch, 1)` for
  its children, then `set_channel(?ctx, ch, 0)` to draw its background and
  `merge(?ctx, ch)`. A lower channel paints beneath a higher one whatever the
  order they were drawn in, so the background can be any shape. Splits nest,
  and each is merged on the layer it was made on.
- **Claims.** Interactive widgets claim through `blit.interact.hit`, which calls
  `blit.context.claim(?ctx, id, x0, y0, x1, y1)`: it records the rect with the
  key (layer, then claim order) and returns whether the widget is hovered. Containers call `reserve_claim` before
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
handle through to the draw list's runs. `0` is reserved for the atlas.

- **Image.** `blit.draw.Image` is a handle, a source rect in uv and a filter.
  `blit.draw.region(tex, tw, th, x, y, w, h, filter)` builds one from a rect in
  texels, `whole(tex, filter)` covers the texture.
- **Drawing.** `blit.context.image_at(?ctx, img, x0, y0, x1, y1, tint)` stretches
  the region into a rect, clipped like any geometry by its run's scissor.
  `blit.widget.image(?ctx, img, w, h)` places it in the layout.
- **Grids.** `blit.widget.Grid` is a row-major field of cells, each colored by
  the consumer (`colors`) or by mapping `values` through a `Palette` of equal
  steps from `lo` to `hi`. `grid_at` fills a rect with it and `grid` places it
  at the cursor. Cells are solid quads on the atlas, so a small field needs no
  texture. A large one is better uploaded as a texture and drawn with
  `FILTER_NEAREST`.

## Shapes & paths

The painter draws shapes in the current local space, clipped by the run's
scissor like everything else. Every edge but a plain quad's is antialiased by
feathered geometry: a strip one pixel wide whose outer vertices carry no
color, so antialiasing needs nothing of the renderer beyond the contract
below. Curves and arcs stay within a quarter pixel of the true shape, so their
segment count follows their size on screen and the interface scale.

- **Rects.** `quad` fills a rect with one quad and `frame(?ctx, x0, y0, x1, y1,
  w, c)` outlines it with a band `w` wide inside its edges, both crisp on whole
  pixels. `rounded_rect` and `stroke_rounded_rect` take a radius per corner
  (`blit.draw.Radii`, `blit.draw.radii(r)` for all four), scaled down together
  when they would overlap. `fill` is a rounded rect with one radius on the
  corners `CORNERS_*` names.
- **Triangles, lines and arcs.** `tri` fills a triangle. `line` and
  `polyline(?ctx, ?pts[0], n, closed, w, join, c)` stroke `w` wide, centred on
  their points, ending square, with `blit.draw.JOIN_MITER`, `JOIN_BEVEL` or
  `JOIN_ROUND` at each corner (a miter past 4 half widths bevels). `circle`
  fills, `stroke_circle` rings inside the radius, and `arc(?ctx, cx, cy, r,
  a0, a1, w, c)` strokes from angle `a0` to `a1` in radians, clockwise on
  screen.
- **Paths.** `blit.path` builds contours of `move`, `line`, `quad` (quadratic),
  `cubic` and `close` commands into a `Path` the consumer owns:
  ```mach
  var p: blit.path.Path = blit.path.init(?a);
  blit.path.move(?p, 0.0::f32, 0.0::f32);
  blit.path.cubic(?p, 4.0::f32, -6.0::f32, 12.0::f32, -6.0::f32, 16.0::f32, 0.0::f32);
  blit.path.line(?p, 8.0::f32, 12.0::f32);
  blit.path.close(?p);
  blit.context.fill_path(?ctx, ?p, look.accent);
  blit.context.stroke_path(?ctx, ?p, 1.5::f32, blit.draw.JOIN_ROUND, look.text);
  ```
  A fill takes the nonzero rule, so a hole is a contour wound against its
  outline and crossing contours fill their union. Contours that overlap still
  show the faint feathers of the edges they hide, so icons are cleanest drawn
  as contours that meet without overlapping. A fill sweeps its edges once,
  sorted, so a large path such as a chart area or a text outline costs
  e log e in its edge count rather than e squared.
- **Gradients.** `blit.draw.gradient(x0, y0, c0, x1, y1, c1)` is a linear
  gradient in local space, clamped beyond its ends, drawn by `quad_gradient`,
  `rounded_rect_gradient` and `fill_path_gradient`.
- **Colors.** `blit.draw.hex(0xRRGGBB, alpha)` sits beside `blit.draw.rgba`.

## Icons

`blit.icon` is a set of icons drawn from path data, with no font or image
behind them, so they scale to any size and take any color: `PLAY`, `PAUSE`,
`STEP`, `STOP`, `CLOSE`, `CHEVRON_UP`, `CHEVRON_DOWN`, `CHEVRON_LEFT`,
`CHEVRON_RIGHT`, `PLUS`, `MINUS`, `SEARCH`, `SETTINGS`, `HELP`, `PIN` and the
dock drop targets `DOCK_CENTER`, `DOCK_LEFT`, `DOCK_RIGHT`, `DOCK_TOP` and
`DOCK_BOTTOM`.

```mach
blit.context.icon_at(?ctx, blit.icon.SETTINGS, x, y, 24.0::f32, look.text);
blit.widget.button(?ctx, blit.icon.STR_PLAY);   # an icon for a label
blit.widget.button(?ctx, "\xF3\xB0\x80\x82 step"); # inline with text
```

- **Path data.** An icon (`blit.icon.Icon`) is a flat `f32` stream of path
  commands and the box it was drawn in. Each command is its verb
  (`blit.path.MOVE`, `LINE`, `QUAD`, `CUBIC` or `CLOSE`, as a float) followed
  by its coordinates: two for a move or line, four for a quadratic (control,
  then end), six for a cubic (both controls, then end) and none for a close.
  It is filled by the nonzero rule, scaled from its box to the size drawn.
  The built-ins sit on a `blit.icon.BOX` (16) square, their contours meeting
  without overlapping.
- **Drawing.** `icon_at(?ctx, id, x, y, size, c)` draws an icon `size` pixels
  tall with its box's top-left at `(x, y)`, feathered and clipped like any
  path. `icon_width(?ctx, id, size)` is the width it takes.
- **Inline with text.** Every icon id is a codepoint, `blit.icon.CODEPOINT_BASE`
  (U+F0000) plus the id, in supplementary private use area A. Text holding
  one draws the icon in place, a line tall (the style's ascent and descent),
  tinted with the text, and measures it the same way, so labels, buttons and
  every other text call take icons with no change. `blit.icon.STR_*` is each
  built-in as a UTF-8 string, and `blit.icon.encode(id, ?buf[0], 4)` writes any
  id's. A codepoint in that range with no icon goes to the glyph source as
  before.
- **Your own icons.** `blit.context.add_icon(?ctx, icon)` registers an icon in
  the same form, in a box of any size, copying its data, and returns its id,
  from `blit.icon.APP_FIRST` (0x1000) up, so a later built-in never moves it.
  Malformed data or an empty box is refused.
  ```mach
  val TRI: [10]f32 = [10]f32{0.0, 0.0, 0.0, 1.0, 24.0, 12.0, 1.0, 0.0, 24.0, 4.0};
  val id: opt[u32] = blit.context.add_icon(?ctx, blit.icon.Icon{data: ?TRI[0], n: 10, w: 24.0::f32, h: 24.0::f32});
  ```

## Rendering

blit emits one indexed triangle list that draws solid shapes and text through
a single shader per texture. Solid shapes sample a white block every atlas
page carries, so `color * texel` is the flat color, and glyphs sample their
cell. Colors and texels are premultiplied.

- **Buffers.** After `end`, upload the vertices (`draw_verts` / `draw_count`,
  `blit.draw.Vert`) and the u32 indices (`draw_indices` / `index_count`), three
  per triangle, in composed paint order. Vertices stay in the order they were
  drawn. Only the indices are reordered to paint layers and channels.
- **Runs.** `run_count` / `run_at` divide the index list into runs, in paint
  order. A `Run` is plain numbers: `kind` (u32), `tex` (u64), `page`, `layer`
  and `filter` (u32), the scissor `clip_x0`, `clip_y0`, `clip_x1`, `clip_y1`
  (f32), `start` and `count` (usize, in indices), and for a consumer span
  `id` and `data` (u64) and its rect `x0`, `y0`, `x1`, `y1` (f32). Every index
  lies in one run. Draw the runs in order:
  - **Kind.** `blit.context.RUN_TRIANGLES` (0): bind, scissor and draw as
    below. `blit.context.RUN_CUSTOM` (1) is a consumer span (see below). Skip a
    run of any other kind, so later kinds need no change to a renderer that
    ignores them.
  - **Texture.** When `tex` is `blit.draw.ATLAS` (0), bind atlas page `page`.
    Otherwise `tex` is the consumer's own texture handle, passed through
    untouched, and `filter` asks for `FILTER_NEAREST` (0) or `FILTER_LINEAR` (1)
    sampling. On the atlas `filter` is always `FILTER_NEAREST` and how to sample
    it stays the renderer's choice. Rebind only when `tex`, `page` or `filter`
    change.
  - **Scissor.** The clip is in screen pixels, y down, the space vertices are
    in. Round each edge to the nearest pixel, scale by the framebuffer's pixels
    per screen pixel when they differ, and in GL flip y:
    `glScissor(x0, fb_h - y1, x1 - x0, y1 - y0)`. Set it whenever it changes,
    with `GL_SCISSOR_TEST` enabled.
  - **Draw.** `glDrawElements(GL_TRIANGLES, count, GL_UNSIGNED_INT,
    start * 4)`: indices are absolute vertex numbers, so no base vertex.
  - **Consumer spans.** A `RUN_CUSTOM` run holds no indices (`count` 0). Set
    its scissor, call the app's own drawing for `id` with `data` and the rect
    (`x0`, `y0`, `x1`, `y1`, screen pixels, y down), then restore blit's state
    (program, buffers, blend, texture binding) before the next run.
    `blit.context.custom(?ctx, x0, y0, x1, y1, id, data)` places one: the rect
    is in local space like every rect, it takes the current clip and layer,
    and it sorts like any run, so a popup on a higher layer, or anything drawn
    after it, paints over it. `id` and `data` are passed through untouched.
- **State.** Blend premultiplied: `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`.
  Disable face culling (triangles come in either winding) and depth testing.
- **Atlas.** `blit.context.atlas_of(?ctx)` is the glyph atlas: `page_count`
  pages, each an RGBA8 square of `blit.atlas.PAGE_SIDE` (512) texels at
  `page_pixels(at, i)`, premultiplied (a glyph's coverage in all four channels,
  the white block opaque). Pages open as glyphs arrive and never resize, and
  past `blit.atlas.PAGE_MAX` (16) the least recently drawn one is cleared and
  reused, wholly dirty. Each has a `page_version` bumped on every write and a
  `page_dirty` rect: upload the dirty rect of each changed page before drawing,
  then `page_clean` it. Every glyph has a transparent gutter, so linear
  filtering is safe. The built-in font at whole scales looks sharpest with
  nearest.
- **Consumer textures** are sampled as premultiplied alpha: upload them
  premultiplied.
- **Color.** Colors are authored as straight rgba and premultiplied as they are
  emitted. When the target encodes sRGB on write, call
  `blit.context.set_srgb(?ctx, 1)`: every color is then converted to linear
  light before premultiplying, so the encoding brings it back to what was
  authored. Alpha is never converted. Each distinct color is converted once and
  cached on the context (`blit.draw.LinearCache`), so sRGB output costs next to
  nothing. Gradients interpolate the emitted colors.
- **Vertex.** `blit.draw.Vert` is 8 `f32`, 32-byte stride: `aPos` (vec2) at 0,
  `aUV` (vec2) at 8, `aColor` (vec4) at 16. Positions in pixels, uv in [0, 1],
  premultiplied rgba.
- **Shader.** One `vec2 uScreen` uniform:
  ```glsl
  gl_Position = vec4(aPos.x / uScreen.x * 2.0 - 1.0,
                     1.0 - aPos.y / uScreen.y * 2.0, 0.0, 1.0);
  FragColor   = aColor * texture(atlas, aUV);
  ```
- **Per frame.** Fill an `Input` (`mx`, `my`, `down`, `wheel`, the keyboard
  and button events and any `paste`), `begin`, widgets, `end`, hand `copied` to the
  clipboard and answer `wants_paste`, upload the changed atlas pages, the
  vertices and the indices, and draw each run as above.
- **From 0.9.** A renderer written for the 0.9 contract changes in these
  places, and the atlas upload, the vertex layout and the shader stay as they
  were:
  - upload the index buffer and draw each run with `glDrawElements` over
    `start` and `count`, which now count indices, where it drew arrays
  - apply each run's scissor
  - blend `ONE` / `ONE_MINUS_SRC_ALPHA` where it blended `SRC_ALPHA` /
    `ONE_MINUS_SRC_ALPHA`, and leave face culling off
  - call back into the app for `RUN_CUSTOM` runs, and skip runs of any other
    kind that is not `RUN_TRIANGLES`
  - upload consumer textures premultiplied

## Testing with the driver

`blit.driver` runs an interface headless, the way blit's own tests do, so an
app built on blit can test its interface. A `Driver` owns a context and an
input, a screen size and a clock, and runs the interface through a callback
between `begin` and `end`, one frame per `step`:

```mach
fun ui(ctx: *blit.context.Context, user: ptr) {
    val app: *App = user::*App;
    # ... widgets, as in a frame, without begin and end ...
}

var d: blit.driver.Driver;
val made: err[allo.Error] = blit.driver.init(?d, ?a, 800.0::f32, 600.0::f32, ui, (?app)::ptr);
blit.driver.step(?d);                               # lay out once
val save: u64 = blit.driver.find(?d, "Settings/Save");
blit.driver.click(?d, save);
blit.driver.click(?d, blit.driver.find(?d, "Settings/name"));
blit.driver.type_text(?d, "untitled");
blit.driver.key(?d, blit.input.KEY_ENTER, 0);
if (!str_equals(blit.driver.text_of(?d, save), "Save")) { ... }
blit.driver.free(?d);
```

- **Finding.** `find(?d, path)` is the id a label path names from the root
  (see Widget ids), `at(?d, x, y)` the widget a pointer there reaches and
  `inside(?d, x0, y0, x1, y1)` the topmost widget drawn wholly inside a rect.
  Any id works, `blit.context.id_of` and `blit.id.child` included.
- **Acting.** `hover`, `click`, `double_click`, `right_click` and
  `click_with(?d, id, button)` move the pointer onto the widget's centre in a
  frame of their own, since input routes by the previous frame's claims, then
  press and release a frame each. `drag(?d, id, x, y)` presses on the widget
  and moves to the point in `DRAG_STEPS` held frames before releasing, and
  `drag_onto(?d, id, target)` drops on another widget's centre. `scroll(?d,
  id, dx, dy)` turns the wheels over a widget, `type_text(?d, s)` types text in
  one frame, and `key(?d, code, mods)` presses a key in one frame and releases
  it in the next. `move`, `leave`, `press` and `release` drive the pointer and
  buttons by hand, a frame each, and a press or release is sent as a button
  event at the pointer as well as in `down`. An action on a widget the last frame did not draw runs
  nothing and returns false.
- **Frames.** Each step carries the clock (`d.time`, advanced by `d.dt`, 1/60
  s by default) and clears the frame's key events, wheel and paste, so input
  set between steps lands in exactly one frame. `d.ctx` and `d.in` are the
  context and input, free to read and set between steps.
- **Queries** read the last frame: `drawn`, `rect` (the screen rect the widget
  claimed, clipped, none when it was not visible), `hot`, `active` and
  `focused`, and `text_in(?d, x0, y0, x1, y1)` and `text_of(?d, id)`, the
  text drawn inside a rect or a widget's rect. Text lines whose box has its
  centre inside are joined in drawing order: directly when one continues the
  last on its row, by a space further along the row, by a newline otherwise.
- **Snapshots.** `snapshot(?d)` is a stable text dump of the last frame's draw
  list for golden comparison: the screen size, then each run with its kind,
  texture, page, layer, filter and scissor. A consumer span adds its callback
  id, data and rect, and any other run its triangle count, followed by its
  geometry one shape a line. A flat-coloured, axis-aligned rect is a `quad`
  (its corners' position and uv, then its colour), anything else a `tri` of
  three vertices. Positions print to two decimals, uvs to four, colours as
  the premultiplied 0 to 255 channels emitted.

The driver's text (`text_in`, `text_of`, `snapshot`) stays valid until the
next of those calls. The context underneath keeps per-widget rects from its
claims (`blit.context.rect_of`, `widget_at`, `widget_in`) and, while
`set_trace(?ctx, 1)` is on, every drawn line of text (`traced_count`,
`traced_at`), off by default so an app's frames pay nothing for it.

## Build & test

```
mach dep pull .
mach build .
mach test .
```

`demo/harness/` is its own project with a path dependency on this checkout. It
drives a headless frame end to end through a bare `use blit;` and prints the
vertex, index and run counts and atlas pages. It takes std from this checkout's `dep/std`, so
pull the root first:

```
mach dep pull demo/harness
mach build demo/harness
demo/harness/out/linux-x86_64/debug/bin/harness
```

`demo/panel/` builds and runs the same way, driven by `blit.driver`. Its
test compares the scripted panel's last frame with the golden snapshot
`demo/panel/src/bin/panel.snap`, and `panel --snapshot` prints a new one when
a change to the draw list is meant. `mach dep pull demo/panel` again after
changing blit, since a demo builds against its pulled copy:

```
mach test demo/panel
demo/panel/out/linux-x86_64/debug/bin/panel --snapshot > demo/panel/src/bin/panel.snap
```

## Benchmark

`demo/bench/` measures blit's per-frame cost on a few representative
interfaces: a dock of eight open sections of controls, a list of 10,000 rows, a
line chart of 100,000 samples, and six overlapping windows each holding a
section and a scroll region. Each scene runs with sRGB output off and then on,
and the table reports the mean frame time, the vertices and runs the frame
emits, the allocations a frame makes, and what sRGB adds. It is local only,
never a CI job. Build it in the release profile:

```
mach dep pull demo/bench
mach build demo/bench -p release
demo/bench/out/linux-x86_64/release/bin/bench
```

Baseline at 0.9.0 on an AMD Ryzen 7 5800X3D, to compare later work against:

```
scene          srgb    us/frame  vertices  runs  allocs   srgb cost
dense panel    off        292.4      5298     1       0
dense panel    on         295.6      5298     1       0   +1.0%
10k row list   off        123.6      1704     1       0
10k row list   on         124.1      1704     1       0   +0.4%
100k chart     off       1924.6     15738     1       0
100k chart     on        1966.7     15738     1       0   +2.1%
windows        off        273.9      5472     1       0
windows        on         277.5      5472     1       0   +1.3%
```

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
