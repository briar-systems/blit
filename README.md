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
`blit.input`, `blit.layout`, `blit.hit`, `blit.band`, `blit.interact`, `blit.field`, `blit.edit`, `blit.ease`, `blit.writer`, `blit.theme`, `blit.style`, `blit.context`, `blit.state`, `blit.anim`, `blit.text`, `blit.widget`, `blit.menu`, `blit.controls`, `blit.value`, `blit.color`, `blit.table`, `blit.textarea`, `blit.chart`, `blit.payload`, `blit.dnd`, `blit.tabs`, `blit.dock`, `blit.driver`, `blit.editor`, `blit.inspect`. A submodule can also be
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

Every color and length a widget draws with comes from a theme
(`blit.theme.Theme`) in two layers. The **tokens** are what a look is designed
in: a palette (`panel`, `window`, `text`, `text_dim`, `text_faint`, `accent`,
`control`, `track`, `handle` and the rest) and metrics (`row`, `gap`, container
padding `pad`, control inset `inset`, `corner`, `edge_w`, ...). The **styles**
are one `blit.theme.Style` per registered widget kind (`blit.theme.BUTTON`,
`SLIDER`, `WINDOW_TITLE`, `MENU_ITEM`, ...): its corner radii, padding, inset, margins,
least sizes and shadow, and a `Paint` per state (`NORMAL`, `HOT`, `ACTIVE`,
`ON`, `DISABLED`, `FOCUSED`) with its fill, gradient end, text, secondary mark,
border and shadow colors. Widgets draw from the styles alone, and no widget
holds a color or a size of its own. Charts read the `plot` fields (`series`,
`line_w`, `tick`, `area`) as they are, and animation the `motion` fields
(`hover_time`, `hover_ease`, `open_time`, `open_ease`, `scroll_time`,
`scroll_ease`: seconds, and a `blit.ease` curve, 0 linear, 1 out, 2 in and
out) through `blit.theme.motion` (see Animation). The tokens `focus` and
`focus_w` derive the `focus_ring` kind, the ring the control the keyboard
reached wears.

`blit.theme.derive(?t)` builds every style from the tokens, so after changing
tokens in code, derive. `theme.set` changes one field, and for a token it
moves every style field that took its value from the old token while keeping
the ones set by hand (`rederive`).

```mach
val look: *blit.theme.Theme = blit.context.theme_of(?ctx);
blit.theme.dark(look);
look.accent = blit.draw.rgba(0.37::f32, 0.83::f32, 0.63::f32, 1.0::f32);
look.corner = 3.0::f32;
blit.theme.derive(look);
blit.theme.style(look, blit.theme.BUTTON).states[blit.theme.HOT].fill_to = blit.draw.hex(0x2A2E37, 1.0::f32);
blit.context.set_scale(?ctx, 2.0::f32);
```

- **Zero configuration.** A context sets its theme up with the default look,
  and `theme_of` hands back the live one to adjust in place. A theme of your
  own is set up with `blit.theme.init(?t, ?a)`, released with `free`, and
  copied into a context with `blit.context.set_theme(?ctx, ?t)`. `warn` is
  there for consumers drawing their own content in the same palette. No
  widget uses it.
- **Built-in themes.** `default(t)` is blit's own look (dark, square, 4 pixel
  spacing), `dark(t)` a rounded dark look with shaded buttons and shadows
  under floating surfaces, `light(t)` a light one and `contrast(t)` a
  high-contrast one with outlined controls and wide focus rings. Each gives a
  theme its look in place, keeping its kinds, and `builtin(t, name)` and
  `BUILTIN_NAMES` reach them by name.
- **Kinds are a registry.** `blit.theme.register_kind(t, name, doc, derive)`
  adds a widget kind and returns its handle: `derive(t, kind, ?style)` builds
  its style from the tokens, starting from `blit.theme.base(t)`, and runs
  again whenever the styles are derived. The built-in kinds are registered
  the same way when a theme is set up, in the order of their constants. A
  registered kind is addressable by its name everywhere a built-in one is:
  paths, wildcards, TOML tables, classes and the editor. A module adds kinds
  of its own this way, as `blit.dock` does (`dock_space`, `dock_splitter`,
  `dock_zone`, `dock_preview`, see `dock.register_kinds`).
- **The box painter.** `blit.context.box(?ctx, kind, state, x0, y0, x1, y1)`
  paints a kind in a state with the shapes of Shapes & paths: its shadow (a
  rounded rect faded over `shadow_blur`), a flat face, or a vertical gradient
  when `fill_to` differs from `fill`, and its outline. `box_part` rounds only
  some corners and outlines some sides, and `box_shadow` and `box_face` paint
  the two halves apart. A custom widget paints through it and looks like the
  built-ins. `blit.theme.pick(hot, active, on, focused)` is the state they
  paint in: on, then focused, then active, then hot.
- **One scale.** `set_scale` multiplies every theme length and the size text is
  laid out and rasterised at (see glyph sources), so 2.0 doubles the whole
  interface, layout and hit rects included, for a HiDPI display or a user's
  choice. Lengths you pass (panel and window widths, dock sizes, your own
  geometry) stay in pixels. `blit.context.px(?ctx, v)` scales them to match.
  `blit.widget.row_gap(?ctx)`, `text_row_height`, `control_row_height` and
  `control_height` (a control row without its gap) report the spacing at the
  current theme and scale.
- **Rows fit their text.** A control row is its style's `min_h` tall, or a
  line of text plus its `inset` above and below if that is taller, so a
  larger glyph source never overflows its rows.

### Overrides and classes

Every field has a path: `palette.accent`, `metrics.gap`, `plot.series.3`,
`button.radius` for a style field and `button.hot.fill` for a paint field,
with `*` for every kind or state. `blit.style` pushes a value onto every field
a path names until the matching pop, so a scope of widgets draws differently
and nothing else does:

```mach
blit.style.push_color(?ctx, "button.*.fill", blit.draw.hex(0xB03030, 1.0::f32));
blit.style.push_length(?ctx, "*.*.border_w", 0.0::f32);
blit.widget.button(?ctx, "delete");
blit.style.pop(?ctx);
blit.style.pop(?ctx);
```

`push_color`, `push_length`, `push_radii`, `push_edges` and the untyped `push`
refuse a path naming no field of their unit, and still open an empty push so
every push pairs with its pop. A frame left with pushes open is restored at
the next `begin`.

A class is a named list of such settings, applied to a widget call with
`push_class` and `pop`:

```mach
val danger: opt[u32] = blit.style.add_class(?ctx, "danger");
blit.style.set(?ctx, danger.some, "button.*.fill", blit.theme.of_color(red));
blit.style.set(?ctx, danger.some, "button.hot.fill", blit.theme.of_color(bright_red));
# per frame:
blit.style.push_class(?ctx, danger.some);
blit.widget.button(?ctx, "delete");
blit.style.pop(?ctx);
```

### Themes as TOML

Themes are TOML, read with `std.data.toml` and written with `blit.writer`.
`blit.style.load_theme(?ctx, text)` replaces the context's theme with one a
document describes, and reads its classes, so a running interface reloads its
look whenever the host reads the file again. `save_theme(?ctx)` writes the
theme and the classes back out. `blit.theme.load(t, text)` and `save` read and
write a theme alone. A document styles a registered kind by name, and a kind
not registered when it is read is refused like any unknown key, so a host
registers its kinds before loading.

```toml
base = "dark"            # a built-in to start from, default when absent

[palette]                # tokens: every style built from one follows it
accent = "#5b9dff"

[metrics]
corner = 6

[plot]
series = ["#5b9dff", "#f0a040"]

[button]                 # a kind's style fields
inset = [8, 4, 8, 4]     # one length for every side, or left, top, right, bottom

[button.hot]             # a kind's paint fields in a state
fill = "#3a4050"
fill_to = "#2a2e37"

["*".focused]            # every kind
border_w = 2.0

[class.danger]           # a class: paths and their values
"button.*.fill" = "#b03030"
```

Colors are `#rgb`, `#rrggbb` or `#rrggbbaa`, or an array of three or four
numbers in [0, 1]. A key naming no field, kind or state, a value that does not
fit its field and a `base` naming no built-in are refused with their byte
offset in the document (`blit.theme.LoadError`), and a refused theme changes
nothing. A save writes the tokens and `plot` in full and a style field only
where it differs from what the tokens derive, colors in hex when hex holds
them exactly, so the file stays short and reads back to the same theme
exactly.

### Theme editor

`blit.editor.theme_editor(?ctx, key, h)` edits the context's live theme with
blit's own widgets: built-in themes by button, a group (the palette, the
metrics, the chart fields or a widget kind) and a state by dropdown, and the
group's fields in a scrolling list `h` pixels tall, each with its meaning from
the field table and a slider per float. It returns `blit.editor.EDITED` on a
frame an edit changed the theme and `SAVE` when its save button was pressed,
and the host writes `blit.style.save_theme(?ctx)` wherever it keeps themes.

### Theme fields

The field table (`blit.theme.FIELDS`) is the one source of the paths, units
and meanings below: TOML, overrides, classes and the editor read it, and a
test holds this README's copy to it (`blit.theme.document` writes it). The
kind table lists the built-in kinds; a registered kind carries its own
meaning, which `document` lists for the theme it is given and the editor
shows.

| path | unit | meaning |
|---|---|---|
| `palette.panel` | color | panel background, opaque in the built-in themes |
| `palette.window` | color | window, popup, menu, tooltip, toast and modal background, opaque in the built-in themes |
| `palette.dock` | color | docked container background |
| `palette.header` | color | window titlebar and section heading |
| `palette.header_hot` | color | a titlebar or heading under the cursor |
| `palette.edge` | color | a dock's inner edge and a separator's rule |
| `palette.text` | color | text |
| `palette.text_dim` | color | secondary text and glyphs: notes, readings, carets, axis labels |
| `palette.text_faint` | color | the faintest text: hints, placeholders and disabled text |
| `palette.accent` | color | a mark that is on (a checked box, a chosen button, a selected row) and a focused field's outline |
| `palette.accent_text` | color | text and marks drawn on an accent fill |
| `palette.warn` | color | warnings, for consumers drawing their own content; no widget uses it |
| `palette.control` | color | a control's face at rest |
| `palette.control_hot` | color | a control under the cursor |
| `palette.control_on` | color | a control pressed, a dropdown open or a menu's header open |
| `palette.track` | color | a slider, toggle, scrollbar, progress or tab bar track, an option row at rest and a text field's face |
| `palette.handle` | color | a slider handle, toggle knob or scrollbar thumb at rest |
| `palette.handle_on` | color | a handle, knob or thumb being dragged or hovered |
| `palette.select` | color | the highlight behind selected text, translucent in the built-in themes |
| `palette.grid` | color | chart grid lines |
| `metrics.row` | length | least height of a control row, which grows to fit a line of text and its inset |
| `metrics.gap` | length | space between layout rows, cells and buttons in a row |
| `metrics.pad` | length | container padding: below a panel's, window's, popup's or menu's content, around a dock's column, and between a scrollbar and its content |
| `metrics.inset` | length | control inset: between a control's edge and its text, and between a box and its label |
| `metrics.handle_w` | length | slider handle width |
| `metrics.bar_w` | length | scrollbar width |
| `metrics.thumb_min` | length | shortest scrollbar thumb |
| `metrics.corner` | length | corner radius of controls and containers, 0 for square |
| `metrics.edge_w` | length | width of an edge line: a dock's inner side, a chart's rules and a focused field's outline |
| `metrics.caret_w` | length | width of a text field's caret |
| `palette.focus` | color | the ring around the control the keyboard reached |
| `metrics.focus_w` | length | width of the focus ring |
| `plot.series` | color x 8 | chart series colors, series k drawing in series[k % 8] |
| `plot.line_w` | length | width of a chart line |
| `plot.tick` | length | length of a chart axis tick |
| `plot.area` | factor | alpha factor of the area filled under a chart line, in [0, 1] |
| `motion.hover_time` | factor | seconds a control's face takes to follow hover and press, 0 for at once |
| `motion.hover_ease` | factor | the curve a hover or press transition eases by: 0 linear, 1 out, 2 in and out |
| `motion.open_time` | factor | seconds a section takes to unfold or fold, 0 for at once |
| `motion.open_ease` | factor | the curve a section folds by: 0 linear, 1 out, 2 in and out |
| `motion.scroll_time` | factor | seconds a scroll region takes to glide to a new offset, 0 for at once |
| `motion.scroll_ease` | factor | the curve a scroll glide eases by: 0 linear, 1 out, 2 in and out |
| `<kind>.radius` | 4 lengths | corner radii: top-left, top-right, bottom-right, bottom-left |
| `<kind>.pad` | 4 lengths | container padding between its edges and its content: left, top, right, bottom |
| `<kind>.inset` | 4 lengths | control inset between its edges and its text: left, top, right, bottom |
| `<kind>.margin` | 4 lengths | space around the widget: left, top, right (between cells), bottom (between rows) |
| `<kind>.min_w` | length | least width |
| `<kind>.min_h` | length | least height, a control's row height before it grows to fit its text |
| `<kind>.shadow_x` | length | shadow offset right |
| `<kind>.shadow_y` | length | shadow offset down |
| `<kind>.shadow_blur` | length | how far the shadow fades out, 0 for a hard edge |
| `<kind>.<state>.fill` | color | the face, at its top when it is a gradient |
| `<kind>.<state>.fill_to` | color | the face at its bottom: equal to fill for a flat face, else a vertical gradient |
| `<kind>.<state>.text` | color | text drawn on the face |
| `<kind>.<state>.mark` | color | secondary ink: a glyph, a caret, a reading or a hint |
| `<kind>.<state>.border` | color | the outline, transparent for none |
| `<kind>.<state>.border_w` | length | the outline's width |
| `<kind>.<state>.shadow` | color | the shadow's color, transparent for none |

| kind | what it styles |
|---|---|
| `label` | a line of text, and a wrapped note in mark |
| `layout` | layout itself: margin.b between items down a column, margin.r between cells, columns and items across a row |
| `panel` | a panel's background, pad around its column |
| `window` | a window's body and its shadow, pad around its column, margin the resize grips outside its edges |
| `window_title` | a window's titlebar: text the title, mark the collapse glyph, hot under the cursor |
| `dock` | a docked panel: fill the body, border its inner edge, pad around its column |
| `popup` | a popup's body, such as a dropdown's options |
| `button` | a button, on when drawn chosen; margin.r between buttons in a row |
| `checkbox` | a checkbox's box: pad around the mark, inset.l between the box and the label |
| `checkbox_mark` | a checkbox's mark, drawn in its on state |
| `toggle` | a toggle's switch track and label, on while set: pad between the row and the track |
| `toggle_knob` | a toggle's knob, in the toggle's state: margin between the knob and the track |
| `slider` | a slider's track: text the label, mark the reading |
| `slider_handle` | a slider's handle: min_w its width |
| `dropdown` | a dropdown's header, on while open |
| `field` | a text field: mark the hint, focused while it holds the keyboard |
| `field_caret` | a text field's caret and its composition underline: fill, min_w the width |
| `field_select` | the highlight behind selected text: fill |
| `section` | a collapsible section heading: mark the caret, min_w its size, 0 to follow the caption's ascent |
| `scrollbar` | a scrollbar's track: min_w its width, margin.l between it and the content |
| `scrollbar_thumb` | a scrollbar's thumb: min_h its least length |
| `list` | a list's body |
| `list_item` | a list's row, on while selected |
| `chart` | a chart: border the grid, mark the axes, ticks, labels and hover guide, inset around labels, margin.r between bars |
| `tab` | a tab, on while chosen, and a tab bar's overflow buttons, disabled when they cannot act: margin.r between tabs |
| `tooltip` | a tooltip, and a chart's read-out: pad around its content, inset around a read-out's text, margin.t below the widget it describes |
| `menu` | a menu's body, pad around its rows, min_w its least width |
| `menu_item` | a row of a menu, on while its submenu is open: mark its shortcut and arrow, inset.l its indent |
| `overlay` | an overlay, chrome-free unless its style gives it a fill or a border: pad around its content |
| `modal` | a modal dialog's body |
| `scrim` | the scrim over everything behind a modal dialog, translucent in the built-in themes |
| `radio` | a radio button's ring: pad around the dot, inset.l between the ring and the label |
| `radio_mark` | a radio button's dot, drawn in its on state |
| `progress` | a progress bar's track and its text |
| `progress_bar` | a progress bar's done part |
| `separator` | a separator: border its rule and border_w the rule's width, mark a label, inset.r between label and rule |
| `tree_item` | a tree's row, on while selected: mark the caret |
| `drop_target` | where a drag would drop: fill and border |
| `drag_preview` | what a drag carries, drawn at the cursor |
| `menu_bar` | a menu bar's background |
| `menu_title` | a menu's header in a menu bar, on while its menu is open |
| `option` | a row of a dropdown's or a tab list's options, on while chosen |
| `tab_bar` | a tab bar's strip behind its tabs |
| `tab_close` | a tab's close box: fill under the cursor, border_w the cross's stroke |
| `table_header` | a table's header row and cells: mark the sort arrow, inset around labels, min_w a column's least width |
| `table_cell` | a table's body cell: inset around its widgets, its row height from min_h and inset |
| `table_rule` | a table's column and frozen-row rules: border and border_w, hot over a resize grip, min_w the grip's width |
| `value` | a value editor's drag cell: inset around its text and before its row's cells, min_w its least width |
| `picker` | a color picker: text its label, mark and border a marker's inner and outer rings, inset.l between swatch and label |
| `checker` | the checkerboard alpha shows through: fill and mark its two cells |
| `toast` | a toast's card: pad around its text, margin between the stack and the surface's edges |
| `focus_ring` | the ring around the control the keyboard reached: border and border_w its stroke, radius its corners |

| state | when |
|---|---|
| `normal` | at rest |
| `hot` | under the cursor |
| `active` | pressed or dragged |
| `on` | set: checked, chosen, selected or open |
| `disabled` | drawn but not taking input |
| `focused` | holding the keyboard |

## Animation

Motion is state: `blit.anim` keeps animated values in the store under ids
(see State store), so a widget animates by asking each frame for its value
with the target it wants, and the value eases from wherever it stands to the
target on the host's clock (`in.time`).

```mach
val id:   u64 = blit.context.id_of(?ctx, "drawer");
val open: f32 = blit.anim.value(?ctx, id, target, blit.theme.MOTION_OPEN); # eased toward target
val hot:  f32 = blit.anim.fade(?ctx, blit.id.child(id, "#hot"), h.hot, blit.theme.MOTION_HOVER);
val face: blit.draw.Color = blit.anim.mix(rest, hover, hot);
```

- **Built in.** A control's face eases between the paints of the states it
  passes through (`anim.box(?ctx, id, kind, state, x0, y0, x1, y1)`, as
  `context.box` paints one state, and `anim.paint` for the paint alone), a
  toggle's knob slides, a section opened with
  `begin_section` unfolds and folds (see Widgets & layout), and a scroll
  region glides to where the wheel, a key or the keyboard focus sent it.
- **Values.** `value(?ctx, id, target, kind)` is timed by the theme's motion
  of a kind and `toward(?ctx, id, target, motion)` by a `theme.Motion` of the
  caller's. A value seen for the first time starts at its target, and a new
  target mid-run turns back from where the value stands, so nothing jumps.
  `fade(?ctx, id, on, kind)` is a 0 to 1 value from 0 that keeps no state at
  rest, for hovers. `snap` puts a value at once (a value dragged under the
  pointer), `running` says whether one moves, and `lerp` and `mix` blend
  numbers and colors.
- **Timing.** Each kind of motion, `theme.MOTION_HOVER` (hover and press),
  `MOTION_OPEN` (sections) and `MOTION_SCROLL` (scroll glides), takes its
  duration and `blit.ease` curve (`LINEAR`, `OUT`, `IN_OUT`) from the theme's
  `motion` fields, paths such as `motion.hover_time`, so TOML, overrides and
  the editor reach them like any field. Every widget reads them through
  `anim.timing(?ctx, kind)` alone.
- **Reduced motion.** `blit.context.set_reduce_motion(?ctx, 1)` makes every
  animation jump straight to its end, as a host passes on its platform's
  setting. A host that never advances `in.time` gets the same.
- **Sleeping.** A value asks for frames through `wake_at` only while it
  moves, so an interface whose animations have all settled reports `none`
  from `next_frame` and an idle host sleeps.

## Docking

`blit.dock` docks windows into a dock space, Dear ImGui style: a space fills
a rect with a tree of splits and tab stacks, windows dragged over it dock
into it, and tabs dragged out of it float again.

```mach
# once: the layout saves and loads with the windows
blit.dock.persist(?ctx);
blit.widget.persist_windows(?ctx);

# per frame: a default layout while there is none, such as before a load
val sid: u64 = blit.context.id_of(?ctx, "main");
if (blit.dock.empty(?ctx, sid)) {
    val root: u64 = blit.dock.root(?ctx, sid);
    val left: u64 = blit.dock.split(?ctx, root, blit.context.Side.left{}, 0.25);
    blit.dock.add(?ctx, left, blit.context.id_of(?ctx, "Scene"));
    blit.dock.add(?ctx, root, blit.context.id_of(?ctx, "Viewport"));
}
# the space first, then its windows, exactly as they are drawn floating
blit.dock.space(?ctx, "main", blit.context.free_area(?ctx));
val w: blit.widget.WindowArea = blit.widget.begin_window(?ctx, scene);
if (w.body != 0) { ... }
blit.widget.end_window(?ctx, w);
```

- **The tree.** A split node divides its rect between two children along an
  axis by a ratio, and a leaf is a tab stack of windows. `root`, `split` (a
  new empty leaf on one side of a node, taking a share of it), `add` (dock a
  window as a leaf's last tab), `insert` (dock it at an index in the leaf's
  tab stack), `select` (bring a docked window to its leaf's front), `remove`
  (float it again) and `node_of` build and read it in code. A window is its title's id. The tree lives in the
  state store, one small entry per space, node and docked window, so a layout
  of any size fits, and everything in it is pinned.
- **Drawing.** `space(?ctx, key, area)` lays the tree out over the rect, in
  the docked band, and draws a splitter between the children of every split
  and a tab bar (`blit.tabs`) across the top of every leaf. Each docked window
  learns where its body goes through `blit.widget.Docked`, and its own
  `begin_window` draws it there without chrome, only while its tab is
  selected. Its content code, its ids, its scroll and every widget's state are
  the same as when it floats. Draw the space before its windows, or they lag
  it by a frame.
- **Splitters.** Dragging a splitter moves its split, keeping each side at
  least a few rows, or a docked window's declared `min_w` and `min_h`.
- **Tabs.** A leaf's tab bar selects, reorders by drag, closes (the window's
  `WindowState.closed`) and tears off its windows: a tab released over no
  target floats there. A tab dragged onto another leaf's tab bar joins it. A
  leaf whose windows are all closed or not drawn gives its room to its
  sibling, and comes back when they do.
- **A see-through centre.** `central(?ctx, sid)` makes the space's root its
  central node, the leaf kept open for what the app draws beneath the space,
  such as a 3D scene. Ask for it before splitting the root, and split it to
  dock panels around it: it keeps its id, so it stays the centre. While it
  holds no window it keeps its share of the space and never collapses, paints
  no background, and the space claims no input over it, so a claim the app
  registered beneath the space (earlier, in a lower band) takes the pointer
  there. `central_area(?ctx, sid)` gives its rect once the space has drawn
  this frame, none while a window is docked in it, which makes it an ordinary
  leaf until the window leaves.
- **Docking by drag.** A window's titlebar is a drag source of
  `widget.WINDOW_KIND` carrying its id. While it, or a docked window's tab, is
  dragged over a space, the space shows drop zones over the leaf under the
  pointer (the centre docks as a tab, four edges split the leaf) and near its
  own outer edges (splitting the whole space), with a preview of where the
  window would land. A window released over a leaf's tab bar docks as a tab.
  Holding shift, or the modifiers `set_suppress` picks, shows no zones and
  docks nothing.
- **Persistence.** `persist` registers the spaces, nodes and docked windows
  as `[dock.<id>]`, `[docknode.<id>]` and `[docked.<id>]` tables, loaded
  pinned, so a loaded layout waits for its space however late it is drawn.
  `empty` tells a space with no layout yet, to build a default one only then.
- **Look.** The chrome draws in four kinds `blit.dock.register_kinds(t)`
  registers on a theme, which a dock does on the context's theme the first
  time it draws: `dock_space` (the background), `dock_splitter` (a splitter
  while hot or dragged, `min_w` its thickness), `dock_zone` (a drop zone,
  hot under the drag) and `dock_preview` (where a window would land). A side
  panel's edge and padding are the built-in `dock` style's. A host loading a
  theme file that styles them registers them first.

### Side panels

`blit.dock.begin_dock(?ctx, key, ?d)`/`end_dock` attach a side panel to a
screen edge (`blit.context.Side`: left, right, top or bottom) in one call. Each
panel takes a strip from the frame's free area, so panels opened in turn stack
inward, and `blit.context.free_area` reports what they leave for the rest of
the screen, such as a world view. Call them at the root.

The strip is a dock space whose root holds the panel's own content. Alone it
looks like a plain panel, with no tab bar. Windows dragged over it dock
beside it or as tabs with it, and then its key labels its tab. The panel
itself never floats, and while another tab is selected its widgets lay out
without drawing or claiming, so the caller places them every frame either way.

A panel's body is a scroll region. `blit.widget.begin_scroll(?ctx, key, ?s, h)`/`end_scroll`
open one as the next item of the layout on its own: its column is clipped and scrolls by the
wheel (`Input.wheel`, pixels, positive turned away from the user) and by a
draggable scrollbar when its content is taller than it. The wheel goes to the
innermost region holding the topmost claim under the cursor. The content
glides to the new offset rather than jumping (`ScrollArea.top` is the offset
it is drawn at this frame, which a region drawing only its rows in view
reads), except under a held thumb, and a tab stop inside the region that the
keyboard moved to is scrolled into view.
`blit.widget.section(?ctx, title, ?open)` is a collapsible heading that returns
whether the rows beneath it should be placed.

This is a breaking change: `begin_dock`, `end_dock`, `Dock` and `DockArea`
moved from `blit.widget` to `blit.dock`, unchanged otherwise.

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
  `blit.context.typing(?ctx)` is true while a widget holds it for its keys: read
  it before `begin` to keep the consumer's own key bindings quiet for the keys
  that frame will type into a field. A control reached by tab, such as a button,
  holds the focus without taking the keys a consumer binds, so it stays false
  then.
- **Keyboard navigation.** Every control is a tab stop. Tab and shift tab move
  the focus through them in the order they are drawn, wrapping, across
  windows, docked tabs and menu bars alike. Controls drawn as one row (a
  button row or grid, a segmented choice, radios, a dropdown's options, a tab
  bar, a menu bar's headers, a window's chrome, a value editor's cells, a
  table's header) are a group: tab reaches the group once, at its chosen
  member or the one that last held the keyboard, and the arrows move within
  it. Enter and space activate the control holding the keyboard as a click
  does. A slider takes left and right, home and end, a list and a tree their
  arrows and pages, and a text field all its keys. A press focuses the control
  it lands on as well. Keys move the focus by the previous frame's stops, as
  the pointer routes by its claims.
- **Focus ring.** The control the keyboard moved to wears a ring, the
  `focus_ring` style (derived from the `focus` and `focus_w` tokens), drawn
  above it on its layer
  (`blit.context.focus_visible`), until a press. A window the keyboard moves
  into comes to the front, and a scroll region brings the control into view.
- **Owning the keyboard.** A focus held by something that is not a tab stop,
  such as an open menu, keeps every key: tab and the arrows move nothing while
  a menu is open. A modal keeps the keyboard inside it: tab moves from the
  modal onto its controls and never past them (see Layers & input routing).
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
- **Tab stops.** `blit.interact.FOCUS` among the buttons makes the widget a
  tab stop (see Keyboard navigation), registered in call order even while
  clipped out of sight: a left press focuses it, `focused` says it holds the
  keyboard, and enter or space while it held the keyboard from the frame's
  start set `activated` and `clicked`. `ARROWS` says it takes the arrow keys
  itself while focused and `TEXT` that it takes typed text, which also keeps
  enter and space its own. `interact.presses(?ctx, code)` counts a key's
  presses for a widget reading its own keys. A widget whose claim is a
  container's, as a list's or a tree's is its scroll region, registers its
  stop with `interact.stop(?ctx, id, x0, y0, x1, y1, flags)`.
- **Groups.** Stops placed between `g = interact.begin_group(?ctx, id, axis)`
  and `end_group(?ctx, g)` are one group, and the arrows along `axis` (`ROW`,
  `COLUMN` or `BOTH`) move between them. `blit.context.mark_current(?ctx, id)`
  names the member tab enters the group at, such as the chosen segment.
- **Disabled.** `blit.context.begin_disabled(?ctx, cond)` and
  `end_disabled(?ctx)` wrap widgets that draw and lay out, keeping their ids
  and state, but take no input when `cond` holds. Inside, `hit` still claims
  the rect but reports nothing hot, pressed, clicked or dragged, the focus is
  neither given nor kept (a holder that becomes disabled loses it), tab and
  the arrows pass over it, scroll
  regions and tables take no wheel, menu items and their shortcuts never fire,
  and every kind paints in its `DISABLED` state through `box` and `paint_of`.
  Scopes nest, and one with `cond` false inside a disabling one stays
  disabled, so a caller writes one call, not a branch.
  `blit.context.disabled(?ctx)` says whether the call site is disabled, for a
  custom control that reads input other than through `hit`.

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
  hot, the topmost claimant under the pointer, and draws the accept
  highlight (the `drop_target` style) over the rect.
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
  is over a target, with `released` set on the frame its button comes up.
  `take(?ctx)` then takes it as dropped, for a target that works out where it
  lands from the pointer, such as a dock whose zones lie under the window
  being dragged.

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
- **Style.** The gaps between items come from the `layout` style's margins
  (`margin.b` down a column, `margin.r` across a row), and the padding a
  container keeps from its own style's `pad`, at the context's scale.

This is a breaking change from the loose layout fields: `Context.ox`, `oy`,
`cx`, `cy` and `pw` are gone (read `avail` instead), as are the saved-layout
fields of `Popup`, `ScrollArea` and `DockArea`, and `Columns` holds its row
instead of `ox` and `pw`.

- **Sections.** `section(?ctx, title, ?open)` is a heading with a caret,
  pointing right when closed and down when open, that returns whether to place
  the rows beneath it. `s = begin_section(?ctx, title, ?open)` is the same
  heading over a body that unfolds and folds: place the rows while `s.body` is
  true, then `end_section(?ctx, s)` whatever it is. Opening or closing, the
  rows show in a clip that grows or shrinks to the height they last took
  whole, over the theme's `MOTION_OPEN`, and the layout below follows it.
  The caret is as tall as the caption's ascent in the current text style,
  whatever the line height, or the section style's `min_w` when it sets one
  (`section.min_w`).
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
  identity as the query or matcher changes. The list is one tab stop, focused
  by tab or a press on a row: up and down move the selection over the shown
  items, home and end to either end and page up and page down by a list's
  height, scrolling it into view, a plain move selecting alone and shift
  extending from the anchor (`List.cursor` is where the keyboard is in a
  multiple selection). A tree (`blit.tree`) is one tab stop the same way, its
  keyboard cursor on a node (`Tree.cursor`): up, down, page up, page down,
  home and end move it a row at a time, right opens a node or steps into it,
  left closes one or steps out to its parent, enter activates the node as a
  double click does and space selects it.
  A list lays out and draws only the rows in view, passing over the rest in
  blocks, so it costs its visible rows and, with a query or a matcher, one
  test per item. Its natural width, which a container sized to its content
  takes, is the widest row it has laid out so far (`List.width`): it grows as
  wider rows scroll into view and never shrinks while scrolling. It resets
  when the list has no items, and a caller whose labels change sets it to 0
  to measure afresh.

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
- **Docking.** The titlebar is a drag source of `WINDOW_KIND` carrying the
  window's id, which a dock space takes in (see Docking). A docked window
  draws in the rect its dock lays out, with no chrome and no grips, its body a
  scroll region as when it floats (`WINDOW_AUTO_SIZE` does not apply there),
  and has no body while another tab of its stack is selected.
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
  `separator` style's `border` color, `border_w` thick, and `separator_label(?ctx, label)` runs
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

## Tables

`blit.table` lays rows of any widgets out under columns the user can resize,
reorder, sort and hide, with frozen leading columns and rows, and draws only
the rows in view, so a table of a million rows costs what one of a screenful
does. The caller describes its columns and runs its rows:

```mach
var cols: [3]blit.table.Column;
cols[0] = blit.table.Column{label: "Name", width: 160.0::f32};
cols[1] = blit.table.Column{label: "Size", width: 60.0::f32};
cols[2] = blit.table.Column{label: "Done", flags: blit.table.NO_SORT};

# per frame:
var o: blit.table.Options = blit.table.options(count, 300.0::f32);
o.freeze_cols = 1;
var t: blit.table.Table = blit.table.begin(?ctx, "files", ?cols[0], 3, o);
if (t.sorted) { order_rows(t.sort, t.dir); }
for (blit.table.next_row(?ctx, ?t)) {
    val f: *File = ?files[order[t.row]];
    if (blit.table.cell(?ctx, ?t, 0)) { blit.widget.text(?ctx, f.name); }
    if (blit.table.cell(?ctx, ?t, 1)) { blit.widget.text(?ctx, f.size_text); }
    if (blit.table.cell(?ctx, ?t, 2)) { blit.widget.checkbox(?ctx, "done", ?f.done); }
}
blit.table.end(?ctx, ?t);
```

- **Rows in view.** `next_row` yields the frozen rows, then only the rows the
  view shows, setting `t.row`. Rows are one height (`Options.row_h`, a control
  row by default), so the first row in view is found by arithmetic and a frame
  never walks the rows above it.
- **Cells.** `cell(?ctx, ?t, c)` opens column `c`'s cell in the current row
  and returns false for a hidden column or one scrolled out of view. A cell
  is a horizontal stack across the column, its widgets centred down the row
  and clipped to the cell.
- **Ids.** A row is an id scope keyed by its key under the table's id, its
  index unless `Options.key` maps it (a caller that sorts keys rows by their
  data), and a cell a scope keyed by its column's label under the row. A
  widget in a cell keeps its id and its state however the rows scroll.
  `cell_id(?t, key, c)` is a cell's scope, the parent of its widgets' ids.
- **The header.** Dragging the grip at a header cell's right edge resizes the
  column. A click, or enter or space on a header the keyboard reached (the
  header is a group of tab stops), sorts by the column, ascending and then descending, and the
  table reports it as `t.sort` (the column's index, the column count for
  none) and `t.dir`, with `t.sorted` set on the frame it changed: the table
  never sorts, the caller orders its rows. Dragging a header drops the column
  on another's place through `blit.dnd`, and a right click opens a context
  menu (`blit.menu`, under `MENU_KEY`) whose checked items show and hide
  columns. `NO_RESIZE`, `NO_REORDER`, `NO_HIDE` and `NO_SORT`
  turn each off per column and `HIDDEN` starts a column hidden.
- **Frozen columns and rows.** The header, the first `freeze_cols` shown
  columns and the first `freeze_rows` rows stay put while the rest scrolls,
  by the wheels and by scrollbars that appear when the content outgrows the
  table. Frozen and scrolled parts are clipped to rects that do not overlap.
- **Column state.** Each column's width, place and visibility live in the
  state store under the column's id (its label under the table's id), and
  the sort and scroll under the table's. A change the user makes pins them,
  so a table not drawn for a while keeps its layout.
  `blit.table.register(?ctx)` makes the layout and sort persist through
  `blit.state.save` and `load`, as `table_column` and `table` tables.
- **Where things went.** `begin` fills each `Column`'s `id`, `shown`,
  `frozen`, `pos` (its place in the display order), `x` and `w`, and `order`,
  the index of the column shown at that record's own place.

## Value editors & the colour picker

`blit.value` edits numbers of any of `i8` to `i64`, `u8` to `u64`, `f32` and
`f64` without loss: nothing passes a 64-bit integer through a float or an
`f64` through anything narrower, a value shows as the shortest text that
reads back as exactly that value, and typed text is read exactly.

- **Drag.** `drag[T](?ctx, label, ?v, speed, lo, hi)` moves `@v` by `speed`
  per pixel dragged across it, `FINE` times as far while shift is held. An
  integer moves by whole steps and keeps the fraction for the next pixel, and
  a float lands on the decimals of its value at the press or of the speed, so
  dragging 1.5 by 0.01 a pixel gives 1.6. A double click, or enter or space
  while it holds the keyboard, turns it into a text field with the value selected: enter or a press elsewhere commits, escape
  leaves the value. `drag_n[T](?ctx, label, ?vec[0], n, speed, lo, hi)` edits
  2 to 4 values in one row, and `drag_range[T](?ctx, label, ?a, ?b, speed, lo,
  hi)` a low and a high value that never cross.
- **Typed numbers.** `number[T](?ctx, label, ?v, step, lo, hi)` is a text
  field with `-` and `+` steppers, committing as a double-clicked drag does.
- **Bounds.** `lo < hi` clamps dragged, stepped and typed values, and equal
  bounds leave a value to its type's range. Typed text that is no number of
  the type leaves the value as it was.

Each value's cell is a part of its editor keyed `#0` to `#3`, so a driver
reaches the first cell of `speed` as `speed/#0`, and a number's steppers as
`speed/-` and `speed/+`. `drag_scalars`, `range_scalars` and `number_scalar`
take a kind (`I8` to `F64`) and a pointer for values typed at run time, and
`value.entry` is the typed text cell under them all.

`blit.color.picker(?ctx, label, ?c, flags)` edits a colour in hue, saturation
and value: a square of saturation and value beside a hue bar, or inside a hue
ring with `RING`, an alpha bar over a checkerboard with `ALPHA`, and beneath
them a swatch, the label and hex text (`#RRGGBB`, `#RRGGBBAA` with alpha)
typed in like a value. The picker keeps its hue across greys and black, and
hex text read back shows as the same text.

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
  `pin[T](?ctx, id, 0)` lets it age out again. `find[T](?ctx, id)` looks an
  entry up without making or reaching it, nil when there is none, and
  `drop[T](?ctx, id)` drops it at once.
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
  `keep[T](?ctx, 1)` loads a registered kind's entries pinned, for state that
  must wait for whatever reaches it.

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
  and escape. A bar's headers are a group of tab stops: left and right move
  between them, and enter, space or down opens a header's menu on its first
  item, the focus going back to the header when it closes.
- **Closing.** A click or enter on an item closes the whole tree, and so does
  a press of any button outside it, which is consumed.
- **Ids.** A bar's key, then each header and submenu label, then the item's
  label: `driver.find(?d, "main/File/Recent/notes.txt")`.

## Modals

`blit.modal` puts up a dialog that blocks everything beneath it until it
closes. Its open state lives in the state store under its title's id, so
`open` and `close` take it up and down from anywhere in the same id scope,
and `begin_modal` and `end_modal` run every frame, open or not:

```mach
if (blit.widget.button(?ctx, "Delete")) { blit.modal.open(?ctx, "Delete file"); }

val m: blit.modal.ModalArea = blit.modal.begin_modal(?ctx, blit.modal.dialog("Delete file"));
if (m.shown != 0) {
    blit.widget.text(?ctx, "notes.txt goes for good.");
    if (blit.widget.button(?ctx, "Delete")) { ...; blit.modal.close(?ctx, "Delete file"); }
}
blit.modal.end_modal(?ctx, m);

var labels: [2]str = [2]str{"Save", "Discard"};
val c: usize = blit.modal.confirm(?ctx, "Unsaved", "Save the changes first?", ?labels[0], 2);
if (c == 0) { ... }   # c is the button chosen, CANCELLED, or NO_CHOICE
```

- **Blocking.** A modal paints and claims in the modals band, above docks,
  windows, overlays and popups, behind a scrim over the whole screen. The scrim
  claims every button, so nothing beneath it is hovered, pressed or scrolled,
  while the widgets inside the modal work as usual. Popups, dropdowns and menus
  opened inside a modal stack above it.
  The scrim paints in the `scrim` style, the body and its shadow in `modal`
  and the titlebar in `window_title`.
- **Placement.** A `Modal` declares a title, a width (0 to fit its widgets),
  a greatest width and `MODAL_*` flags. It opens centred, or with its top left
  at `x`, `y` under `MODAL_ANCHORED`, and stays on the screen. Its size is
  measured as it is drawn, so the frame it opens lays out hidden behind a scrim
  that already blocks.
- **Closing.** Escape closes the top modal while it holds the keyboard itself
  or a control inside it that takes no text does (escape in a text field
  inside it ends the edit first), and so does the close
  button in its titlebar (`MODAL_NO_CLOSE`, `MODAL_NO_TITLE`). A press on the
  scrim closes it only with `MODAL_SCRIM_CLOSES`. `ModalArea.closed` and `why`
  report the frame it closed.
- **Stacking.** A modal opened inside another's body nests above it, and
  modals called one after another stack by call order. Only the top one takes
  the pointer and escape.
- **Focus.** A modal takes the keyboard the frame it opens, so a field beneath
  stops seeing keys, and gives it back to the previous holder the frame after
  it closes. Tab moves from the modal onto its controls, and tab and the
  arrows stay among the top modal's controls while it is open.
- **Confirm.** `confirm` is a dialog with a message and a row of buttons. It
  returns the index chosen, closing itself, `CANCELLED` on the frame it is
  closed without a choice (escape, close button or scrim), and `NO_CHOICE`
  otherwise.
- **Ids.** A modal is the id scope of its widgets:
  `driver.find(?d, "Delete file/Delete")`.

## Overlays, toasts & tooltips

`blit.overlay` places widgets that float above the interface without being
windows: a HUD readout, a help button, the cursor's coordinates. An overlay is
placed by an anchor, not by the layout, and sizes to its content:

```mach
# a readout in the top right corner of the surface
var hud: blit.overlay.Overlay = blit.overlay.on_surface(blit.overlay.TOP_RIGHT);
hud.dx = -8.0::f32;
hud.dy = 8.0::f32;
val s: blit.overlay.Shown = blit.overlay.begin(?ctx, "hud", hud);
blit.widget.text(?ctx, "fps 60");
blit.overlay.end(?ctx, s);

# a note just below a rect, flipped above it and clamped where it would run off
var o: blit.overlay.Overlay = blit.overlay.on_rect(r, blit.overlay.BOTTOM_LEFT, blit.overlay.TOP_LEFT);
o.keep = 1;
```

- **Anchors.** An `Anchor` is a point of a rect as fractions of its size:
  `TOP_LEFT`, `TOP`, `TOP_RIGHT`, `LEFT`, `CENTER`, `RIGHT`, `BOTTOM_LEFT`,
  `BOTTOM` and `BOTTOM_RIGHT`, or any other. `at` is the point of the target
  (the surface, or `target` in the caller's local pixels with `to_rect` 1),
  `pivot` the point of the overlay put there, and `dx`/`dy` an offset in
  pixels. `on_surface(a)` puts the overlay's own `a` at the surface's, so a
  corner anchor sits in that corner. `keep` keeps it on the surface: an
  overlay running off an edge flips to the far side of its anchor on that
  axis, then is clamped.
- **Size.** Its widgets lay out down a column it fits to them, measured into
  the state store under its id. A placement that reads the size (any pivot
  but the top left, or `keep`) uses last frame's measure, and an overlay never
  measured spends its first frame hidden, only measuring, and asks for the
  next at once, as a fitted stack does.
- **No chrome, no claim.** A bare overlay draws no title, frame or
  background unless its style gives it one, and claims nothing itself: input stops only where its widgets
  claim, so the world under its empty space and its text stays interactive.
- **Order.** Overlays paint and take input in the overlays band, above docks
  and windows and beneath popups, menus and modals. `order` places one among
  the others, higher above, and call order breaks a tie.
- **Fade.** `fade` (a `Fade` of `dist`, `near` and `far`) runs the overlay's
  opacity from `near`, with the pointer on it, to `far`, with the pointer
  `dist` pixels away or more or off the surface: near 0.2 and far 1 lets a
  HUD get out of the way, near 1 and far 0 shows it only as the pointer
  nears. It fades everything it holds through `blit.context.push_alpha(?ctx,
  a)`/`pop_alpha`, an opacity scope every color the painter emits passes
  through, which nests by multiplying. A consumer span is drawn by the
  consumer and is not faded.

`blit.toast` stacks timed notifications at an anchor of the surface or of
any rect:

```mach
var toasts: blit.toast.Toasts;
blit.toast.init(?toasts, ?a);                     # once
val posted: err[allo.Error] = blit.toast.post(?toasts, "saved", 0.0); # anywhere: 0 for SECONDS
val st: err[allo.Error] = blit.toast.post_keyed(?toasts, "status", "identifying...", 0.0); # one card per key
val re: err[allo.Error] = blit.toast.post_keyed(?toasts, "status", "a cat", 2.0); # the same card, new text
val held: bool = blit.toast.withdraw(?toasts, "status"); # take it down early
blit.toast.show(?ctx, "toasts", ?toasts, blit.overlay.BOTTOM_RIGHT); # per frame
blit.toast.show_in(?ctx, "toasts", ?toasts, viewport, blit.overlay.TOP_RIGHT); # or inside a rect
```

- **Life.** A toast's clock starts the first frame `show` draws it. It fades
  in over its first `FADE` seconds and out over its last, and is dropped once
  its time is up. `post` copies the text into storage the `Toasts` owns, so a
  transient buffer will do, and `free` releases it.
- **Keys.** `post_keyed` names a toast by a key, copied like the text.
  Posting under a key the stack holds replaces that toast in place: it keeps
  its place in the stack, takes the new text and time, and its clock starts
  over at the next show without fading in again if it was on screen.
  `withdraw` takes a keyed toast down before its time is up, fading it out
  over `FADE` from the next show, or dropping it unseen if no frame showed it
  yet, and returns whether the stack held the key.
- **Stack.** The cards stack away from the anchor's edge, up from a bottom
  anchor and down from any other, the newest nearest the anchor, lined up on
  its side and kept off the edges by the `toast` style's margin. `show`
  anchors to the surface, `show_in` to a rect in local pixels, such as a
  viewport beside a docked panel, the stack inside it as `show`'s is inside
  the surface.
- **Frames.** `show` asks for frames only while a toast fades, and otherwise
  for the moment the next one starts to fade out, so once they are gone
  `next_frame` is `none` again. A post or withdraw between frames asks for
  the next one with `blit.context.redraw`.

`blit.tooltip` shows an overlay over a widget once the pointer has rested on
it, named by id after the widget is drawn:

```mach
blit.widget.button(?ctx, "Save");
blit.tooltip.text(?ctx, blit.context.id_of(?ctx, "Save"), "write the file");

var t: blit.tooltip.Tip = blit.tooltip.tip();
t.follow = 0;                                     # below the widget, not the pointer
val tip: blit.tooltip.Shown = blit.tooltip.begin(?ctx, id, t);
if (tip.open != 0) { blit.widget.text(?ctx, "any widgets"); }
blit.tooltip.end(?ctx, tip);
```

- **Delay.** It shows once the widget has been the hovered claimant for
  `delay` seconds (`DELAY`, 0.5 s), asking for that frame through `wake_at`
  while it waits and for nothing once shown. A held button hides it and
  starts the delay over.
- **Placement.** Below and right of the pointer, clear of the cursor by
  `CURSOR_GAP`, or below the widget with `follow` 0, in the tooltips band
  above everything but a drag preview, and always kept on the surface.
- **Pass-through.** A tooltip claims nothing, so the widget under it keeps the
  pointer. Its content is for reading: a widget in it that claims would take
  the hover from the widget it describes.

Overlays, toasts and tooltips draw in the `overlay`, `toast` and `tooltip`
styles, which `blit.overlay.chrome(?ctx, kind)` reads at rest and
`blit.overlay.paint` draws. A bare overlay's style has no fill or outline, so
it stays chrome-free until a theme gives it one.

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
  slot above a parent of the same band or, opened inside a higher band, one
  slot above its parent in that band, and an ordered band (windows,
  overlays) takes the slot given, a window's z or an overlay's order. `end()` composes the draw list by layer,
  keeping call order within a layer, so a popup opened early in the frame
  still paints over a window called after it, and sibling popups share a
  layer. `run_at` reports each run's `layer`. `push_layer` and `pop_layer`
  remain, deprecated, as `push_band(?ctx, band.POPUPS, 0)` and `pop_band`.
- **Trapping the keyboard.** A band whose row sets `trap` (modals) keeps
  keyboard navigation inside its topmost layer holding a tab stop, so tab
  cycles through the top modal's controls alone.
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
  nothing and returns false. `settle(?d)` runs frames while the interface
  asks for the next one at once, so its animations and glides reach their
  ends.
- **Frames.** Each step carries the clock (`d.time`, advanced by `d.dt`, 1/60
  s by default) and clears the frame's key events, wheel and paste, so input
  set between steps lands in exactly one frame. `d.ctx` and `d.in` are the
  context and input, free to read and set between steps.
- **Queries** read the last frame: `drawn`, `rect` (the screen rect the widget
  claimed, clipped, none when it was not visible), `hot`, `active` and
  `focused`, `focus_of(?d)` (whichever widget holds the keyboard), and `text_in(?d, x0, y0, x1, y1)` and `text_of(?d, id)`, the
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

## Inspector

`blit.inspect` is an interface inspector built with blit, for debugging the
interfaces built with it: a window over the frame showing what the context
keeps, as a tree whose sections open to their entries.

```mach
var insp: blit.inspect.Inspector;
blit.inspect.init(?insp, ?a);          # once, closed
# per frame, after every other widget:
blit.inspect.show(?ctx, ?insp);
# bound to a key or a button:
blit.inspect.toggle(?insp);
# at shutdown: blit.inspect.free(?insp)
```

- **What it shows.** The frame: the screen, scale and dt, and the hovered,
  hot, active and focused ids (whether the focus wears the ring and takes
  typed keys). The focus order: every tab stop in the order tab moves
  through them, with its layer, group and the keys it takes. Layers and
  claims: each band with its rule and its claims and runs, and each claim's
  id, layer and rect. Collisions: every id claimed twice. The draw list: its
  vertex, index and run counts and each run's layer, texture, triangles and
  clip. Windows: each window's rect, z and flags. Dock spaces: each space's
  tree of splits and leaves and the windows docked in them. The state store:
  every entry's id, kind (a registered kind's name, or its type), size, age
  and pin.
- **Outlines.** Hovering an entry outlines its rect on the surface, in the
  tooltips band above everything but a drag, in the `inspect_outline` kind
  (`blit.inspect.register_kinds` registers it, as `show` does the first time
  it draws): a claim's rect, a widget's, a window's, a dock node's, a tab
  stop's, a run's clip.
- **Costing nothing when off.** It records nothing: everything it shows is
  what the context already keeps for routing, drawing and its store, read
  where it stands. The `Inspector` is the caller's, and while closed `show`
  returns at once. Called last, it reads the app's whole frame before
  drawing itself, and while open it copies what it lists into storage it
  owns, so drawing itself never moves what it reads. Closing its window
  closes it.

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

`demo/gallery/` is the reference people learn blit from, as Dear ImGui's demo
window is: one window covering every widget and module, each section beside
the code that builds it. The screen is a dock space with the gallery docked
in it, a list of sections on the left, the chosen section's widgets in the
middle and its source on the right. Each section is a file of its own under
`demo/gallery/src/sections/`, embedded, so the code shown is the code that
runs, and a new section is one file and one row of the table in
`demo/gallery/src/app.mach`. A host with a window and a renderer makes a
`Gallery` and runs `gallery.app.ui` each frame. Its test visits every
section headless, checking each frame is whole with no id collisions, and
compares the last frame with `demo/gallery/src/bin/gallery.snap`:

```
mach dep pull demo/gallery
mach test demo/gallery
demo/gallery/out/linux-x86_64/debug/bin/gallery --snapshot > demo/gallery/src/bin/gallery.snap
```

## Benchmark

`demo/bench/` measures blit's per-frame cost on a few representative
interfaces: a dock of eight open sections of controls, a list of 10,000 rows, a
line chart of 100,000 samples, six overlapping windows each holding a
section and a scroll region, and one path of 10,000 edges filled. Each scene runs with sRGB output off and then on,
and the table reports the median frame time over 21 timed batches with the
spread between the fastest and slowest batch, the vertices and runs the frame
emits, the allocations a frame makes, and what sRGB adds. The off and on
batches are interleaved so drift in the machine's speed lands on both. It is local only,
never a CI job. Build it in the release profile:

```
mach dep pull demo/bench
mach build demo/bench -p release
demo/bench/out/linux-x86_64/release/bin/bench
```

Baseline on dev ahead of 0.10.0 (after #152), on an AMD Ryzen 7 5800X3D, to
compare later work against. Run it on an idle machine and pinned to one core
(`taskset -c 15`): other load shows up as a large spread, and a run whose
spread is large is not worth comparing. Two consecutive runs recorded this way
agreed within 2% on every scene.

```
scene          srgb    us/frame    spread  vertices  runs  allocs   srgb cost
dense panel    off        253.4     3.4%      3532     3       0
dense panel    on         258.0     0.4%      3532     3       0   +1.8%
10k row list   off         60.4     2.3%      1136     3       0
10k row list   on          60.7     0.4%      1136     3       0   +0.5%
100k chart     off       1697.3     4.4%     10492     3       0
100k chart     on        1756.1     0.7%     10492     3       0   +3.4%
windows        off        241.5     3.9%      3672    18       0
windows        on         246.4     0.6%      3672    18       0   +2.0%
10k-edge fill  off      14413.6     1.5%    231520     1       0
10k-edge fill  on       14404.5     0.9%    231520     1       0   +0.0%
```

## Conventions

`main`/`dev` long-lived branches; `feat/*` and `fix/*` branch off `dev` and
merge back; `dev` integrates to `main` for releases. Conventional commits,
semver tags.
