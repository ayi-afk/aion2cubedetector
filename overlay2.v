module main

import math
import proto

// Second map overlay: a transparent, click-through window laid over the
// game's large see-through map (the one with the "Map Opacity" slider),
// which keeps the character in its middle. Besides the cubes in view it
// shows what the backend knows: every place something was seen at
// ("History"), what is there right now on this game server, and the other
// Cube Watch players on it ("Players"). It is moved, resized and zoomed
// like the first overlay ("Unlock"); the window code they share is in
// overlay.v.

const overlay2_class = 'CubeWatchMapOverlay2'
// World units shown across the overlay's width: presets, and the range the
// mouse wheel can fine-tune it to while unlocked.
const overlay2_zooms = [20000, 30000, 40000, 60000, 80000, 120000, 160000]
const default_overlay2_zoom = 60000
const overlay2_zoom_min = 5000
const overlay2_zoom_max = 400000
// An empty place whose expected respawn is overdue by more than this many
// seconds gets no "due" any more: the next one most likely came and went unseen.
const overlay2_due_seconds = 600.0
// Default box: a square in the middle of the screen, this share of its height.
const overlay2_default_size = 0.5

fn register_overlay2_class(instance voidptr) {
	cls := WndClassEx{
		size:       u32(sizeof(WndClassEx))
		wnd_proc:   voidptr(overlay2_proc)
		instance:   instance
		cursor:     C.LoadCursorW(unsafe { nil }, idc_arrow)
		class_name: overlay2_class.to_wide()
	}
	C.RegisterClassExW(&cls)
}

fn overlay2_proc(hwnd voidptr, msg u32, wparam usize, lparam isize) isize {
	ptr := C.GetWindowLongPtrW(hwnd, gwlp_userdata)
	if ptr != 0 {
		mut app := unsafe { &App(voidptr(ptr)) }
		if r := app.overlay2_message(msg, wparam) {
			return r
		}
	}
	return C.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// overlay2_rect: the saved position (fractions of the screen), or the default.
fn (app &App) overlay2_rect() Rect {
	s := app.settings
	sw, sh := primary_screen()
	if s.overlay2_w <= 0 || s.overlay2_h <= 0 {
		side := int(overlay2_default_size * f64(sh))
		return Rect{(sw - side) / 2, (sh - side) / 2, (sw + side) / 2, (sh + side) / 2}
	}
	x, y := int(s.overlay2_x * sw), int(s.overlay2_y * sh)
	return Rect{x, y, x + int(s.overlay2_w * sw), y + int(s.overlay2_h * sh)}
}

// apply_overlay2 shows, hides or repositions the overlay after a settings change.
fn (mut app App) apply_overlay2() {
	if !app.settings.overlay2 {
		if app.overlay2_hwnd != unsafe { nil } {
			C.ShowWindow(app.overlay2_hwnd, sw_hide)
		}
		app.overlay2_unlocked = false
		app.update_overlay2_controls()
		return
	}
	if app.overlay2_hwnd == unsafe { nil } {
		ex := ws_ex_layered | ws_ex_topmost | ws_ex_toolwindow | ws_ex_noactivate | ws_ex_transparent
		app.overlay2_hwnd = C.CreateWindowExW(ex, overlay2_class.to_wide(), 'Cube Watch map overlay 2'.to_wide(),
			ws_popup, 0, 0, 10, 10, unsafe { nil }, unsafe { nil }, app.instance, unsafe { nil })
		if app.overlay2_hwnd == unsafe { nil } {
			app.set_status('Cannot create the second map overlay window.', true)
			return
		}
		C.SetWindowLongPtrW(app.overlay2_hwnd, gwlp_userdata, isize(voidptr(app)))
	}
	rc := app.overlay2_rect()
	C.SetWindowPos(app.overlay2_hwnd, voidptr(isize(hwnd_topmost)), rc.left, rc.top, rc.right - rc.left,
		rc.bottom - rc.top, swp_noactivate)
	C.ShowWindow(app.overlay2_hwnd, 4) // SW_SHOWNOACTIVATE: never take focus from the game
	app.render_overlay2()
	app.update_overlay2_controls()
}

fn (mut app App) set_overlay2(on bool) {
	app.settings.overlay2 = on
	app.save()
	app.apply_overlay2()
	// The backend sends what is around only while the overlay is on.
	app.remote_watch()
	if on {
		app.set_status('Map overlay 2 on. Open the game\'s see-through map, click "Unlock" and drag the overlay over it so that the cross sits on your arrow.',
			false)
	}
}

fn (mut app App) set_overlay2_unlocked(unlocked bool) {
	if app.overlay2_hwnd == unsafe { nil } || !app.settings.overlay2 {
		return
	}
	app.overlay2_unlocked = unlocked
	// Zoom reference: where you stand now, drawn as a cross once you move.
	app.overlay2_ref = if unlocked {
		if p := app.player { ?proto.Vec3(p.pos) } else { none }
	} else {
		none
	}
	mut ex := u32(C.GetWindowLongPtrW(app.overlay2_hwnd, gwl_exstyle))
	ex = if unlocked { ex & ~ws_ex_transparent } else { ex | ws_ex_transparent }
	C.SetWindowLongPtrW(app.overlay2_hwnd, gwl_exstyle, isize(ex))
	app.render_overlay2()
	app.update_overlay2_controls()
	if unlocked {
		app.set_status('Overlay 2 unlocked: drag it over the game\'s see-through map (edges resize) until the cross sits on your arrow. Zoom: mouse wheel over it until the marks sit on their places of the map (or walk away and bring the white X onto the spot you started from). Right-click or "Lock" when done.',
			false)
	}
}

fn (mut app App) reset_overlay2_position() {
	app.settings.overlay2_x, app.settings.overlay2_y = 0, 0
	app.settings.overlay2_w, app.settings.overlay2_h = 0, 0
	app.save()
	app.apply_overlay2()
}

fn (mut app App) overlay2_message(msg u32, wparam usize) ?isize {
	match msg {
		wm_mouseactivate {
			return ma_noactivate
		}
		wm_setcursor {
			if !app.overlay2_unlocked {
				return none
			}
			mut edges := app.overlay2_drag
			if edges < 0 {
				edges, _ = app.overlay_cursor_edges(app.overlay2_hwnd)
			}
			C.SetCursor(C.LoadCursorW(unsafe { nil }, edges_cursor(edges)))
			return 1
		}
		wm_lbuttondown {
			if !app.overlay2_unlocked {
				return none
			}
			edges, pt := app.overlay_cursor_edges(app.overlay2_hwnd)
			app.overlay2_drag = edges
			app.overlay2_drag_pt = pt
			C.GetWindowRect(app.overlay2_hwnd, &app.overlay2_drag_rect)
			C.SetCapture(app.overlay2_hwnd)
			return 0
		}
		wm_mousemove {
			if app.overlay2_drag < 0 {
				return none
			}
			mut pt := Point{}
			C.GetCursorPos(&pt)
			rc := app.dragged_rect(app.overlay2_drag_rect, app.overlay2_drag, pt.x - app.overlay2_drag_pt.x,
				pt.y - app.overlay2_drag_pt.y)
			C.SetWindowPos(app.overlay2_hwnd, unsafe { nil }, rc.left, rc.top, rc.right - rc.left,
				rc.bottom - rc.top, swp_nozorder | swp_noactivate)
			app.render_overlay2()
			return 0
		}
		wm_lbuttonup {
			if app.overlay2_drag < 0 {
				return none
			}
			app.overlay2_drag = -1
			C.ReleaseCapture()
			mut rc := Rect{}
			C.GetWindowRect(app.overlay2_hwnd, &rc)
			sw, sh := primary_screen()
			app.settings.overlay2_x = f64(rc.left) / sw
			app.settings.overlay2_y = f64(rc.top) / sh
			app.settings.overlay2_w = f64(rc.right - rc.left) / sw
			app.settings.overlay2_h = f64(rc.bottom - rc.top) / sh
			app.save()
			return 0
		}
		wm_mousewheel {
			if !app.overlay2_unlocked {
				return none
			}
			// Wheel up = zoom in (fewer world units across the map).
			delta := i16(u16(hiword(wparam)))
			factor := if delta > 0 { 0.95 } else { 1.0 / 0.95 }
			zoom := int(math.round(f64(app.settings.overlay2_zoom) * factor))
			app.settings.overlay2_zoom = clamp(zoom, overlay2_zoom_min, overlay2_zoom_max)
			app.update_overlay2_controls()
			app.save()
			app.render_overlay2()
			app.set_status('Overlay 2 zoom: ${format_units(app.settings.overlay2_zoom)} units across it.',
				false)
			return 0
		}
		wm_rbuttonup {
			if app.overlay2_unlocked {
				app.set_overlay2_unlocked(false)
				return 0
			}
			return none
		}
		else {
			return none
		}
	}
}

fn (mut app App) render_overlay2() {
	if app.overlay2_hwnd == unsafe { nil } || !app.settings.overlay2 {
		return
	}
	opacity := if app.overlay2_unlocked {
		math.max(app.settings.overlay2_opacity, 70)
	} else {
		app.settings.overlay2_opacity
	}
	app.paint_layered(app.overlay2_hwnd, opacity, true)
}

// ---- drawing -----------------------------------------------------------------

// Overlay2View places world positions on the overlay: the character in the
// middle, map north up.
struct Overlay2View {
	compass proto.Compass
	px      f64
	py      f64
	cx      f32
	cy      f32
	scale   f32 // overlay pixels per world unit
	w       f32
	h       f32
}

fn (v Overlay2View) at(x f64, y f64) (f32, f32) {
	dx, dy := x - v.px, y - v.py
	d := f32(math.hypot(dx, dy)) * v.scale
	a := math.radians(v.compass.bearing(dx, dy))
	return v.cx + f32(math.sin(a)) * d, v.cy - f32(math.cos(a)) * d
}

fn (v Overlay2View) shows(x f32, y f32) bool {
	return x >= 0 && x <= v.w && y >= 0 && y <= v.h
}

// short_span: "45s", "12m", "3h" for the countdown under an empty place.
fn short_span(seconds f64) string {
	s := math.abs(seconds)
	return if s < 60 {
		'${int(s)}s'
	} else if s < 3600 {
		'${int(s / 60)}m'
	} else {
		'${int(s / 3600)}h'
	}
}

fn (app &App) draw_overlay2(c Canvas, w int, h int) {
	fw, fh := f32(w), f32(h)
	cx, cy := fw / 2, fh / 2
	accent := u32(0xffe0a020) // cube-watch orange, ARGB
	if app.overlay2_unlocked {
		// Alignment aid: frame and a cross for the player arrow.
		c.fill_rect(0, 0, fw, fh, 0x50000000)
		c.stroke_rect(1, 1, fw - 2, fh - 2, 2, accent)
		arm := f32(app.s(18))
		c.line(cx - arm, cy, cx + arm, cy, 2, accent)
		c.line(cx, cy - arm, cx, cy + arm, 2, accent)
		grip := f32(app.s(6))
		for p in [[f32(0), 0], [fw - grip, 0], [f32(0), fh - grip],
			[fw - grip, fh - grip]] {
			c.fill_rect(p[0], p[1], grip, grip, accent)
		}
	}
	p := app.player or { return }
	view := Overlay2View{
		compass: app.compass()
		px:      p.pos.x
		py:      p.pos.y
		cx:      cx
		cy:      cy
		scale:   fw / f32(app.settings.overlay2_zoom)
		w:       fw
		h:       fh
	}
	font := c.new_font('Segoe UI', f32(math.max(10.0, f64(w) * 0.022))) or { GdipFont{} }
	defer {
		if font.font != unsafe { nil } {
			c.free_font(font)
		}
	}
	outline := u32(0xd0000000)
	white := u32(0xffffffff)
	small := f32(math.max(2.5, f64(w) * 0.006))
	big := f32(math.max(4.5, f64(w) * 0.011))
	hub_now := now_seconds() + app.area_skew

	// 1. Places something was seen at but nothing is at now: small faint dots,
	// with the time until the next one where the backend expects one.
	if app.settings.overlay2_history {
		for s in app.area_spots {
			if s.present {
				continue
			}
			x, y := view.at(s.x, s.y)
			if !view.shows(x, y) {
				continue
			}
			// greyed out: a place, not a cube
			c.fill_circle(x, y, small, 0x90a4adba)
			c.stroke_circle(x, y, small, 1, 0x80000000)
			left := f64(s.expected) - hub_now
			if s.expected > 0 && left > -overlay2_due_seconds && font.font != unsafe { nil } {
				text := if left > 0 { short_span(left) } else { 'due' }
				tw, _ := c.text_size(text, font)
				c.outlined_text(x - tw / 2, y + small + 1, text, font, if left < 120 {
					u32(0xfffab219)
				} else {
					u32(0xffcfd8e6)
				})
			}
		}
		if app.area_spots.len == 0 && !app.remote_online {
			// No backend: the places of this PC's own history files.
			for s in app.history_spots {
				x, y := view.at(s.x, s.y)
				if view.shows(x, y) {
					c.fill_rect(x - small, y - small, 2 * small, 2 * small, 0x90a4adba)
				}
			}
		}
	}
	// 2. What is there right now on this game server, as the backend knows it.
	for s in app.area_spots {
		if !s.present {
			continue
		}
		x, y := view.at(s.x, s.y)
		if !view.shows(x, y) {
			continue
		}
		c.fill_circle(x, y, big + 4, 0x48000000 | s.color)
		c.fill_circle(x, y, big, 0xff000000 | s.color)
		c.stroke_circle(x, y, big, 1.5, white)
	}
	// 3. The cubes this client sees itself, in their list colors.
	limit := app.settings.compass_range
	targets := app.compass_targets()
	for i := targets.len - 1; i >= 0; i-- {
		t := targets[i]
		a := math.radians(t.bearing)
		d := f32(t.planar) * view.scale
		x, y := cx + f32(math.sin(a)) * d, cy - f32(math.cos(a)) * d
		if !view.shows(x, y) {
			continue
		}
		r := if i == 0 { big * 1.3 } else { big }
		c.fill_circle(x, y, r, with_alpha(app.target_color(t), 255))
		c.stroke_circle(x, y, r, 1.5, if t.contest {
			with_alpha(app.theme.contested, 255)
		} else {
			outline
		})
		app.draw_marker_label(c, font, t, x, y, r, x + r * 8 > fw, RectF{0, 0, fw, fh})
		app.draw_opening_alert(c, font, t, x, y, r)
	}
	// Taken in the last few seconds: a red X where the cube was.
	for t in app.taken {
		if limit > 0 && t.planar > limit {
			continue
		}
		a := math.radians(t.bearing)
		d := f32(t.planar) * view.scale
		x, y := cx + f32(math.sin(a)) * d, cy - f32(math.cos(a)) * d
		if !view.shows(x, y) {
			continue
		}
		arm := big * 1.3
		for pass in 0 .. 2 {
			width := if pass == 0 { big * 0.9 } else { big * 0.5 }
			color := if pass == 0 { outline } else { u32(0xffe02424) }
			c.line(x - arm, y - arm, x + arm, y + arm, width, color)
			c.line(x - arm, y + arm, x + arm, y - arm, width, color)
		}
	}
	// 4. The other Cube Watch players on this game server and map.
	if app.settings.overlay2_players {
		for person in app.area_people {
			x, y := view.at(person.x, person.y)
			if !view.shows(x, y) {
				continue
			}
			c.fill_circle(x, y, big, 0xff4cc9f0)
			c.stroke_circle(x, y, big, 1.5, white)
			if font.font != unsafe { nil } {
				tw, _ := c.text_size(person.name, font)
				c.outlined_text(x - tw / 2, y + big + 1, person.name, font, white)
			}
		}
	}
	if app.overlay2_unlocked {
		// With the right zoom the white X stays on the spot of the map where
		// you stood when the overlay was unlocked.
		if ref := app.overlay2_ref {
			x, y := view.at(ref.x, ref.y)
			if math.hypot(x - cx, y - cy) >= 3 {
				arm := f32(app.s(7))
				for pass in 0 .. 2 {
					width := if pass == 0 { f32(4) } else { f32(2) }
					color := if pass == 0 { u32(0xc0000000) } else { white }
					c.line(x - arm, y - arm, x + arm, y + arm, width, color)
					c.line(x - arm, y + arm, x + arm, y - arm, width, color)
				}
			}
		}
	}
}

// ---- settings controls ---------------------------------------------------------

fn (mut app App) on_overlay2_choice(id Ctl) {
	sel := int(C.SendMessageW(app.ctl(id), cb_getcursel, 0, 0))
	if id == .overlay2_zoom && sel >= 0 && sel < overlay2_zooms.len {
		app.settings.overlay2_zoom = overlay2_zooms[sel]
	} else if id == .overlay2_opacity && sel >= 0 && sel < overlay_opacities.len {
		app.settings.overlay2_opacity = overlay_opacities[sel]
	}
	app.save()
	app.render_overlay2()
}

fn (mut app App) update_overlay2_controls() {
	on := app.settings.overlay2
	C.SendMessageW(app.ctl(.overlay2), bm_setcheck, usize(on), 0)
	for id in [Ctl.overlay2_zoom, .overlay2_opacity, .overlay2_unlock, .overlay2_reset,
		.overlay2_history, .overlay2_players] {
		C.EnableWindow(app.ctl(id), int(on))
	}
	set_text(app.ctl(.overlay2_unlock), if app.overlay2_unlocked { 'Lock' } else { 'Unlock' })
	// Presets, plus the wheel-tuned value as an extra last entry.
	combo := app.ctl(.overlay2_zoom)
	zoom := app.settings.overlay2_zoom
	C.SendMessageW(combo, cb_resetcontent, 0, 0)
	for z in overlay2_zooms {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(format_units(z).to_wide()))
	}
	mut sel := overlay2_zooms.index(zoom)
	if sel < 0 {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(format_units(zoom).to_wide()))
		sel = overlay2_zooms.len
	}
	C.SendMessageW(combo, cb_setcursel, usize(sel), 0)
}
