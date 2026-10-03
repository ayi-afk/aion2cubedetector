module main

import math
import proto

// Custom-drawn compass: player position in the corner, one arrow per
// collectable cube (nearest three within the compass range) and a color
// legend below the dial.

const compass_class = 'CubeWatchCompass'
const max_compass_targets = 3
// Compass range choices in planar world units; 0 = unlimited. Cubes are
// announced from roughly 15,000 units away.
const compass_ranges = [10000, 20000, 30000, 50000, 100000, 0]
const default_compass_range = 30000

fn range_label(r int) string {
	return if r == 0 { 'Unlimited' } else { format_units(r) }
}

// compass_targets: collectable cubes within the compass range, nearest first.
fn (app &App) compass_targets() []Target {
	limit := app.settings.compass_range
	return if limit == 0 { app.targets } else { app.targets.filter(it.planar <= limit) }
}

fn register_compass_class(instance voidptr) {
	cls := WndClassEx{
		size:       u32(sizeof(WndClassEx))
		wnd_proc:   voidptr(compass_proc)
		instance:   instance
		cursor:     C.LoadCursorW(unsafe { nil }, idc_arrow)
		class_name: compass_class.to_wide()
	}
	C.RegisterClassExW(&cls)
}

fn compass_proc(hwnd voidptr, msg u32, wparam usize, lparam isize) isize {
	if msg == wm_erasebkgnd {
		return 1 // painted fully in WM_PAINT; avoids flicker
	}
	if msg == wm_paint {
		ptr := C.GetWindowLongPtrW(C.GetParent(hwnd), gwlp_userdata)
		mut ps := PaintStruct{}
		hdc := C.BeginPaint(hwnd, &ps)
		if ptr != 0 {
			app := unsafe { &App(voidptr(ptr)) }
			app.paint_compass(hwnd, hdc)
		}
		C.EndPaint(hwnd, &ps)
		return 0
	}
	return C.DefWindowProcW(hwnd, msg, wparam, lparam)
}

fn draw_text(dc voidptr, text string, left int, top int, right int, bottom int) {
	draw_text_aligned(dc, text, left, top, right, bottom, dt_center)
}

fn draw_text_aligned(dc voidptr, text string, left int, top int, right int, bottom int, align u32) {
	mut rc := Rect{left, top, right, bottom}
	C.DrawTextW(dc, text.to_wide(), -1, &rc, align | dt_vcenter | dt_singleline | dt_end_ellipsis)
}

fn (app &App) paint_compass(hwnd voidptr, hdc voidptr) {
	mut rc := Rect{}
	C.GetClientRect(hwnd, &rc)
	w, h := rc.right, rc.bottom
	if w <= 0 || h <= 0 {
		return
	}
	// Draw off-screen, then copy, so updates several times a second do not
	// flicker.
	dc := C.CreateCompatibleDC(hdc)
	bmp := C.CreateCompatibleBitmap(hdc, w, h)
	old_bmp := C.SelectObject(dc, bmp)
	C.FillRect(dc, &rc, app.bg_brush)
	C.SetBkMode(dc, 1)
	old_font := C.SelectObject(dc, app.font)

	line := app.s(17)
	pad := app.s(4)
	in_range := app.compass_targets()
	shown := in_range#[..max_compass_targets]
	top := app.draw_position(dc, w, line) + pad
	legend_rows := math.max(shown.len, 1) + if app.targets.len > shown.len { 1 } else { 0 }
	mut bottom := h - legend_rows * line - pad
	if app.settings.compact && app.status_is_error {
		bottom -= line
		C.SetTextColor(dc, app.theme.error)
		draw_text(dc, app.status_text, 0, h - line, w, h)
	}
	r := math.max(math.min(w - 2 * pad, bottom - top - 2 * pad) / 2, app.s(20))
	cx, cy := w / 2, top + pad + r
	app.draw_dial(dc, cx, cy, r)

	if app.calibrating {
		// Show what to do instead of the cube arrows.
		app.draw_arrow(dc, cx, cy, f64(r) * 0.82, 0, app.theme.text)
		C.SetTextColor(dc, app.theme.text)
		draw_text(dc, 'Walk UP on minimap, then stop', 0, cy + r + pad, w, cy + r + pad + line)
		C.BitBlt(hdc, 0, 0, w, h, dc, 0, 0, srccopy)
		C.SelectObject(dc, old_font)
		C.SelectObject(dc, old_bmp)
		C.DeleteObject(bmp)
		C.DeleteDC(dc)
		return
	}
	// Farthest first so the nearest arrow ends up on top.
	for i := shown.len - 1; i >= 0; i-- {
		t := shown[i]
		scale := if i == 0 { 0.82 } else { 0.66 }
		app.draw_arrow(dc, cx, cy, f64(r) * scale, t.bearing, app.target_color(t))
	}
	mut y := cy + r + pad
	if shown.len == 0 {
		C.SetTextColor(dc, app.theme.dim)
		draw_text(dc, if app.targets.len > 0 { 'no cube in range' } else { 'no cube to point at' },
			0, y, w, y + line)
		y += line
	}
	for i, t in shown {
		app.draw_legend_row(dc, t, i == 0, pad, y, w - pad, y + line)
		y += line
	}
	if app.targets.len > shown.len {
		far := app.targets.len - in_range.len
		more := in_range.len - shown.len
		text := if far == 0 {
			'+${more} more (see list)'
		} else if more == 0 {
			'+${far} too far (see list)'
		} else {
			'+${more} more, ${far} too far'
		}
		C.SetTextColor(dc, app.theme.dim)
		draw_text(dc, text, 0, y, w, y + line)
	}

	C.BitBlt(hdc, 0, 0, w, h, dc, 0, 0, srccopy)
	C.SelectObject(dc, old_font)
	C.SelectObject(dc, old_bmp)
	C.DeleteObject(bmp)
	C.DeleteDC(dc)
}

fn (app &App) target_color(t Target) u32 {
	return if app.targets_stale { app.fade(t.color) } else { t.color }
}

// draw_legend_row: [color square] #n  NE  2,737  [up/down triangle] 200
fn (app &App) draw_legend_row(dc voidptr, t Target, nearest bool, left int, top int, right int, bottom int) {
	color := app.target_color(t)
	sq := app.s(10)
	mid := (top + bottom) / 2
	brush := C.CreateSolidBrush(color)
	mut box := Rect{left, mid - sq / 2, left + sq, mid + sq / 2}
	C.FillRect(dc, &box, brush)
	C.DeleteObject(brush)

	// (An if-expression over voidptr fields does not compile here.)
	mut font := app.font
	if nearest {
		font = app.bold_font
	}
	old := C.SelectObject(dc, font)
	text_color := if t.contest { app.theme.contested } else { color }
	C.SetTextColor(dc, text_color)
	flag := if t.contest { '!' } else { '' }
	text_left := left + sq + app.s(5)
	height_w := app.s(62)
	draw_text_aligned(dc, '${flag}#${t.number}  ${proto.point_short(t.bearing)}  ${format_units(t.planar)}',
		text_left, top, right - height_w, bottom, dt_left)

	// Height: small triangle up (above you) / down (below you), or "level".
	C.SetTextColor(dc, app.theme.dim)
	hx := right - height_w + app.s(4)
	if math.abs(t.dz) < trend_threshold {
		draw_text_aligned(dc, 'level', hx, top, right, bottom, dt_left)
	} else {
		tri := app.s(4)
		up := t.dz > 0
		app.fill_triangle(dc, hx, mid, tri, up, app.theme.dim)
		draw_text_aligned(dc, format_units(t.dz), hx + 3 * tri, top, right, bottom, dt_left)
	}
	C.SelectObject(dc, old)
}

// fill_triangle: small up/down triangle `2*tri` wide centred on mid.
fn (app &App) fill_triangle(dc voidptr, hx int, mid int, tri int, up bool, color u32) {
	if g := app.gdip {
		x, m, d := f32(hx), f32(mid), f32(tri)
		pts := if up {
			[PointF{x, m + d}, PointF{x + 2 * d, m + d}, PointF{x + d, m - d}]
		} else {
			[PointF{x, m - d}, PointF{x + 2 * d, m - d}, PointF{x + d, m + d}]
		}
		if g.fill_polygon(dc, pts, color) {
			return
		}
	}
	pts := if up {
		[Point{hx, mid + tri}, Point{hx + 2 * tri, mid + tri},
			Point{hx + tri, mid - tri}]
	} else {
		[Point{hx, mid - tri}, Point{hx + 2 * tri, mid - tri},
			Point{hx + tri, mid + tri}]
	}
	pen := C.CreatePen(0, 1, color)
	fill := C.CreateSolidBrush(color)
	old_pen := C.SelectObject(dc, pen)
	old_brush := C.SelectObject(dc, fill)
	C.Polygon(dc, pts.data, pts.len)
	C.SelectObject(dc, old_pen)
	C.SelectObject(dc, old_brush)
	C.DeleteObject(pen)
	C.DeleteObject(fill)
}

// draw_position shows the player position in the top-left corner with a
// dot that lights up when a fresh position arrived; returns its height.
fn (app &App) draw_position(dc voidptr, w int, line int) int {
	p := app.player or {
		C.SetTextColor(dc, app.theme.dim)
		draw_text_aligned(dc, 'waiting for your position...', 0, 0, w, line, dt_left)
		return line
	}

	age := now_seconds() - p.timestamp
	dot := app.s(8)
	brush := C.CreateSolidBrush(app.freshness_color(age))
	mut box := Rect{0, (line - dot) / 2, dot, (line + dot) / 2}
	C.FillRect(dc, &box, brush)
	C.DeleteObject(brush)
	// While re-detecting the old position stays on screen, in yellow.
	redetecting := age >= player_redetect_seconds
	C.SetTextColor(dc, if redetecting { app.theme.warn } else { app.theme.text })
	x := dot + app.s(4)
	draw_text_aligned(dc, 'X ${format_signed(p.pos.x)}  Y ${format_signed(p.pos.y)}',
		x, 0, w, line, dt_left)
	C.SetTextColor(dc, if redetecting { app.theme.warn } else { app.theme.dim })
	draw_text_aligned(dc, 'Z ${format_signed(p.pos.z)}  (${age:.0f}s ago)', x, line, w,
		2 * line, dt_left)
	return 2 * line
}

fn (app &App) draw_dial(dc voidptr, cx int, cy int, r int) {
	edge := C.CreatePen(0, 1, app.theme.dial_edge)
	face := C.CreateSolidBrush(app.theme.dial_face)
	old_pen := C.SelectObject(dc, edge)
	old_brush := C.SelectObject(dc, face)
	mut smooth := false
	if g := app.gdip {
		smooth = g.circle(dc, f32(cx), f32(cy), f32(r), app.theme.dial_face, app.theme.dial_edge)
	}
	if !smooth {
		C.Ellipse(dc, cx - r, cy - r, cx + r, cy + r)
	}
	C.SetTextColor(dc, app.theme.dim)
	letter := app.s(16)
	draw_text(dc, 'N', cx - letter, cy - r, cx + letter, cy - r + letter + 2)
	draw_text(dc, 'S', cx - letter, cy + r - letter - 2, cx + letter, cy + r)
	draw_text(dc, 'W', cx - r + 2, cy - letter, cx - r + letter + 2, cy + letter)
	draw_text(dc, 'E', cx + r - letter - 2, cy - letter, cx + r - 2, cy + letter)
	C.SelectObject(dc, old_pen)
	C.SelectObject(dc, old_brush)
	C.DeleteObject(edge)
	C.DeleteObject(face)
}

// fade blends a color halfway towards the dial face (used while the
// position is old).
fn (app &App) fade(c u32) u32 {
	face := app.theme.dial_face
	mix := fn [c, face] (shift u32) u32 {
		return ((((c >> shift) & 0xff) + ((face >> shift) & 0xff)) / 2) << shift
	}
	return mix(0) | mix(8) | mix(16)
}

// draw_arrow draws a needle of length `len` rotated `bearing` degrees
// clockwise from screen-up (north).
fn (app &App) draw_arrow(dc voidptr, cx int, cy int, len f64, bearing f64, color u32) {
	// Needle outline pointing up, in units of `len` (screen y grows down).
	shape := [[0.0, -1.0], [0.13, 0.3], [0.0, 0.18], [-0.13, 0.3]]
	a := math.radians(bearing)
	sin, cos := math.sin(a), math.cos(a)
	if g := app.gdip {
		mut fpts := []PointF{}
		for p in shape {
			x, y := p[0] * len, p[1] * len
			fpts << PointF{f32(f64(cx) + x * cos - y * sin), f32(f64(cy) + x * sin + y * cos)}
		}
		if g.fill_polygon(dc, fpts, color) {
			return
		}
	}
	mut pts := []Point{}
	for p in shape {
		x, y := p[0] * len, p[1] * len
		pts << Point{cx + int(math.round(x * cos - y * sin)), cy + int(math.round(x * sin +
			y * cos))}
	}
	pen := C.CreatePen(0, 1, color)
	brush := C.CreateSolidBrush(color)
	old_pen := C.SelectObject(dc, pen)
	old_brush := C.SelectObject(dc, brush)
	C.Polygon(dc, pts.data, pts.len)
	C.SelectObject(dc, old_pen)
	C.SelectObject(dc, old_brush)
	C.DeleteObject(pen)
	C.DeleteObject(brush)
}
