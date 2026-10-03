module main

import math
import proto

// Map overlay: a transparent, click-through, always-on-top window laid over
// the game's minimap that marks the cubes in their list colors. It is drawn
// with per-pixel alpha (UpdateLayeredWindow) from a GDI+ image. "Unlock"
// makes it draggable / resizable to fit a moved minimap; right-click locks.

// UpdateLayeredWindow is missing from tcc's user32 import list; loaded at runtime.
type FnUpdateLayeredWindow = fn (voidptr, voidptr, voidptr, voidptr, voidptr, voidptr, u32, voidptr, u32) int

fn C.SetCapture(hwnd voidptr) voidptr
fn C.ReleaseCapture() int
fn C.SetCursor(cursor voidptr) voidptr

const overlay_class = 'CubeWatchMapOverlay'
const ws_popup = u32(0x80000000)
const ws_ex_transparent = u32(0x00000020)
const ws_ex_toolwindow = u32(0x00000080)
const ws_ex_noactivate = u32(0x08000000)
const gwl_exstyle = -20
const ulw_alpha = u32(2)
const wm_setcursor = u32(0x0020)
const wm_mouseactivate = u32(0x0021)
const wm_mousemove = u32(0x0200)
const wm_lbuttondown = u32(0x0201)
const wm_mousewheel = u32(0x020A)
const ma_noactivate = 3
const idc_sizeall = voidptr(usize(32646))
const idc_sizenwse = voidptr(usize(32642))
const idc_sizenesw = voidptr(usize(32643))
const idc_sizewe = voidptr(usize(32644))
const idc_sizens = voidptr(usize(32645))

// Default minimap box, measured from Edit HUD screenshots (outer margin
// "None") in units of screen height at UI Proportion "Medium": anchored to
// the top-right corner, everything scales with the UI proportion.
const minimap_width = 0.2280
const minimap_height = 0.1745
const minimap_top = 0.0693
const minimap_right_margin = 0.0210
// Inside the box: the player icon (map centre) and the title bar height.
const minimap_player_x = 0.500
const minimap_player_y = 0.563
const minimap_title_height = 0.13

// Game "UI Proportion" choices and their measured scale (Large estimated).
const ui_proportion_names = ['Smaller', 'Small', 'Medium', 'Large', 'Larger']
const ui_proportion_pcts = [88, 94, 100, 109, 118]
// World units shown across the minimap's width: presets, and the range the
// mouse wheel can fine-tune it to while unlocked.
const overlay_zooms = [4000, 6000, 8000, 10000, 15000, 20000, 30000, 40000]
const default_overlay_zoom = 10000
const overlay_zoom_min = 2000
const overlay_zoom_max = 80000
const overlay_opacities = [100, 80, 60, 40]

// Edge bits for dragging; 0 = move.
const edge_left = 1
const edge_right = 2
const edge_top = 4
const edge_bottom = 8

struct BlendFunction {
	op     u8
	flags  u8
	alpha  u8
	format u8
}

struct SizeI {
	cx int
	cy int
}

fn register_overlay_class(instance voidptr) {
	cls := WndClassEx{
		size:       u32(sizeof(WndClassEx))
		wnd_proc:   voidptr(overlay_proc)
		instance:   instance
		cursor:     C.LoadCursorW(unsafe { nil }, idc_arrow)
		class_name: overlay_class.to_wide()
	}
	C.RegisterClassExW(&cls)
}

fn overlay_proc(hwnd voidptr, msg u32, wparam usize, lparam isize) isize {
	ptr := C.GetWindowLongPtrW(hwnd, gwlp_userdata)
	if ptr != 0 {
		mut app := unsafe { &App(voidptr(ptr)) }
		if r := app.overlay_message(msg, wparam) {
			return r
		}
	}
	return C.DefWindowProcW(hwnd, msg, wparam, lparam)
}

fn primary_screen() (int, int) {
	return C.GetSystemMetrics(0), C.GetSystemMetrics(1)
}

// overlay_default_rect is where the minimap sits for the chosen UI
// proportion on the primary screen.
fn overlay_default_rect(ui_pct int) Rect {
	sw, sh := primary_screen()
	s := f64(sh) * f64(ui_pct) / 100.0
	w := int(math.round(minimap_width * s))
	h := int(math.round(minimap_height * s))
	right := sw - int(math.round(minimap_right_margin * s))
	top := int(math.round(minimap_top * s))
	return Rect{right - w, top, right, top + h}
}

// overlay_rect: the saved (moved) position, stored as fractions of the
// screen so it survives resolution changes, or the default.
fn (app &App) overlay_rect() Rect {
	s := app.settings
	if s.overlay_w <= 0 || s.overlay_h <= 0 {
		return overlay_default_rect(s.overlay_ui_pct)
	}
	sw, sh := primary_screen()
	x, y := int(s.overlay_x * sw), int(s.overlay_y * sh)
	return Rect{x, y, x + int(s.overlay_w * sw), y + int(s.overlay_h * sh)}
}

fn (mut app App) remember_overlay_rect(rc Rect) {
	sw, sh := primary_screen()
	app.settings.overlay_x = f64(rc.left) / sw
	app.settings.overlay_y = f64(rc.top) / sh
	app.settings.overlay_w = f64(rc.right - rc.left) / sw
	app.settings.overlay_h = f64(rc.bottom - rc.top) / sh
}

// apply_overlay shows, hides or repositions the overlay after a settings change.
fn (mut app App) apply_overlay() {
	if !app.settings.overlay {
		if app.overlay_hwnd != unsafe { nil } {
			C.ShowWindow(app.overlay_hwnd, sw_hide)
		}
		app.overlay_unlocked = false
		app.update_overlay_controls()
		return
	}
	if app.overlay_hwnd == unsafe { nil } {
		ex := ws_ex_layered | ws_ex_topmost | ws_ex_toolwindow | ws_ex_noactivate | ws_ex_transparent
		app.overlay_hwnd = C.CreateWindowExW(ex, overlay_class.to_wide(), 'Cube Watch map overlay'.to_wide(),
			ws_popup, 0, 0, 10, 10, unsafe { nil }, unsafe { nil }, app.instance, unsafe { nil })
		if app.overlay_hwnd == unsafe { nil } {
			app.set_status('Cannot create the map overlay window.', true)
			return
		}
		C.SetWindowLongPtrW(app.overlay_hwnd, gwlp_userdata, isize(voidptr(app)))
	}
	rc := app.overlay_rect()
	C.SetWindowPos(app.overlay_hwnd, voidptr(isize(hwnd_topmost)), rc.left, rc.top, rc.right - rc.left,
		rc.bottom - rc.top, swp_noactivate)
	C.ShowWindow(app.overlay_hwnd, 4) // SW_SHOWNOACTIVATE: never take focus from the game
	app.render_overlay()
	app.update_overlay_controls()
}

fn (mut app App) set_overlay_unlocked(unlocked bool) {
	if app.overlay_hwnd == unsafe { nil } || !app.settings.overlay {
		return
	}
	app.overlay_unlocked = unlocked
	// Zoom reference: where you stand now, drawn as a cross once you move.
	app.overlay_ref = if unlocked {
		if p := app.player { ?proto.Vec3(p.pos) } else { none }
	} else {
		none
	}
	mut ex := u32(C.GetWindowLongPtrW(app.overlay_hwnd, gwl_exstyle))
	ex = if unlocked { ex & ~ws_ex_transparent } else { ex | ws_ex_transparent }
	C.SetWindowLongPtrW(app.overlay_hwnd, gwl_exstyle, isize(ex))
	app.render_overlay()
	app.update_overlay_controls()
	if unlocked {
		app.set_status('Overlay unlocked: drag it onto the minimap (edges resize). Zoom: walk away a bit and stop, then use the mouse wheel over it until the white X sits on the spot where you started. Right-click or "Lock" when done.',
			false)
	}
}

fn (mut app App) reset_overlay_position() {
	app.settings.overlay_x, app.settings.overlay_y = 0, 0
	app.settings.overlay_w, app.settings.overlay_h = 0, 0
	app.save()
	app.apply_overlay()
}

// keep_overlay_on_top re-asserts topmost; some games push themselves above
// topmost windows when they regain focus.
fn (mut app App) keep_overlay_on_top() {
	if app.overlay_hwnd == unsafe { nil } || !app.settings.overlay {
		return
	}
	now := now_seconds()
	if now - app.overlay_topmost_at < 2.0 {
		return
	}
	app.overlay_topmost_at = now
	C.SetWindowPos(app.overlay_hwnd, voidptr(isize(hwnd_topmost)), 0, 0, 0, 0, swp_nomove | swp_nosize | swp_noactivate)
}

// ---- mouse: move / resize while unlocked ------------------------------------

fn (app &App) overlay_cursor_edges() (int, Point) {
	mut pt := Point{}
	C.GetCursorPos(&pt)
	mut rc := Rect{}
	C.GetWindowRect(app.overlay_hwnd, &rc)
	grip := app.s(8)
	mut edges := 0
	if pt.x < rc.left + grip {
		edges |= edge_left
	} else if pt.x >= rc.right - grip {
		edges |= edge_right
	}
	if pt.y < rc.top + grip {
		edges |= edge_top
	} else if pt.y >= rc.bottom - grip {
		edges |= edge_bottom
	}
	return edges, pt
}

fn edges_cursor(edges int) voidptr {
	return match edges {
		edge_left | edge_top, edge_right | edge_bottom { idc_sizenwse }
		edge_right | edge_top, edge_left | edge_bottom { idc_sizenesw }
		edge_left, edge_right { idc_sizewe }
		edge_top, edge_bottom { idc_sizens }
		else { idc_sizeall }
	}
}

fn (mut app App) overlay_message(msg u32, wparam usize) ?isize {
	match msg {
		wm_mouseactivate {
			return ma_noactivate
		}
		wm_setcursor {
			if !app.overlay_unlocked {
				return none
			}
			mut edges := app.overlay_drag
			if edges < 0 {
				edges, _ = app.overlay_cursor_edges()
			}
			C.SetCursor(C.LoadCursorW(unsafe { nil }, edges_cursor(edges)))
			return 1
		}
		wm_lbuttondown {
			if !app.overlay_unlocked {
				return none
			}
			edges, pt := app.overlay_cursor_edges()
			app.overlay_drag = edges
			app.overlay_drag_pt = pt
			C.GetWindowRect(app.overlay_hwnd, &app.overlay_drag_rect)
			C.SetCapture(app.overlay_hwnd)
			return 0
		}
		wm_mousemove {
			if app.overlay_drag < 0 {
				return none
			}
			mut pt := Point{}
			C.GetCursorPos(&pt)
			dx, dy := pt.x - app.overlay_drag_pt.x, pt.y - app.overlay_drag_pt.y
			mut rc := app.overlay_drag_rect
			e := app.overlay_drag
			min_w, min_h := app.s(80), app.s(60)
			if e == 0 {
				rc = Rect{rc.left + dx, rc.top + dy, rc.right + dx, rc.bottom + dy}
			}
			if e & edge_left != 0 {
				rc.left = math.min(rc.left + dx, rc.right - min_w)
			}
			if e & edge_right != 0 {
				rc.right = math.max(rc.right + dx, rc.left + min_w)
			}
			if e & edge_top != 0 {
				rc.top = math.min(rc.top + dy, rc.bottom - min_h)
			}
			if e & edge_bottom != 0 {
				rc.bottom = math.max(rc.bottom + dy, rc.top + min_h)
			}
			C.SetWindowPos(app.overlay_hwnd, unsafe { nil }, rc.left, rc.top, rc.right - rc.left,
				rc.bottom - rc.top, swp_nozorder | swp_noactivate)
			app.render_overlay()
			return 0
		}
		wm_lbuttonup {
			if app.overlay_drag < 0 {
				return none
			}
			app.overlay_drag = -1
			C.ReleaseCapture()
			mut rc := Rect{}
			C.GetWindowRect(app.overlay_hwnd, &rc)
			app.remember_overlay_rect(rc)
			app.save()
			return 0
		}
		wm_mousewheel {
			if !app.overlay_unlocked {
				return none
			}
			// Wheel up = zoom in (fewer world units across the map).
			delta := i16(u16(hiword(wparam)))
			factor := if delta > 0 { 0.95 } else { 1.0 / 0.95 }
			zoom := int(math.round(f64(app.settings.overlay_zoom) * factor))
			app.settings.overlay_zoom = clamp(zoom, overlay_zoom_min, overlay_zoom_max)
			app.update_overlay_controls()
			app.save()
			app.render_overlay()
			app.set_status('Map zoom: ${format_units(app.settings.overlay_zoom)} units across the minimap.',
				false)
			return 0
		}
		wm_rbuttonup {
			if app.overlay_unlocked {
				app.set_overlay_unlocked(false)
				return 0
			}
			return none
		}
		else {
			return none
		}
	}
}

// ---- drawing -----------------------------------------------------------------

fn (mut app App) render_overlay() {
	if app.overlay_hwnd == unsafe { nil } || !app.settings.overlay {
		return
	}
	g := app.gdip or { return }
	mut rc := Rect{}
	C.GetWindowRect(app.overlay_hwnd, &rc)
	w, h := rc.right - rc.left, rc.bottom - rc.top
	if w <= 0 || h <= 0 {
		return
	}
	screen := C.GetDC(unsafe { nil })
	mem := C.CreateCompatibleDC(screen)
	header := BitmapInfoHeader{
		size:      u32(sizeof(BitmapInfoHeader))
		width:     w
		height:    -h // top-down rows
		planes:    1
		bit_count: 32
	}
	mut bits := unsafe { nil }
	dib := C.CreateDIBSection(screen, &header, 0, voidptr(&bits), unsafe { nil }, 0)
	if dib == unsafe { nil } || bits == unsafe { nil } {
		C.DeleteDC(mem)
		C.ReleaseDC(unsafe { nil }, screen)
		return
	}
	old := C.SelectObject(mem, dib)
	// GDI+ draws premultiplied ARGB straight into the DIB, which is the
	// format UpdateLayeredWindow expects.
	img := unsafe { nil }
	g.create_bitmap(w, h, w * 4, gdip_format_32bpp_pargb, bits, &img)
	if img != unsafe { nil } {
		gr := unsafe { nil }
		g.image_graphics(img, &gr)
		if gr != unsafe { nil } {
			g.set_smoothing(gr, gdip_smoothing_antialias)
			g.clear(gr, 0)
			app.draw_overlay(Canvas{&g, gr}, w, h)
			g.delete_graphics(gr)
		}
		g.dispose_image(img)
	}
	opacity := if app.overlay_unlocked {
		math.max(app.settings.overlay_opacity, 70)
	} else {
		app.settings.overlay_opacity
	}
	blend := BlendFunction{
		alpha:  u8(opacity * 255 / 100)
		format: 1 // AC_SRC_ALPHA
	}
	size := SizeI{w, h}
	src := Point{0, 0}
	dst := Point{rc.left, rc.top}
	ulw := proc_address('user32.dll', 'UpdateLayeredWindow')
	if ulw != unsafe { nil } {
		update := FnUpdateLayeredWindow(ulw)
		update(app.overlay_hwnd, screen, &dst, &size, mem, &src, 0, &blend, ulw_alpha)
	}
	C.SelectObject(mem, old)
	C.DeleteObject(dib)
	C.DeleteDC(mem)
	C.ReleaseDC(unsafe { nil }, screen)
}

fn (app &App) draw_overlay(c Canvas, w int, h int) {
	fw, fh := f32(w), f32(h)
	cx, cy := fw * f32(minimap_player_x), fh * f32(minimap_player_y)
	accent := u32(0xffe0a020) // cube-watch orange, ARGB
	if app.overlay_unlocked {
		// Alignment aid: frame, title bar line and a cross on the player arrow.
		c.fill_rect(0, 0, fw, fh, 0x50000000)
		c.stroke_rect(1, 1, fw - 2, fh - 2, 2, accent)
		ty := fh * f32(minimap_title_height)
		c.line(2, ty, fw - 2, ty, 1, 0x80e0a020)
		arm := f32(app.s(14))
		c.line(cx - arm, cy, cx + arm, cy, 2, accent)
		c.line(cx, cy - arm, cx, cy + arm, 2, accent)
		grip := f32(app.s(6))
		for p in [[f32(0), 0], [fw - grip, 0], [f32(0), fh - grip],
			[fw - grip, fh - grip]] {
			c.fill_rect(p[0], p[1], grip, grip, accent)
		}
	}
	app.draw_freshness_ring(c, cx, cy, fw)
	// World units -> overlay pixels; map north is up (compass bearing 0).
	scale := fw / f32(app.settings.overlay_zoom)
	if app.overlay_unlocked {
		app.draw_zoom_reference(c, cx, cy, scale)
	}
	targets := app.compass_targets()
	if targets.len == 0 && app.taken.len == 0 {
		return
	}
	r := f32(math.max(4.0, f64(w) * 0.022))
	inset := r + 2
	left, right := inset, fw - inset
	top, bottom := fh * f32(minimap_title_height) + inset, fh - inset
	outline := u32(0xd0000000)
	font := c.new_font('Segoe UI', f32(math.max(10.0, f64(w) * 0.042))) or { GdipFont{} }
	defer {
		if font.font != unsafe { nil } {
			c.free_font(font)
		}
	}
	bounds := RectF{left, top, right - left, bottom - top}
	limit := app.settings.compass_range
	// Taken in the last few seconds: a red X where the cube was.
	for t in app.taken {
		if limit > 0 && t.planar > limit {
			continue
		}
		a := math.radians(t.bearing)
		d := f32(t.planar) * scale
		x, y := cx + f32(math.sin(a)) * d, cy - f32(math.cos(a)) * d
		if x < left || x > right || y < top || y > bottom {
			continue
		}
		arm := r * 1.3
		for pass in 0 .. 2 {
			width := if pass == 0 { r * 0.9 } else { r * 0.5 }
			color := if pass == 0 { u32(0xd0000000) } else { u32(0xffe02424) }
			c.line(x - arm, y - arm, x + arm, y + arm, width, color)
			c.line(x - arm, y + arm, x + arm, y - arm, width, color)
		}
	}
	// Farthest first so the nearest marker ends up on top.
	for i := targets.len - 1; i >= 0; i-- {
		t := targets[i]
		a := math.radians(t.bearing)
		ux, uy := f32(math.sin(a)), f32(-math.cos(a))
		d := f32(t.planar) * scale
		mut x, mut y := cx + ux * d, cy + uy * d
		color := with_alpha(app.target_color(t), 255)
		mr := if i == 0 { r * 1.3 } else { r }
		if x >= left && x <= right && y >= top && y <= bottom {
			c.fill_circle(x, y, mr, color)
			c.stroke_circle(x, y, mr, 1.5, if t.contest {
				with_alpha(app.theme.contested, 255)
			} else {
				outline
			})
			app.draw_marker_label(c, font, t, x, y, mr, x + mr * 6 > right, bounds)
			app.draw_opening_alert(c, font, t, x, y, mr)
			continue
		}
		// Off the map: an arrow on the edge pointing towards the cube.
		mut k := d
		if ux > 0 {
			k = f32(math.min(k, (right - cx) / ux))
		} else if ux < 0 {
			k = f32(math.min(k, (left - cx) / ux))
		}
		if uy > 0 {
			k = f32(math.min(k, (bottom - cy) / uy))
		} else if uy < 0 {
			k = f32(math.min(k, (top - cy) / uy))
		}
		x, y = cx + ux * k, cy + uy * k
		s := mr * 1.4
		pts := [PointF{x + ux * s, y + uy * s},
			PointF{x - uy * s * 0.7 - ux * s * 0.5, y + ux * s * 0.7 - uy * s * 0.5},
			PointF{x + uy * s * 0.7 - ux * s * 0.5, y - ux * s * 0.7 - uy * s * 0.5}]
		c.fill_polygon(pts, color)
		c.stroke_polygon(pts, 1.5, outline)
		// Label towards the map centre so it stays on the map.
		app.draw_marker_label(c, font, t, x, y, s, x > cx, bounds)
		app.draw_opening_alert(c, font, t, x, y, s)
	}
}

// draw_opening_alert puts a bold "!" above a cube someone is opening: the
// warning color for another player, white for you.
fn (app &App) draw_opening_alert(c Canvas, font GdipFont, t Target, x f32, y f32, r f32) {
	if !t.opening || font.font == unsafe { nil } {
		return
	}
	tw, th := c.text_size('!', font)
	color := if t.contest { with_alpha(app.theme.contested, 255) } else { u32(0xffffffff) }
	c.outlined_text(x - tw / 2, y - r - th * 0.9, '!', font, color)
}

// short_units: compact planar distance for the small map labels.
fn short_units(v f64) string {
	d := math.abs(v)
	return if d < 1000 {
		'${int(math.round(d))}'
	} else if d < 10000 {
		'${d / 1000:.1f}k'
	} else {
		'${int(math.round(d / 1000))}k'
	}
}

// draw_marker_label: [up/down triangle] planar distance, beside a marker at
// (x, y) of radius r; on its left when `left`, kept inside `bounds`.
fn (app &App) draw_marker_label(c Canvas, font GdipFont, t Target, x f32, y f32, r f32, left bool, bounds RectF) {
	if font.font == unsafe { nil } {
		return
	}
	text := short_units(t.planar)
	tw, th := c.text_size(text, font)
	show_tri := math.abs(t.dz) >= trend_threshold
	tri := th * 0.22
	tri_w := if show_tri { tri * 2 + th * 0.12 } else { f32(0) }
	total := tri_w + tw
	gap := r + 2
	mut lx := if left { x - gap - total } else { x + gap }
	lx = f32(math.max(bounds.x, math.min(lx, bounds.x + bounds.w - total)))
	ly := f32(math.max(bounds.y, math.min(y - th / 2, bounds.y + bounds.h - th)))
	white := u32(0xffffffff)
	if show_tri {
		mid := ly + th / 2
		pts := if t.dz > 0 {
			[PointF{lx, mid + tri}, PointF{lx + 2 * tri, mid + tri},
				PointF{lx + tri, mid - tri}]
		} else {
			[PointF{lx, mid - tri}, PointF{lx + 2 * tri, mid - tri},
				PointF{lx + tri, mid + tri}]
		}
		c.fill_polygon(pts, white)
		c.stroke_polygon(pts, 1.2, 0xe0000000)
	}
	c.outlined_text(lx + tri_w, ly, text, font, white)
}

// ---- settings controls ---------------------------------------------------------

fn (mut app App) set_overlay(on bool) {
	app.settings.overlay = on
	app.save()
	app.apply_overlay()
	if on {
		app.set_status('Map overlay on. Set "Game UI" to your UI Proportion; if it does not sit on the minimap, click "Unlock" and drag it there.',
			false)
	}
}

fn (mut app App) on_overlay_choice(id Ctl) {
	sel := int(C.SendMessageW(app.ctl(id), cb_getcursel, 0, 0))
	match id {
		.overlay_ui {
			if sel >= 0 && sel < ui_proportion_pcts.len {
				app.settings.overlay_ui_pct = ui_proportion_pcts[sel]
				// A new UI size moves the minimap: back to its default spot.
				app.reset_overlay_position()
				return
			}
		}
		.overlay_zoom {
			if sel >= 0 && sel < overlay_zooms.len {
				app.settings.overlay_zoom = overlay_zooms[sel]
			}
		}
		.overlay_opacity {
			if sel >= 0 && sel < overlay_opacities.len {
				app.settings.overlay_opacity = overlay_opacities[sel]
			}
		}
		else {}
	}
	app.save()
	app.render_overlay()
}

fn (mut app App) update_overlay_controls() {
	on := app.settings.overlay
	C.SendMessageW(app.ctl(.overlay), bm_setcheck, usize(on), 0)
	for id in [Ctl.overlay_ui, .overlay_zoom, .overlay_opacity, .overlay_unlock, .overlay_reset] {
		C.EnableWindow(app.ctl(id), int(on))
	}
	set_text(app.ctl(.overlay_unlock), if app.overlay_unlocked { 'Lock' } else { 'Unlock' })
	// Presets, plus the wheel-tuned value as an extra last entry so the
	// remembered zoom is visible.
	combo := app.ctl(.overlay_zoom)
	zoom := app.settings.overlay_zoom
	C.SendMessageW(combo, cb_resetcontent, 0, 0)
	for z in overlay_zooms {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(format_units(z).to_wide()))
	}
	mut sel := overlay_zooms.index(zoom)
	if sel < 0 {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(format_units(zoom).to_wide()))
		sel = overlay_zooms.len
	}
	C.SendMessageW(combo, cb_setcursel, usize(sel), 0)
}

// draw_zoom_reference marks where you stood when the overlay was unlocked;
// with the right zoom it stays on that spot of the minimap as you walk.
fn (app &App) draw_zoom_reference(c Canvas, cx f32, cy f32, scale f32) {
	ref := app.overlay_ref or { return }
	p := app.player or { return }
	dx, dy := ref.x - p.pos.x, ref.y - p.pos.y
	d := f32(math.hypot(dx, dy)) * scale
	if d < 3 {
		return
	}
	a := math.radians(app.compass().bearing(dx, dy))
	x, y := cx + f32(math.sin(a)) * d, cy - f32(math.cos(a)) * d
	arm := f32(app.s(7))
	for pass in 0 .. 2 {
		width := if pass == 0 { f32(4) } else { f32(2) }
		color := if pass == 0 { u32(0xc0000000) } else { u32(0xffffffff) }
		c.line(x - arm, y - arm, x + arm, y + arm, width, color)
		c.line(x - arm, y + arm, x + arm, y - arm, width, color)
	}
}

// draw_freshness_ring circles the player arrow: green = position updated in
// the last 5 s, yellow = up to 15 s, red = older (re-detecting) or none yet.
fn (app &App) draw_freshness_ring(c Canvas, cx f32, cy f32, fw f32) {
	color := if p := app.player {
		app.freshness_color(now_seconds() - p.timestamp)
	} else {
		app.theme.error
	}
	r := fw * 0.085
	width := f32(math.max(2.0, f64(fw) * 0.008))
	c.stroke_circle(cx, cy, r, width + 2, 0xa0000000)
	c.stroke_circle(cx, cy, r, width, with_alpha(color, 235))
}
