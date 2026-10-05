module main

import math
import os
import proto
import strings
import time

const app_title = 'Cube Watch'
const window_class = 'CubeWatchMainWindow'
const npcap_download_url = 'https://npcap.com/#download'

const wm_capture = wm_app + 1
const wm_tray = wm_app + 2
const wm_show_instance = wm_app + 3

const timer_refresh = usize(1)
const timer_npcap_check = usize(2)
const tray_id = u32(1)

// The server echoes the local player's position only occasionally, so the
// last known fix is always used; past this age it is shown as stale.
const stale_position_seconds = 10.0
// Entering an instance gives the character a new entity id, so updates for
// it are ignored; past this age the player is detected again (and again
// every this many seconds while no fresh position arrives).
const player_redetect_seconds = 15.0
// Position freshness shown by the compass dot and the overlay ring: green
// below this age, yellow until player_redetect_seconds, then red.
const fresh_position_seconds = 5.0
// Minimum distance change (world units) reported as moving closer/farther.
const trend_threshold = 10.0
// Opened or vanished cubes stay listed (greyed) this long, then are removed.
const cube_linger_seconds = 20.0
// A taken (opened / destroyed) cube shows a red X on the map overlay this long.
const taken_marker_seconds = 5.0

enum Ctl {
	status = 100
	install_npcap
	adapter_label
	adapter
	start_stop
	player
	redetect
	nearest
	list
	clear
	copy
	sound_label
	sound_mode
	sound_file
	browse
	test_sound
	opacity_label
	opacity
	opacity_value
	topmost
	close_to_tray
	run_as_admin
	compass
	calibrate
	rotate_north
	view_toggle
	dark_mode
	range_label
	compass_range
	overlay
	overlay_ui_label
	overlay_ui
	overlay_zoom_label
	overlay_zoom
	overlay_opacity_label
	overlay_opacity
	overlay_unlock
	overlay_reset
	history_toggle
	history
	overlay_xyz
	xyz_alpha
	xyz_order
	overlay_ring
	ring_radius
	auto_clear_label
	auto_clear
	overlay_history
}

// Controls shown only in the standard (full) view.
const standard_only_controls = [Ctl.status, .adapter_label, .adapter, .start_stop, .player, .redetect,
	.nearest, .list, .clear, .copy, .sound_label, .sound_mode, .sound_file, .browse, .test_sound,
	.opacity_label, .opacity, .opacity_value, .topmost, .close_to_tray, .dark_mode, .calibrate,
	.rotate_north, .range_label, .compass_range, .overlay, .overlay_ui_label, .overlay_ui,
	.overlay_zoom_label, .overlay_zoom, .overlay_opacity_label, .overlay_opacity, .overlay_unlock,
	.overlay_reset, .history_toggle, .history, .overlay_xyz, .xyz_alpha, .xyz_order, .overlay_ring,
	.ring_radius, .auto_clear_label, .auto_clear, .overlay_history]

// List view columns.
const col_seen = 1
const col_state = 2
const col_distance = 3
const col_height = 4
const col_x = 5
const col_y = 6
const col_z = 7

enum TrayCmd {
	show = 1
	topmost
	compact
	dark_mode
	calibrate
	overlay
	overlay_unlock
	clear_cubes
	exit
}

enum CubeState {
	available
	out_of_view
	opening
	opened
	gone
}

struct CubeRow {
	number int
	id     u64
	seen   string
mut:
	pos   proto.Vec3
	state CubeState
	actor u64 // player opening / who opened the cube
	ended f64 // when it was opened or vanished (0 = still there)
	// For the history CSV (history.v).
	appeared       f64 // first seen
	spawned        int = -1 // appeared inside the view range: 1 / 0 / -1 unknown
	first_distance f64 = -1 // planar distance at first sight
	logged         bool
}

// is_target reports whether the cube can still be collected.
fn (c CubeRow) is_target() bool {
	return c.state in [.available, .out_of_view, .opening]
}

// Target is one collectable cube as the compass shows it.
struct Target {
	number  int
	color   u32
	bearing f64
	planar  f64
	dz      f64
	contest bool // another player is opening it
	opening bool // someone (anyone) is opening it
}

struct PlayerFix {
	pos       proto.Vec3
	timestamp f64
}

@[heap]
struct App {
mut:
	hwnd         voidptr
	instance     voidptr
	font         voidptr
	bold_font    voidptr
	theme        Theme
	bg_brush     voidptr
	field_brush  voidptr
	icon         voidptr
	dpi          int = 96
	settings     Settings
	start_hidden bool
	replay_path  string
	trial        Trial
	gdip         ?Gdip // antialiased compass drawing
	// Cube history (history.v): rows newest first, this session's CSV,
	// grouped spots for the overlay and whether the History list is shown.
	history       []HistoryRow
	history_file  string
	history_spots []HistorySpot
	history_view  bool
	// Map overlay window (overlay.v); drag = edge bits while moving, -1 idle.
	overlay_hwnd       voidptr
	overlay_unlocked   bool
	overlay_drag       int = -1
	overlay_drag_pt    Point
	overlay_drag_rect  Rect
	overlay_topmost_at f64
	overlay_ref        ?proto.Vec3 // zoom reference point while unlocked
	trial_ended        bool
	npcap              ?Npcap
	devices            []Device
	capture            &Capture = unsafe { nil }
	restart_pending    bool
	status_is_error    bool
	elevated           bool
	controls           map[int]voidptr
	cubes              []CubeRow // newest first, matches list view order
	cube_count         int
	player             ?PlayerFix
	player_id          ?u64
	trend_ref          ?f64
	trend_ref_time     f64
	trend              f64
	targets            []Target // nearest first
	taken              []Target // cubes taken in the last taken_marker_seconds
	targets_stale      bool     // player position is old
	calibrating        bool
	calib_start        PlayerFix // position when calibration started
	last_refresh       f64
	last_redetect      f64 // last automatic player re-detection
	status_text        string
	install_visible    bool
	admin_visible      bool
	dirty              bool
	tray_added         bool
	tray_hint_shown    bool
	taskbar_created    u32
}

fn (app &App) ctl(id Ctl) voidptr {
	return app.controls[int(id)] or { unsafe { nil } }
}

fn (app &App) s(v int) int {
	return v * app.dpi / 96
}

fn now_seconds() f64 {
	return f64(time.now().unix_milli()) / 1000.0
}

fn format_units(v f64) string {
	n := i64(math.round(math.abs(v)))
	digits := n.str()
	mut sb := strings.new_builder(digits.len + 4)
	for i, c in digits {
		if i > 0 && (digits.len - i) % 3 == 0 {
			sb.write_u8(`,`)
		}
		sb.write_u8(c)
	}
	return sb.str()
}

fn format_signed(v f64) string {
	sign := if v < 0 && math.round(v) != 0 { '-' } else { '+' }
	return sign + format_units(v)
}

fn format_pos(p proto.Vec3) string {
	return '${p.x:.1f}, ${p.y:.1f}, ${p.z:.1f}'
}

// ---- window creation -------------------------------------------------------

fn (mut app App) add(id Ctl, class string, text string, style u32, ex_style u32) voidptr {
	hwnd := C.CreateWindowExW(ex_style, class.to_wide(), text.to_wide(), ws_child | ws_visible | style,
		0, 0, 10, 10, app.hwnd, voidptr(usize(int(id))), app.instance, unsafe { nil })
	C.SendMessageW(hwnd, wm_setfont, usize(app.font), 1)
	app.controls[int(id)] = hwnd
	return hwnd
}

// add_choices adds a drop-down list with `items`, selecting `sel`.
fn (mut app App) add_choices(id Ctl, items []string, sel int) voidptr {
	combo := app.add(id, 'COMBOBOX', '', ws_tabstop | ws_vscroll | cbs_dropdownlist, 0)
	for item in items {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(item.to_wide()))
	}
	C.SendMessageW(combo, cb_setcursel, usize(sel), 0)
	return combo
}

fn (mut app App) on_create() {
	app.capture = &Capture{
		notify_hwnd: app.hwnd
		notify_msg:  wm_capture
	}
	app.add(.status, 'STATIC', 'Starting...', ss_endellipsis, 0)
	install := app.add(.install_npcap, 'BUTTON', 'Install Npcap', ws_tabstop | bs_pushbutton,
		0)
	C.SendMessageW(install, bm_setimage, image_icon, ptr_param(C.LoadIconW(unsafe { nil },
		idi_shield)))
	run_as_admin := app.add(.run_as_admin, 'BUTTON', 'Run as administrator', ws_tabstop | bs_pushbutton,
		0)
	C.SendMessageW(run_as_admin, bm_setimage, image_icon, ptr_param(C.LoadIconW(unsafe { nil },
		idi_shield)))
	C.ShowWindow(run_as_admin, sw_hide)
	// Let a non-elevated second launch bring an elevated window forward.
	allow_msg := proc_address('user32.dll', 'ChangeWindowMessageFilterEx')
	if allow_msg != unsafe { nil } {
		change_filter := FnChangeWindowMessageFilterEx(allow_msg)
		change_filter(app.hwnd, wm_show_instance, 1, unsafe { nil })
	}
	app.add(.adapter_label, 'STATIC', 'Adapter:', 0, 0)
	app.add(.adapter, 'COMBOBOX', '', ws_tabstop | ws_vscroll | cbs_dropdownlist, 0)
	app.add(.start_stop, 'BUTTON', 'Start', ws_tabstop | bs_pushbutton, 0)
	app.add(.player, 'STATIC', 'Player: waiting for position updates', ss_endellipsis,
		0)
	app.add(.redetect, 'BUTTON', 'Re-detect player', ws_tabstop | bs_pushbutton, 0)
	app.add(.view_toggle, 'BUTTON', if app.settings.compact {
		'Standard view'
	} else {
		'Compact view'
	}, ws_tabstop | bs_pushbutton, 0)
	app.add(.nearest, 'STATIC', 'No cubes detected yet.', ss_endellipsis, 0)
	list := app.add(.list, 'SysListView32', '', ws_tabstop | lvs_report | lvs_showselalways | lvs_nosortheader,
		ws_ex_clientedge)
	app.init_list(list)
	subclass_list(list, app)
	app.add(.compass, compass_class, '', 0, 0)
	app.add(.calibrate, 'BUTTON', app.calibrate_label(), ws_tabstop | bs_pushbutton, 0)
	app.add(.rotate_north, 'BUTTON', 'Rotate ' + rotate_glyph, ws_tabstop | bs_pushbutton,
		0)
	app.add(.clear, 'BUTTON', 'Clear list', ws_tabstop | bs_pushbutton, 0)
	app.add(.copy, 'BUTTON', 'Copy XYZ', ws_tabstop | bs_pushbutton, 0)
	app.add(.range_label, 'STATIC', 'Compass range:', 0, 0)
	app.add(.history_toggle, 'BUTTON', 'History', ws_tabstop | bs_autocheckbox, 0)
	history := app.add(.history, 'SysListView32', '', ws_tabstop | lvs_report | lvs_ownerdata | lvs_showselalways | lvs_nosortheader,
		ws_ex_clientedge)
	app.init_history_list(history)
	ranges := app.add(.compass_range, 'COMBOBOX', '', ws_tabstop | ws_vscroll | cbs_dropdownlist,
		0)
	for r in compass_ranges {
		C.SendMessageW(ranges, cb_addstring, 0, ptr_param(range_label(r).to_wide()))
	}
	C.SendMessageW(ranges, cb_setcursel, usize(compass_ranges.index(app.settings.compass_range)),
		0)
	app.add(.sound_label, 'STATIC', 'Alert:', 0, 0)
	modes := app.add(.sound_mode, 'COMBOBOX', '', ws_tabstop | ws_vscroll | cbs_dropdownlist,
		0)
	for label in ['Windows sound', 'Alert melody', 'Custom file', 'Off'] {
		C.SendMessageW(modes, cb_addstring, 0, ptr_param(label.to_wide()))
	}
	C.SendMessageW(modes, cb_setcursel, usize(int(app.settings.sound_mode)), 0)
	app.add(.sound_file, 'EDIT', app.settings.sound_file, ws_tabstop | es_autohscroll | es_readonly,
		ws_ex_clientedge)
	app.add(.browse, 'BUTTON', 'Browse...', ws_tabstop | bs_pushbutton, 0)
	app.add(.test_sound, 'BUTTON', 'Test', ws_tabstop | bs_pushbutton, 0)
	app.add(.opacity_label, 'STATIC', 'Opacity:', 0, 0)
	app.create_opacity_bar()
	app.add(.opacity_value, 'STATIC', '${app.settings.opacity}%', 0, 0)
	topmost := app.add(.topmost, 'BUTTON', 'Always on top', ws_tabstop | bs_autocheckbox,
		0)
	C.SendMessageW(topmost, bm_setcheck, usize(app.settings.topmost), 0)
	tray := app.add(.close_to_tray, 'BUTTON', 'Close to tray', ws_tabstop | bs_autocheckbox,
		0)
	C.SendMessageW(tray, bm_setcheck, usize(app.settings.close_to_tray), 0)
	app.add(.dark_mode, 'BUTTON', 'Dark mode', ws_tabstop | bs_autocheckbox, 0)
	app.add(.overlay, 'BUTTON', 'Map overlay', ws_tabstop | bs_autocheckbox, 0)
	app.add(.overlay_ui_label, 'STATIC', 'Game UI:', 0, 0)
	app.add_choices(.overlay_ui, ui_proportion_names, ui_proportion_pcts.index(app.settings.overlay_ui_pct))
	app.add(.overlay_zoom_label, 'STATIC', 'Map zoom:', 0, 0)
	app.add_choices(.overlay_zoom, overlay_zooms.map(format_units(it)), overlay_zooms.index(app.settings.overlay_zoom))
	app.add(.overlay_opacity_label, 'STATIC', 'Opacity:', 0, 0)
	app.add_choices(.overlay_opacity, overlay_opacities.map('${it} %'), overlay_opacities.index(app.settings.overlay_opacity))
	app.add(.overlay_unlock, 'BUTTON', 'Unlock', ws_tabstop | bs_pushbutton, 0)
	app.add(.overlay_reset, 'BUTTON', 'Reset', ws_tabstop | bs_pushbutton, 0)
	app.add(.overlay_xyz, 'BUTTON', 'XYZ', ws_tabstop | bs_autocheckbox, 0)
	app.add_choices(.xyz_order, []string{}, 0)
	app.update_xyz_order_choices()
	app.add(.overlay_ring, 'BUTTON', 'Ring', ws_tabstop | bs_autocheckbox, 0)
	app.add(.auto_clear_label, 'STATIC', app.auto_clear_text(), 0, 0)
	app.add(.overlay_history, 'BUTTON', 'History on map', ws_tabstop | bs_autocheckbox,
		0)
	app.create_trackbars()
	C.SendMessageW(app.ctl(.overlay_xyz), bm_setcheck, usize(app.settings.overlay_xyz),
		0)
	C.SendMessageW(app.ctl(.overlay_ring), bm_setcheck, usize(app.settings.overlay_ring),
		0)
	C.SendMessageW(app.ctl(.overlay_history), bm_setcheck, usize(app.settings.overlay_history),
		0)

	app.taskbar_created = C.RegisterWindowMessageW('TaskbarCreated'.to_wide())
	app.add_tray_icon()
	app.apply_theme()
	app.apply_opacity()
	app.apply_topmost()
	app.apply_overlay()
	app.update_sound_controls()
	app.layout()
	C.SetTimer(app.hwnd, timer_refresh, 250, unsafe { nil })
	if app.replay_path != '' {
		// Replay needs neither Npcap nor an adapter.
		app.install_visible = false
		C.EnableWindow(app.ctl(.adapter), 0)
		set_text(app.hwnd, '${app_title} - replay: ${os.file_name(app.replay_path)}${app.trial_suffix()}')
		app.layout()
		app.start_capture()
	} else {
		app.init_npcap()
	}
}

// create_opacity_bar (re)creates the slider; the trackbar caches its
// background, so a theme switch replaces it.
fn (mut app App) create_opacity_bar() {
	old := app.ctl(.opacity)
	bar := app.add(.opacity, 'msctls_trackbar32', '', ws_tabstop, 0)
	C.SendMessageW(bar, tbm_setrange, 1, makelong(20, 100))
	C.SendMessageW(bar, tbm_setpagesize, 0, 10)
	C.SendMessageW(bar, tbm_setpos, 1, isize(app.settings.opacity))
	if old != unsafe { nil } {
		C.DestroyWindow(old)
		app.layout()
	}
}

fn (mut app App) init_list(list voidptr) {
	C.SendMessageW(list, lvm_setextendedlistviewstyle, 0, lvs_ex_fullrowselect | lvs_ex_gridlines | lvs_ex_doublebuffer)
	// Order must match the col_* constants.
	columns := [
		['#', '34', 'l'],
		['Seen', '64', 'l'],
		['State', '110', 'l'],
		['Distance', '70', 'r'],
		['Height', '84', 'r'],
		['X', '76', 'r'],
		['Y', '76', 'r'],
		['Z', '64', 'r'],
	]
	for i, c in columns {
		col := LvColumn{
			mask: lvcf_fmt | lvcf_width | lvcf_text
			fmt:  if c[2] == 'r' && i > 0 { lvcfmt_right } else { lvcfmt_left }
			cx:   app.s(c[1].int())
			text: c[0].to_wide()
		}
		C.SendMessageW(list, lvm_insertcolumnw, usize(i), ptr_param(&col))
	}
}

fn (app &App) show(id Ctl, visible bool) {
	C.ShowWindow(app.ctl(id), if visible { sw_show } else { sw_hide })
}

fn (mut app App) layout() {
	mut rc := Rect{}
	C.GetClientRect(app.hwnd, &rc)
	w, h := rc.right, rc.bottom
	m := app.s(10)
	gap := app.s(6)
	row := app.s(24)
	compact := app.settings.compact
	for id in standard_only_controls {
		app.show(id, !compact)
	}
	app.show(.install_npcap, !compact && app.install_visible)
	app.show(.run_as_admin, !compact && app.admin_visible)
	if compact {
		// Compact: the compass panel draws position and status itself.
		cm := app.s(6)
		app.place(.compass, cm, cm, w - 2 * cm, h - 2 * cm - row - cm)
		app.place(.view_toggle, cm, h - cm - row, w - 2 * cm, row)
		C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
		return
	}
	label_w := app.s(60)
	btn_w := app.s(96)
	text_off := app.s(4) // vertically centre static text against controls

	mut y := m
	// The top-right slot holds whichever action button is currently needed.
	install_w := app.s(130)
	admin_w := app.s(170)
	action_w := if app.install_visible {
		install_w
	} else if app.admin_visible {
		admin_w
	} else {
		0
	}
	status_w := if action_w > 0 { w - 2 * m - action_w - gap } else { w - 2 * m }
	app.place(.status, m, y + text_off, status_w, row - text_off)
	app.place(.install_npcap, w - m - install_w, y, install_w, row + app.s(4))
	app.place(.run_as_admin, w - m - admin_w, y, admin_w, row + app.s(4))
	y += row + gap + app.s(4)

	app.place(.adapter_label, m, y + text_off, label_w, row)
	app.place(.adapter, m + label_w, y, w - 2 * m - label_w - btn_w - gap, app.s(300))
	app.place(.start_stop, w - m - btn_w, y, btn_w, row)
	y += row + gap

	redetect_w := app.s(120)
	toggle_w := app.s(110)
	app.place(.player, m, y + text_off, w - 2 * m - redetect_w - toggle_w - 2 * gap, row)
	app.place(.view_toggle, w - m - redetect_w - gap - toggle_w, y, toggle_w, row)
	app.place(.redetect, w - m - redetect_w, y, redetect_w, row)
	y += row + gap
	app.place(.nearest, m, y, w - 2 * m, row)
	y += row

	bottom_rows := 5
	list_bottom := h - m - bottom_rows * row - (bottom_rows - 1) * gap - gap
	compass_w := app.s(190)
	list_h := math.max(list_bottom - y, app.s(60))
	compass_x := w - m - compass_w
	list_y := y
	app.place(.list, m, y, compass_x - gap - m, list_h)
	north_y := y + list_h - row
	app.place(.compass, compass_x, y, compass_w, list_h - row - gap)
	rotate_w := app.s(70)
	app.place(.calibrate, compass_x, north_y, compass_w - rotate_w - gap, row)
	app.place(.rotate_north, compass_x + compass_w - rotate_w, north_y, rotate_w, row)

	mut by := h - m - bottom_rows * row - (bottom_rows - 1) * gap
	app.place(.clear, m, by, btn_w, row)
	app.place(.copy, m + btn_w + gap, by, btn_w, row)
	range_x := m + 2 * (btn_w + gap) + gap
	range_label_w := app.s(96)
	app.place(.range_label, range_x, by + text_off, range_label_w, row)
	app.place(.compass_range, range_x + range_label_w, by, app.s(100), app.s(200))
	app.place(.history_toggle, range_x + range_label_w + app.s(100) + 2 * gap, by, app.s(80),
		row)
	by += row + gap

	mode_w := app.s(130)
	small_btn := app.s(80)
	app.place(.sound_label, m, by + text_off, label_w, row)
	app.place(.sound_mode, m + label_w, by, mode_w, app.s(200))
	file_x := m + label_w + mode_w + gap
	app.place(.sound_file, file_x, by, w - m - file_x - 2 * (small_btn + gap), row)
	app.place(.browse, w - m - 2 * small_btn - gap, by, small_btn, row)
	app.place(.test_sound, w - m - small_btn, by, small_btn, row)
	by += row + gap

	bar_w := app.s(150)
	value_w := app.s(44)
	app.place(.opacity_label, m, by + text_off, label_w, row)
	app.place(.opacity, m + label_w, by, bar_w, row)
	app.place(.opacity_value, m + label_w + bar_w + gap, by + text_off, value_w, row)
	check_x := m + label_w + bar_w + gap + value_w + gap
	app.place(.topmost, check_x, by, app.s(120), row)
	app.place(.close_to_tray, check_x + app.s(120) + gap, by, app.s(120), row)
	app.place(.dark_mode, check_x + 2 * (app.s(120) + gap), by, app.s(100), row)
	by += row + gap

	mut ox := m
	for item in [[int(Ctl.overlay), 100], [int(Ctl.overlay_ui_label), 54],
		[int(Ctl.overlay_ui), 86], [int(Ctl.overlay_zoom_label), 64],
		[int(Ctl.overlay_zoom), 80], [int(Ctl.overlay_opacity_label), 52],
		[int(Ctl.overlay_opacity), 66], [int(Ctl.overlay_unlock), 70],
		[int(Ctl.overlay_reset), 60]] {
		id := unsafe { Ctl(item[0]) }
		cw := app.s(item[1])
		is_label := id in [.overlay_ui_label, .overlay_zoom_label, .overlay_opacity_label]
		is_combo := id in [.overlay_ui, .overlay_zoom, .overlay_opacity]
		app.place(id, ox, if is_label { by + text_off } else { by }, cw, if is_combo {
			app.s(200)
		} else {
			row
		})
		ox += cw + if is_label { 0 } else { gap }
	}
	by += row + gap

	ox = m
	for item in [[int(Ctl.overlay_xyz), 48], [int(Ctl.xyz_alpha), 64],
		[int(Ctl.xyz_order), 72], [int(Ctl.overlay_ring), 50],
		[int(Ctl.ring_radius), 80], [int(Ctl.auto_clear_label), 108],
		[int(Ctl.auto_clear), 96], [int(Ctl.overlay_history), 118]] {
		id := unsafe { Ctl(item[0]) }
		cw := app.s(item[1])
		app.place(id, ox, if id == .auto_clear_label { by + text_off } else { by }, cw,
			if id == .xyz_order {
			app.s(200)
		} else {
			row
		})
		ox += cw + gap
	}
	// The History list takes the cube list's place while "History" is ticked.
	app.place(.history, m, list_y, compass_x - gap - m, list_h)
	app.show(.list, !compact && !app.history_view)
	app.show(.history, !compact && app.history_view)
}

fn (app &App) place(id Ctl, x int, y int, w int, h int) {
	C.MoveWindow(app.ctl(id), x, y, math.max(w, 0), math.max(h, 0), 1)
}

// ---- Npcap and capture -------------------------------------------------------

fn (mut app App) init_npcap() {
	api := load_npcap() or {
		app.npcap = none
		app.show_npcap_missing(err.msg())
		return
	}
	app.npcap = api
	C.KillTimer(app.hwnd, timer_npcap_check)
	app.install_visible = false
	app.layout()
	access := npcap_access()
	app.update_title(access)
	if access == .admin_only && !app.elevated {
		app.show_admin_required('Npcap is restricted to administrators. Click "Run as administrator" to restart Cube Watch elevated.')
		return
	}
	app.reload_devices()
	app.start_capture()
}

// update_title shows the privilege check result, e.g.
// "Cube Watch - standard user | Npcap: all users".
fn (app &App) update_title(access NpcapAccess) {
	user := if app.elevated { 'administrator' } else { 'standard user' }
	set_text(app.hwnd, '${app_title} - ${user} | Npcap: ${access.label()}${app.trial_suffix()}')
}

fn (app &App) trial_suffix() string {
	days := app.trial.days_left()
	return ' | Trial: ${days} day${if days == 1 {
		''
	} else {
		's'
	}} left'
}

// check_trial closes the app once the trial runs out while it is open.
fn (mut app App) check_trial() {
	if app.trial_ended || app.trial.still_valid() {
		return
	}
	app.trial_ended = true
	C.KillTimer(app.hwnd, timer_refresh)
	trial_message(trial_expired_text(app.trial.expires))
	C.DestroyWindow(app.hwnd)
}

fn (mut app App) show_admin_required(message string) {
	app.set_status(message, true)
	app.admin_visible = true
	C.EnableWindow(app.ctl(.adapter), 0)
	C.EnableWindow(app.ctl(.start_stop), 0)
	app.layout()
}

fn (mut app App) run_as_admin() {
	if !restart_elevated(app.hwnd) {
		app.set_status('Administrator restart was cancelled or failed. Cube Watch keeps running without elevation.',
			true)
		return
	}
	// The elevated instance waits for this one to release the
	// single-instance mutex before it starts.
	C.DestroyWindow(app.hwnd)
}

fn (mut app App) show_npcap_missing(detail string) {
	app.set_status('Npcap is not installed. Click "Install Npcap" - detection starts automatically afterwards.',
		true)
	eprintln(detail)
	app.install_visible = true
	C.EnableWindow(app.ctl(.adapter), 0)
	C.EnableWindow(app.ctl(.start_stop), 0)
	app.layout()
	C.SetTimer(app.hwnd, timer_npcap_check, 3000, unsafe { nil })
}

fn (mut app App) reload_devices() {
	api := app.npcap or { return }
	combo := app.ctl(.adapter)
	C.SendMessageW(combo, cb_resetcontent, 0, 0)
	app.devices = api.devices() or {
		app.set_status('Cannot list network adapters: ${err}', true)
		[]Device{}
	}
	for d in app.devices {
		C.SendMessageW(combo, cb_addstring, 0, ptr_param(d.label().to_wide()))
	}
	mut index := -1
	for i, d in app.devices {
		if d.name == app.settings.adapter {
			index = i
		}
	}
	if index < 0 {
		index = preferred_device(app.devices)
	}
	if index >= 0 {
		C.SendMessageW(combo, cb_setcursel, usize(index), 0)
	}
	enabled := int(app.devices.len > 0)
	C.EnableWindow(combo, enabled)
	C.EnableWindow(app.ctl(.start_stop), enabled)
}

fn (mut app App) selected_device() ?Device {
	i := int(C.SendMessageW(app.ctl(.adapter), cb_getcursel, 0, 0))
	if i < 0 || i >= app.devices.len {
		return none
	}
	return app.devices[i]
}

fn (mut app App) start_capture() {
	if app.replay_path != '' {
		if app.capture.start_replay(app.replay_path, app.settings.port) {
			set_text(app.ctl(.start_stop), 'Stop')
		}
		return
	}
	api := app.npcap or { return }
	device := app.selected_device() or {
		app.set_status('No network adapter available. Check that Npcap is installed correctly.',
			true)
		return
	}
	if app.capture.start(api, device, app.settings.port) {
		set_text(app.ctl(.start_stop), 'Stop')
		app.set_status('Opening ${device.label()}...', false)
	}
}

fn (mut app App) on_capture_events() {
	for ev in app.capture.drain() {
		match ev.kind {
			.status {
				app.set_status(ev.text, false)
			}
			.failed {
				app.set_status(ev.text, true)
			}
			.open_failed {
				if app.elevated {
					app.set_status('${ev.text}. Running as administrator already - check that the Npcap driver is running.',
						true)
				} else {
					app.show_admin_required('${ev.text}. Npcap may require administrator rights - try "Run as administrator".')
				}
			}
			.server {
				app.set_status('Capturing. Game server detected: ${ev.text}', false)
			}
			.decoded {
				app.on_decoded(ev.ev)
			}
			.stopped {
				set_text(app.ctl(.start_stop), 'Start')
				if app.restart_pending {
					app.restart_pending = false
					app.start_capture()
				} else if !app.status_is_error && app.replay_path == '' {
					app.set_status('Capture stopped.', false)
				}
			}
		}
	}
}

fn (mut app App) on_decoded(ev proto.Event) {
	match ev.kind {
		.player_detected {
			app.player_id = ev.id
		}
		.player {
			fix := PlayerFix{ev.pos, ev.timestamp}
			app.player = fix
			app.check_calibration(fix)
		}
		.cube {
			app.on_cube(ev)
		}
		.cube_visible {
			app.update_cube(ev.id, fn [ev] (mut c CubeRow) {
				c.pos = ev.pos
				if c.state == .out_of_view {
					c.state = .available
				}
			})
		}
		.cube_opening {
			app.update_cube(ev.id, fn [ev] (mut c CubeRow) {
				c.state = .opening
				c.actor = ev.actor
			})
			if !app.is_self(ev.actor) {
				if row := app.cube_by_id(ev.id) {
					msg := 'Cube #${row.number} is being opened by another player (entity ${ev.actor})!'
					app.set_status(msg, true)
					if C.IsWindowVisible(app.hwnd) == 0 || C.IsIconic(app.hwnd) != 0 {
						app.balloon('Cube contested', msg)
					}
				}
			}
		}
		.cube_opened {
			app.update_cube(ev.id, fn [ev] (mut c CubeRow) {
				c.state = .opened
				c.actor = ev.actor
				c.mark_ended(ev.timestamp)
			})
			app.log_cube(app.cube_index(ev.id), if app.is_self(ev.actor) { 1 } else { 0 })
			if !app.is_self(ev.actor) {
				if row := app.cube_by_id(ev.id) {
					app.set_status('Cube #${row.number} was taken by another player (entity ${ev.actor}).',
						false)
				}
			}
		}
		.cube_removed {
			app.update_cube(ev.id, fn [ev] (mut c CubeRow) {
				if ev.reason == proto.removed_destroyed || c.state == .opened {
					c.state = .gone
					c.mark_ended(ev.timestamp)
				} else if c.state != .gone {
					c.state = .out_of_view
				}
			})
			if c := app.cube_by_id(ev.id) {
				if c.state == .gone {
					app.log_cube(app.cube_index(ev.id), -1) // destroyed, opener unknown
				}
			}
		}
	}
	app.dirty = true
}

fn (mut c CubeRow) mark_ended(timestamp f64) {
	if c.ended == 0 {
		c.ended = timestamp
	}
}

// prune_cubes drops cubes that were opened or vanished more than
// cube_linger_seconds ago.
fn (mut app App) prune_cubes() {
	now := now_seconds()
	mut i := app.cubes.len - 1
	for i >= 0 {
		c := app.cubes[i]
		expired := app.settings.auto_clear_minutes > 0
			&& now - c.appeared > f64(app.settings.auto_clear_minutes) * 60
		if (c.ended > 0 && now - c.ended > cube_linger_seconds) || expired {
			app.log_cube(i, -1)
			C.SendMessageW(app.ctl(.list), lvm_deleteitem, usize(i), 0)
			app.cubes.delete(i)
			app.dirty = true
		}
		i--
	}
}

// auto_redetect re-arms player detection when the position has gone stale,
// keeping the last fix on screen until a new one arrives.
fn (mut app App) auto_redetect() {
	p := app.player or { return }
	now := now_seconds()
	if now - p.timestamp < player_redetect_seconds
		|| now - app.last_redetect < player_redetect_seconds {
		return
	}
	app.last_redetect = now
	app.capture.request_player_reset()
}

// freshness_color: green / yellow / red for the age of the last position.
fn (app &App) freshness_color(age f64) u32 {
	return if age < fresh_position_seconds {
		app.theme.fresh
	} else if age < player_redetect_seconds {
		app.theme.warn
	} else {
		app.theme.error
	}
}

fn (app &App) is_self(id u64) bool {
	self_id := app.player_id or { return false }
	return self_id == id
}

fn (app &App) cube_index(id u64) int {
	for i, c in app.cubes {
		if c.id == id {
			return i
		}
	}
	return -1
}

// clear_cubes empties the cube list (e.g. a cube stuck under the ground),
// recording the cubes in the history first.
fn (mut app App) clear_cubes() {
	app.log_open_cubes()
	C.SendMessageW(app.ctl(.list), lvm_deleteallitems, 0, 0)
	app.cubes.clear()
	app.dirty = true
}

fn (app &App) cube_by_id(id u64) ?CubeRow {
	for c in app.cubes {
		if c.id == id {
			return c
		}
	}
	return none
}

fn (mut app App) update_cube(id u64, change fn (mut CubeRow)) {
	for i in 0 .. app.cubes.len {
		if app.cubes[i].id == id {
			change(mut app.cubes[i])
			c := app.cubes[i]
			app.set_cell(i, col_x, '${c.pos.x:.1f}')
			app.set_cell(i, col_y, '${c.pos.y:.1f}')
			app.set_cell(i, col_z, '${c.pos.z:.1f}')
			app.set_cell(i, col_state, app.state_text(c))
			return
		}
	}
}

fn (app &App) state_text(c CubeRow) string {
	// The full player id is shown in the status line; keep the cell short.
	who := if app.is_self(c.actor) { 'you' } else { 'other' }
	return match c.state {
		.available { 'available' }
		.out_of_view { 'out of view' }
		.opening { 'opening (${who})' }
		.opened { 'opened (${who})' }
		.gone { 'gone' }
	}
}

fn (mut app App) on_cube(ev proto.Event) {
	app.cube_count++
	seen := time.unix(i64(ev.timestamp)).local().hhmmss()
	mut row := CubeRow{
		number:   app.cube_count
		id:       ev.id
		pos:      ev.pos
		seen:     seen
		appeared: ev.timestamp
	}
	if p := app.player {
		row.first_distance = math.hypot(ev.pos.x - p.pos.x, ev.pos.y - p.pos.y)
		row.spawned = if row.first_distance < spawn_in_range_units { 1 } else { 0 }
	}
	app.cubes.insert(0, row)
	list := app.ctl(.list)
	item := LvItem{
		mask: lvif_text
		item: 0
		text: row.number.str().to_wide()
	}
	C.SendMessageW(list, lvm_insertitemw, 0, ptr_param(&item))
	app.set_cell(0, col_seen, seen)
	app.set_cell(0, col_x, '${ev.pos.x:.1f}')
	app.set_cell(0, col_y, '${ev.pos.y:.1f}')
	app.set_cell(0, col_z, '${ev.pos.z:.1f}')
	app.set_cell(0, col_state, app.state_text(row))
	app.trend_ref = none
	app.trend = 0
	app.dirty = true
	app.refresh_distances()

	play_alert(app.settings.sound_mode, app.settings.sound_file) or {
		app.set_status('Alert sound failed: ${err}', true)
	}
	if C.IsWindowVisible(app.hwnd) == 0 || C.IsIconic(app.hwnd) != 0 {
		app.balloon('Cube spawned nearby!', 'Cube at ${format_pos(ev.pos)}')
	}
}

// list_custom_draw colors each row like its compass arrow (grey once the
// cube was opened or vanished).
fn (app &App) list_custom_draw(mut cd NmLvCustomDraw) isize {
	if cd.draw_stage == cdds_prepaint {
		return cdrf_notifyitemdraw
	}
	if cd.draw_stage == cdds_itemprepaint && int(cd.item_spec) < app.cubes.len {
		cd.clr_text = app.cube_color(app.cubes[int(cd.item_spec)])
	}
	return cdrf_dodefault
}

fn (app &App) set_cell(index int, sub int, text string) {
	item := LvItem{
		mask:     lvif_text
		item:     index
		sub_item: sub
		text:     text.to_wide()
	}
	C.SendMessageW(app.ctl(.list), lvm_setitemtextw, usize(index), ptr_param(&item))
}

fn (mut app App) set_status(text string, is_error bool) {
	app.status_is_error = is_error
	app.status_text = text
	set_text(app.ctl(.status), text)
	if app.settings.compact {
		C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
	}
}

fn (app &App) compass() proto.Compass {
	return proto.Compass{
		north_deg: app.settings.north_deg
	}
}

fn height_text(dz f64) string {
	return if math.abs(dz) < trend_threshold {
		'level'
	} else {
		'${format_units(dz)} ${if dz > 0 {
			'above'
		} else {
			'below'
		}}'
	}
}

// refresh_distances updates the player line, the distance columns, the
// nearest-cube summary and the compass from the last known player position.
fn (mut app App) refresh_distances() {
	if !app.dirty {
		return
	}
	app.dirty = false
	now := now_seconds()
	app.last_refresh = now
	id_text := if id := app.player_id { ' | entity ${id}' } else { '' }
	p := app.player or {
		set_text(app.ctl(.player), 'Player: waiting for a position update from the server${id_text}')
		for i in 0 .. app.cubes.len {
			app.set_cell(i, col_distance, '-')
			app.set_cell(i, col_height, '-')
		}
		app.taken = []
		app.set_targets([], false)
		set_text(app.ctl(.nearest), if app.cubes.len == 0 {
			'No cubes detected yet.'
		} else {
			'Cube detected - waiting for your position (move, land or stop briefly).'
		})
		return
	}

	age := now - p.timestamp
	redetect := if age >= player_redetect_seconds { ' - re-detecting your character' } else { '' }
	set_text(app.ctl(.player), 'Player: (${format_pos(p.pos)}) - updated ${age:.0f}s ago${redetect}${id_text}')

	compass := app.compass()
	mut targets := []Target{}
	mut taken := []Target{}
	for i, cube in app.cubes {
		dx, dy, dz := cube.pos.x - p.pos.x, cube.pos.y - p.pos.y, cube.pos.z - p.pos.z
		planar := math.hypot(dx, dy)
		app.set_cell(i, col_distance, format_units(planar))
		app.set_cell(i, col_height, height_text(dz))
		if cube.is_target() {
			targets << Target{
				number:  cube.number
				color:   app.cube_color(cube)
				bearing: compass.bearing(dx, dy)
				planar:  planar
				dz:      dz
				contest: cube.state == .opening && !app.is_self(cube.actor)
				opening: cube.state == .opening
			}
		} else if cube.state in [.opened, .gone] && cube.ended > 0
			&& now - cube.ended < taken_marker_seconds {
			taken << Target{
				number:  cube.number
				bearing: compass.bearing(dx, dy)
				planar:  planar
				dz:      dz
			}
		}
	}
	app.taken = taken
	targets.sort(a.planar < b.planar)
	app.set_targets(targets, age > stale_position_seconds)
	if targets.len == 0 {
		set_text(app.ctl(.nearest), if app.cubes.len == 0 {
			'No cubes detected yet.'
		} else {
			'No collectable cube left in the list.'
		})
		return
	}
	t := targets[0]
	if ref := app.trend_ref {
		if now - app.trend_ref_time >= 1.0 {
			app.trend = ref - t.planar
			app.trend_ref = t.planar
			app.trend_ref_time = now
		}
	} else {
		app.trend_ref = t.planar
		app.trend_ref_time = now
	}
	mut parts := [
		'Nearest cube #${t.number}: ${proto.point_name(t.bearing)}, ${format_units(t.planar)} units',
	]
	if math.abs(app.trend) >= trend_threshold {
		parts << '${format_units(app.trend)} ${if app.trend > 0 { 'closer' } else { 'farther' }}'
	}
	if math.abs(t.dz) >= trend_threshold {
		parts << height_text(t.dz)
	}
	if targets.len > 1 {
		parts << '${targets.len - 1} more cube(s)'
	}
	set_text(app.ctl(.nearest), parts.join(' | '))
}

fn (mut app App) set_targets(targets []Target, stale bool) {
	app.targets = targets
	app.targets_stale = stale
	app.render_overlay()
	C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
	C.InvalidateRect(app.ctl(.list), unsafe { nil }, 0) // row colors follow state
}

// ---- window behaviour --------------------------------------------------------

fn (mut app App) apply_opacity() {
	app.settings.opacity = clamp(app.settings.opacity, 20, 100)
	set_text(app.ctl(.opacity_value), '${app.settings.opacity}%')
	f := proc_address('user32.dll', 'SetLayeredWindowAttributes')
	if f == unsafe { nil } {
		return
	}
	alpha := u8(app.settings.opacity * 255 / 100)
	call_setlayeredwindowattributes := FnSetLayeredWindowAttributes(f)
	_ := call_setlayeredwindowattributes(app.hwnd, 0, alpha, lwa_alpha)
}

fn (mut app App) apply_topmost() {
	insert_after := isize(if app.settings.topmost { hwnd_topmost } else { hwnd_notopmost })
	C.SetWindowPos(app.hwnd, voidptr(insert_after), 0, 0, 0, 0, swp_nomove | swp_nosize | swp_noactivate)
	C.SendMessageW(app.ctl(.topmost), bm_setcheck, usize(app.settings.topmost), 0)
}

fn (mut app App) update_sound_controls() {
	custom := int(app.settings.sound_mode == .custom)
	C.EnableWindow(app.ctl(.sound_file), custom)
	C.EnableWindow(app.ctl(.browse), custom)
	C.EnableWindow(app.ctl(.test_sound), int(app.settings.sound_mode != .off))
}

fn (app &App) view_size(compact bool) (int, int) {
	s := app.settings
	if compact {
		w := if s.compact_width > 0 { s.compact_width } else { app.s(250) }
		h := if s.compact_height > 0 { s.compact_height } else { app.s(380) }
		return w, h
	}
	w := if s.width > 0 { s.width } else { app.s(760) }
	h := if s.height > 0 { s.height } else { app.s(520) }
	return w, h
}

// set_compact switches between the full window and the compact overlay;
// each view keeps its own window size.
fn (mut app App) set_compact(compact bool) {
	if compact == app.settings.compact {
		return
	}
	app.save()
	app.settings.compact = compact
	set_text(app.ctl(.view_toggle), if compact { 'Standard view' } else { 'Compact view' })
	w, h := app.view_size(compact)
	C.SetWindowPos(app.hwnd, unsafe { nil }, 0, 0, w, h, swp_nomove | swp_nozorder | swp_noactivate)
	app.layout()
	app.save()
}

const rotate_glyph = '\u21BA' // counter-clockwise arrow

// Calibration needs a walk of at least this many world units (about one
// second of running) to measure a direction reliably.
const calibration_min_distance = 300.0

fn (app &App) calibrate_label() string {
	return if app.calibrating {
		'Cancel calibration'
	} else if app.settings.north_calibrated {
		'Re-calibrate north'
	} else {
		'Calibrate north'
	}
}

// toggle_calibration starts or cancels the minimap-north calibration: the
// user walks straight "up" on the minimap and stops; the server then
// reports the new position and the walk direction becomes north.
fn (mut app App) toggle_calibration() {
	if app.calibrating {
		app.calibrating = false
		app.set_status('Calibration cancelled.', false)
	} else {
		start := app.player or {
			app.set_status('Calibration needs your position first: move a little and stop, then click "Calibrate north" again.',
				true)
			return
		}

		app.calibrating = true
		app.calib_start = start
		app.set_status('Calibrating: walk straight UP on your minimap (north) for a few seconds, then stop.',
			false)
	}
	set_text(app.ctl(.calibrate), app.calibrate_label())
	C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
}

fn (mut app App) check_calibration(fix PlayerFix) {
	if !app.calibrating {
		return
	}
	dx := fix.pos.x - app.calib_start.pos.x
	dy := fix.pos.y - app.calib_start.pos.y
	if math.hypot(dx, dy) < calibration_min_distance {
		return
	}
	app.calibrating = false
	app.settings.north_deg = proto.north_from_walk(dx, dy)
	app.update_xyz_order_choices() // the map-order star follows north
	app.settings.north_calibrated = true
	app.trend_ref = none
	app.dirty = true
	app.set_status('North calibrated - arrows now match your minimap (north = world ${app.settings.north_deg:.0f} deg).',
		false)
	set_text(app.ctl(.calibrate), app.calibrate_label())
	app.refresh_distances()
	app.save()
}

fn (mut app App) set_dark(dark bool) {
	app.settings.theme = if dark { theme_dark } else { theme_light }
	app.apply_theme()
	app.save()
}

fn (mut app App) save() {
	if app.replay_path != '' {
		return
	}
	if C.IsIconic(app.hwnd) == 0 && C.IsWindowVisible(app.hwnd) != 0 {
		mut rc := Rect{}
		C.GetWindowRect(app.hwnd, &rc)
		app.settings.x, app.settings.y = rc.left, rc.top
		if app.settings.compact {
			app.settings.compact_width = rc.right - rc.left
			app.settings.compact_height = rc.bottom - rc.top
		} else {
			app.settings.width, app.settings.height = rc.right - rc.left, rc.bottom - rc.top
		}
	}
	save_settings(app.settings) or { eprintln('Cannot save settings: ${err}') }
}

fn (mut app App) show_window() {
	C.ShowWindow(app.hwnd, if C.IsIconic(app.hwnd) != 0 { sw_restore } else { sw_show })
	C.SetForegroundWindow(app.hwnd)
	app.dirty = true
}

fn (mut app App) hide_to_tray() {
	app.save()
	C.ShowWindow(app.hwnd, sw_hide)
	if !app.tray_hint_shown {
		app.tray_hint_shown = true
		app.balloon(app_title, 'Still watching for cubes in the background. Use the tray icon to reopen or exit.')
	}
}

fn (mut app App) tray_data() NotifyIconData {
	mut nid := NotifyIconData{
		size:         u32(sizeof(NotifyIconData))
		hwnd:         app.hwnd
		id:           tray_id
		flags:        nif_message | nif_icon | nif_tip
		callback_msg: wm_tray
		icon:         app.icon
	}
	copy_wide(&nid.tip[0], nid.tip.len, app_title)
	return nid
}

fn (mut app App) add_tray_icon() {
	f := proc_address('shell32.dll', 'Shell_NotifyIconW')
	if f == unsafe { nil } {
		return
	}
	mut nid := app.tray_data()
	call_shellnotifyicon := FnShellNotifyIcon(f)
	app.tray_added = call_shellnotifyicon(nim_add, &nid) != 0
}

fn (mut app App) remove_tray_icon() {
	f := proc_address('shell32.dll', 'Shell_NotifyIconW')
	if f == unsafe { nil } || !app.tray_added {
		return
	}
	mut nid := app.tray_data()
	call_shellnotifyicon := FnShellNotifyIcon(f)
	_ := call_shellnotifyicon(nim_delete, &nid)
	app.tray_added = false
}

fn (mut app App) balloon(title string, text string) {
	f := proc_address('shell32.dll', 'Shell_NotifyIconW')
	if f == unsafe { nil } || !app.tray_added {
		return
	}
	mut nid := app.tray_data()
	nid.flags = nif_info
	nid.info_flags = niif_info
	copy_wide(&nid.info[0], nid.info.len, text)
	copy_wide(&nid.info_title[0], nid.info_title.len, title)
	call_shellnotifyicon := FnShellNotifyIcon(f)
	_ := call_shellnotifyicon(nim_modify, &nid)
}

fn (mut app App) tray_menu() {
	menu := C.CreatePopupMenu()
	C.AppendMenuW(menu, mf_string, usize(int(TrayCmd.show)), 'Show Cube Watch'.to_wide())
	C.AppendMenuW(menu, mf_string | if app.settings.topmost { mf_checked } else { u32(0) },
		usize(int(TrayCmd.topmost)), 'Always on top'.to_wide())
	C.AppendMenuW(menu, mf_string | if app.settings.compact { mf_checked } else { u32(0) },
		usize(int(TrayCmd.compact)), 'Compact view'.to_wide())
	C.AppendMenuW(menu, mf_string, usize(int(TrayCmd.calibrate)), 'Calibrate north'.to_wide())
	C.AppendMenuW(menu, mf_string, usize(int(TrayCmd.clear_cubes)), 'Clear cubes'.to_wide())
	C.AppendMenuW(menu, mf_string | if app.settings.overlay { mf_checked } else { u32(0) },
		usize(int(TrayCmd.overlay)), 'Map overlay'.to_wide())
	if app.settings.overlay {
		C.AppendMenuW(menu, mf_string, usize(int(TrayCmd.overlay_unlock)), if app.overlay_unlocked {
			'Lock map overlay'.to_wide()
		} else {
			'Unlock map overlay (move / resize)'.to_wide()
		})
	}
	C.AppendMenuW(menu, mf_string | if app.theme.dark { mf_checked } else { u32(0) },
		usize(int(TrayCmd.dark_mode)), 'Dark mode'.to_wide())
	C.AppendMenuW(menu, mf_separator, 0, unsafe { nil })
	C.AppendMenuW(menu, mf_string, usize(int(TrayCmd.exit)), 'Exit'.to_wide())
	mut pt := Point{}
	C.GetCursorPos(&pt)
	// Required so the menu closes when the user clicks elsewhere.
	C.SetForegroundWindow(app.hwnd)
	cmd := C.TrackPopupMenu(menu, tpm_rightbutton | tpm_returncmd, pt.x, pt.y, 0, app.hwnd,
		unsafe { nil })
	C.PostMessageW(app.hwnd, wm_null, 0, 0)
	C.DestroyMenu(menu)
	match cmd {
		int(TrayCmd.show) {
			app.show_window()
		}
		int(TrayCmd.topmost) {
			app.settings.topmost = !app.settings.topmost
			app.apply_topmost()
			app.save()
		}
		int(TrayCmd.compact) {
			app.set_compact(!app.settings.compact)
			app.show_window()
		}
		int(TrayCmd.dark_mode) {
			app.set_dark(!app.theme.dark)
		}
		int(TrayCmd.calibrate) {
			app.show_window()
			app.toggle_calibration()
		}
		int(TrayCmd.clear_cubes) {
			app.clear_cubes()
		}
		int(TrayCmd.overlay) {
			app.set_overlay(!app.settings.overlay)
		}
		int(TrayCmd.overlay_unlock) {
			app.set_overlay_unlocked(!app.overlay_unlocked)
		}
		int(TrayCmd.exit) {
			C.DestroyWindow(app.hwnd)
		}
		else {}
	}
}

fn (mut app App) browse_sound() {
	f := proc_address('comdlg32.dll', 'GetOpenFileNameW')
	if f == unsafe { nil } {
		return
	}
	mut file := []u16{len: 1024}
	filter := 'Audio files (*.wav;*.mp3;*.wma)\0*.wav;*.mp3;*.wma\0All files (*.*)\0*.*\0\0'
	mut ofn := OpenFileName{
		struct_size: u32(sizeof(OpenFileName))
		owner:       app.hwnd
		filter:      filter.to_wide()
		file:        file.data
		max_file:    u32(file.len)
		title:       'Choose cube alert sound'.to_wide()
		flags:       ofn_filemustexist | ofn_pathmustexist | ofn_nochangedir
	}
	call_getopenfilename := FnGetOpenFileName(f)
	if call_getopenfilename(&ofn) == 0 {
		return
	}
	app.settings.sound_file = unsafe { string_from_wide(file.data) }
	set_text(app.ctl(.sound_file), app.settings.sound_file)
	app.save()
}

fn (mut app App) copy_selected() {
	index := int(C.SendMessageW(app.ctl(.list), lvm_getnextitem, ~usize(0), lvni_selected))
	if index < 0 || index >= app.cubes.len {
		app.set_status('Select a cube in the list to copy its coordinates.', false)
		return
	}
	text := format_pos(app.cubes[index].pos)
	wide := text.to_wide()
	bytes := usize((text.len + 1) * 2)
	if C.OpenClipboard(app.hwnd) == 0 {
		app.set_status('Clipboard is busy; try again.', true)
		return
	}
	C.EmptyClipboard()
	mem := C.GlobalAlloc(0x2, bytes) // GMEM_MOVEABLE
	if mem != unsafe { nil } {
		dst := C.GlobalLock(mem)
		unsafe { vmemcpy(dst, wide, int(bytes)) }
		C.GlobalUnlock(mem)
		if C.SetClipboardData(13, mem) == unsafe { nil } { // CF_UNICODETEXT
			C.GlobalFree(mem)
		}
	}
	C.CloseClipboard()
	app.set_status('Copied cube #${app.cubes[index].number} coordinates: ${text}', false)
}

fn (mut app App) open_npcap_download() {
	f := proc_address('shell32.dll', 'ShellExecuteW')
	if f == unsafe { nil } {
		return
	}
	call_shellexecute := FnShellExecute(f)
	_ := call_shellexecute(app.hwnd, 'open'.to_wide(), npcap_download_url.to_wide(), unsafe { nil },
		unsafe { nil }, sw_show)
}

fn (mut app App) on_command(id int, code int) {
	match id {
		int(Ctl.install_npcap) {
			app.open_npcap_download()
		}
		int(Ctl.dark_mode) {
			app.set_dark(C.SendMessageW(app.ctl(.dark_mode), bm_getcheck, 0, 0) == 1)
		}
		int(Ctl.view_toggle) {
			app.set_compact(!app.settings.compact)
		}
		int(Ctl.run_as_admin) {
			app.run_as_admin()
		}
		int(Ctl.start_stop) {
			if app.capture.is_running() {
				app.restart_pending = false
				app.capture.request_stop()
			} else {
				app.start_capture()
			}
		}
		int(Ctl.adapter) {
			if code != cbn_selchange {
				return
			}
			device := app.selected_device() or { return }
			app.settings.adapter = device.name
			app.save()
			if app.capture.is_running() {
				app.restart_pending = true
				app.capture.request_stop()
			} else {
				app.start_capture()
			}
		}
		int(Ctl.redetect) {
			app.capture.request_player_reset()
			app.player = none
			app.player_id = none
			set_text(app.ctl(.player), 'Player: re-detecting - move your character')
			app.dirty = true
		}
		int(Ctl.clear) {
			app.clear_cubes()
		}
		int(Ctl.copy) {
			app.copy_selected()
		}
		int(Ctl.sound_mode) {
			if code != cbn_selchange {
				return
			}
			sel := int(C.SendMessageW(app.ctl(.sound_mode), cb_getcursel, 0, 0))
			app.settings.sound_mode = match sel {
				1 { SoundMode.melody }
				2 { SoundMode.custom }
				3 { SoundMode.off }
				else { SoundMode.windows }
			}
			app.update_sound_controls()
			app.save()
			if app.settings.sound_mode == .custom && app.settings.sound_file == '' {
				app.browse_sound()
			}
		}
		int(Ctl.overlay) {
			app.set_overlay(C.SendMessageW(app.ctl(.overlay), bm_getcheck, 0, 0) == 1)
		}
		int(Ctl.overlay_ui), int(Ctl.overlay_zoom), int(Ctl.overlay_opacity) {
			if code == cbn_selchange {
				app.on_overlay_choice(unsafe { Ctl(id) })
			}
		}
		int(Ctl.overlay_unlock) {
			app.set_overlay_unlocked(!app.overlay_unlocked)
		}
		int(Ctl.overlay_reset) {
			app.reset_overlay_position()
		}
		int(Ctl.xyz_order) {
			if code == cbn_selchange {
				sel := int(C.SendMessageW(app.ctl(.xyz_order), cb_getcursel, 0, 0))
				if sel >= 0 && sel < xyz_orders.len {
					app.settings.xyz_order = xyz_orders[sel]
					app.save()
					app.render_overlay()
					C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
				}
			}
		}
		int(Ctl.history_toggle) {
			app.set_history_view(C.SendMessageW(app.ctl(.history_toggle), bm_getcheck,
				0, 0) == 1)
		}
		int(Ctl.overlay_xyz), int(Ctl.overlay_ring), int(Ctl.overlay_history) {
			ctl := unsafe { Ctl(id) }
			checked := C.SendMessageW(app.ctl(ctl), bm_getcheck, 0, 0) == 1
			match ctl {
				.overlay_xyz { app.settings.overlay_xyz = checked }
				.overlay_ring { app.settings.overlay_ring = checked }
				else { app.settings.overlay_history = checked }
			}
			app.save()
			app.apply_overlay()
		}
		int(Ctl.compass_range) {
			if code != cbn_selchange {
				return
			}
			sel := int(C.SendMessageW(app.ctl(.compass_range), cb_getcursel, 0, 0))
			if sel >= 0 && sel < compass_ranges.len {
				app.settings.compass_range = compass_ranges[sel]
				app.save()
				app.render_overlay()
				C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
			}
		}
		int(Ctl.calibrate) {
			app.toggle_calibration()
		}
		int(Ctl.rotate_north) {
			app.settings.north_deg = proto.normalize_deg(app.settings.north_deg + 90)
			app.update_xyz_order_choices()
			app.set_status('Compass turned a quarter turn ${rotate_glyph}. Use "Calibrate north" for an exact match with the minimap.',
				false)
			app.dirty = true
			app.refresh_distances()
			app.save()
		}
		int(Ctl.browse) {
			app.browse_sound()
		}
		int(Ctl.test_sound) {
			if app.settings.sound_mode == .custom && app.settings.sound_file == '' {
				// Nothing chosen yet: pick the file first, then play it.
				app.browse_sound()
				if app.settings.sound_file == '' {
					app.set_status('Choose a sound file for "Custom file" (Browse...).',
						false)
					return
				}
			}
			play_alert(app.settings.sound_mode, app.settings.sound_file) or {
				app.set_status('Alert sound failed: ${err}', true)
				return
			}
			app.set_status('Playing the alert sound${if app.settings.sound_mode == .custom {
				': ' + os.file_name(app.settings.sound_file)
			} else {
				''
			}}.', false)
		}
		int(Ctl.topmost) {
			app.settings.topmost = C.SendMessageW(app.ctl(.topmost), bm_getcheck, 0, 0) == 1
			app.apply_topmost()
			app.save()
		}
		int(Ctl.close_to_tray) {
			app.settings.close_to_tray = C.SendMessageW(app.ctl(.close_to_tray), bm_getcheck,
				0, 0) == 1
			app.save()
		}
		else {}
	}
}

fn (mut app App) handle(msg u32, wparam usize, lparam isize) isize {
	match msg {
		wm_capture {
			app.on_capture_events()
			return 0
		}
		wm_timer {
			if wparam == timer_refresh {
				app.check_trial()
				if app.trial_ended {
					return 0
				}
				app.prune_cubes()
				app.auto_redetect()
				app.keep_overlay_on_top()
				// Keeps the position age and the update dot in the corner live.
				C.InvalidateRect(app.ctl(.compass), unsafe { nil }, 0)
				// Position ages are shown in seconds; redraw at least once a second.
				if now_seconds() - app.last_refresh >= 1.0 {
					app.dirty = true
				}
				app.refresh_distances()
			} else if wparam == timer_npcap_check {
				if _ := load_npcap() {
					app.init_npcap()
				}
			}
			return 0
		}
		wm_command {
			app.on_command(loword(wparam), hiword(wparam))
			return 0
		}
		wm_hscroll {
			if voidptr(lparam) in [app.ctl(.xyz_alpha), app.ctl(.ring_radius),
				app.ctl(.auto_clear)] {
				app.on_overlay_slider(voidptr(lparam), loword(wparam) == 8)
				return 0
			}
			if voidptr(lparam) == app.ctl(.opacity) {
				app.settings.opacity = int(C.SendMessageW(app.ctl(.opacity), tbm_getpos,
					0, 0))
				app.apply_opacity()
				if loword(wparam) == 8 { // TB_ENDTRACK
					app.save()
				}
			}
			return 0
		}
		wm_notify {
			hdr := unsafe { &NmHdr(voidptr(lparam)) }
			if hdr.hwnd_from == app.ctl(.list) && hdr.code == nm_customdraw {
				mut cd := unsafe { &NmLvCustomDraw(voidptr(lparam)) }
				return app.list_custom_draw(mut cd)
			}
			if hdr.hwnd_from == app.ctl(.history) && hdr.code == lvn_getdispinfow {
				mut info := unsafe { &NmLvDispInfo(voidptr(lparam)) }
				app.history_dispinfo(mut info)
				return 0
			}
		}
		wm_ctlcolorstatic, wm_ctlcoloredit, wm_ctlcolorlistbox, wm_ctlcolorbtn {
			return app.on_ctl_color(msg, voidptr(wparam), voidptr(lparam))
		}
		wm_erasebkgnd {
			mut rc := Rect{}
			C.GetClientRect(app.hwnd, &rc)
			C.FillRect(voidptr(wparam), &rc, app.bg_brush)
			return 1
		}
		wm_settingchange {
			// Follow the Windows light/dark switch when the theme is "system".
			if app.settings.theme == theme_system && lparam != 0
				&& unsafe { string_from_wide(&u16(voidptr(lparam))) } == 'ImmersiveColorSet' {
				app.apply_theme()
			}
		}
		wm_size {
			app.layout()
			return 0
		}
		wm_getminmaxinfo {
			mut info := unsafe { &MinMaxInfo(voidptr(lparam)) }
			info.min_track = if app.settings.compact {
				Point{app.s(180), app.s(230)}
			} else {
				Point{app.s(640), app.s(430)}
			}
			return 0
		}
		wm_tray {
			match u32(loword(usize(lparam))) {
				wm_lbuttonup, wm_lbuttondblclk, nin_balloonuserclick {
					if C.IsWindowVisible(app.hwnd) != 0 && C.IsIconic(app.hwnd) == 0 {
						app.hide_to_tray()
					} else {
						app.show_window()
					}
				}
				wm_rbuttonup {
					app.tray_menu()
				}
				else {}
			}
			return 0
		}
		wm_show_instance {
			app.show_window()
			return 0
		}
		wm_exitsizemove {
			// Keep the window position even if the app is killed later.
			app.save()
			return 0
		}
		wm_endsession {
			// Windows logoff / shutdown ends the process without WM_DESTROY.
			if wparam != 0 {
				app.save()
			}
			return 0
		}
		wm_close {
			if app.settings.close_to_tray && app.tray_added {
				app.hide_to_tray()
			} else {
				C.DestroyWindow(app.hwnd)
			}
			return 0
		}
		wm_destroy {
			app.log_open_cubes()
			if app.overlay_hwnd != unsafe { nil } {
				C.DestroyWindow(app.overlay_hwnd)
			}
			app.save()
			app.capture.request_stop()
			app.remove_tray_icon()
			C.PostQuitMessage(0)
			return 0
		}
		else {
			if msg == app.taskbar_created && msg != 0 {
				// Explorer restarted; the tray icon has to be added again.
				app.tray_added = false
				app.add_tray_icon()
				return 0
			}
		}
	}
	return C.DefWindowProcW(app.hwnd, msg, wparam, lparam)
}

fn wnd_proc(hwnd voidptr, msg u32, wparam usize, lparam isize) isize {
	if msg == wm_create {
		cs := unsafe { &CreateStruct(voidptr(lparam)) }
		C.SetWindowLongPtrW(hwnd, gwlp_userdata, isize(cs.create_params))
		mut app := unsafe { &App(cs.create_params) }
		app.hwnd = hwnd
		app.on_create()
		return 0
	}
	ptr := C.GetWindowLongPtrW(hwnd, gwlp_userdata)
	if ptr == 0 {
		return C.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	mut app := unsafe { &App(voidptr(ptr)) }
	return app.handle(msg, wparam, lparam)
}

// ---- startup -------------------------------------------------------------

// enable_visual_styles activates Common Controls v6 through a generated
// manifest, since the tcc-built executable has no embedded resources.
fn enable_visual_styles() {
	create := proc_address('kernel32.dll', 'CreateActCtxW')
	activate := proc_address('kernel32.dll', 'ActivateActCtx')
	if create == unsafe { nil } || activate == unsafe { nil } {
		return
	}
	manifest := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <dependency><dependentAssembly>
    <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
  </dependentAssembly></dependency>
</assembly>
'
	path := os.join_path(settings_dir(), 'visual-styles.manifest')
	os.mkdir_all(settings_dir()) or { return }
	if os.read_file(path) or { '' } != manifest {
		os.write_file(path, manifest) or { return }
	}
	ctx := ActCtx{
		size:   u32(sizeof(ActCtx))
		source: path.to_wide()
	}
	call_createactctx := FnCreateActCtx(create)
	handle := call_createactctx(&ctx)
	if isize(handle) == -1 {
		return
	}
	mut cookie := usize(0)
	call_activateactctx := FnActivateActCtx(activate)
	_ := call_activateactctx(handle, &cookie)
}

fn init_common_controls() {
	f := proc_address('comctl32.dll', 'InitCommonControlsEx')
	if f == unsafe { nil } {
		return
	}
	icc := InitCommonControlsEx{
		size: u32(sizeof(InitCommonControlsEx))
		icc:  icc_listview_classes | icc_bar_classes
	}
	call_initcommoncontrolsex := FnInitCommonControlsEx(f)
	_ := call_initcommoncontrolsex(&icc)
}

// bold_ui_font highlights the nearest cube in the compass legend.
fn bold_ui_font() voidptr {
	mut ncm := NonClientMetrics{
		size: u32(sizeof(NonClientMetrics))
	}
	if C.SystemParametersInfoW(spi_getnonclientmetrics, ncm.size, &ncm, 0) == 0 {
		return unsafe { nil }
	}
	mut lf := ncm.message_font
	lf.weight = 700
	lf.quality = cleartype_quality
	return C.CreateFontIndirectW(&lf)
}

fn ui_font() voidptr {
	mut ncm := NonClientMetrics{
		size: u32(sizeof(NonClientMetrics))
	}
	if C.SystemParametersInfoW(spi_getnonclientmetrics, ncm.size, &ncm, 0) == 0 {
		return unsafe { nil }
	}
	mut lf := ncm.message_font
	lf.quality = cleartype_quality
	return C.CreateFontIndirectW(&lf)
}

// on_screen reports whether a saved window position is still visible on
// the current monitor layout.
fn on_screen(x int, y int) bool {
	vx, vy := C.GetSystemMetrics(76), C.GetSystemMetrics(77)
	vw, vh := C.GetSystemMetrics(78), C.GetSystemMetrics(79)
	return x >= vx - 50 && y >= vy - 10 && x < vx + vw - 100 && y < vy + vh - 50
}

fn run_app(start_hidden bool, replay_path string) int {
	trial := start_trial() or { return 1 }
	dpi_aware := proc_address('user32.dll', 'SetProcessDPIAware')
	if dpi_aware != unsafe { nil } {
		call_setprocessdpiaware := FnSetProcessDpiAware(dpi_aware)
		_ := call_setprocessdpiaware()
	}
	enable_visual_styles()
	init_common_controls()

	mut app := &App{
		instance:     C.GetModuleHandleW(unsafe { nil })
		settings:     load_settings()
		start_hidden: start_hidden
		replay_path:  replay_path
		trial:        trial
		history:      load_history()
		gdip:         load_gdip()
		theme:        light_theme
		elevated:     is_elevated()
	}
	app.history_spots = group_history(app.history)
	screen := C.GetDC(unsafe { nil })
	app.dpi = C.GetDeviceCaps(screen, logpixelsy)
	C.ReleaseDC(unsafe { nil }, screen)
	app.font = ui_font()
	app.bold_font = bold_ui_font()
	register_compass_class(app.instance)
	register_overlay_class(app.instance)
	app.icon = make_cube_icon()

	cls := WndClassEx{
		size:       u32(sizeof(WndClassEx))
		wnd_proc:   voidptr(wnd_proc)
		instance:   app.instance
		icon:       app.icon
		icon_small: app.icon
		cursor:     C.LoadCursorW(unsafe { nil }, idc_arrow)
		background: C.GetSysColorBrush(color_btnface)
		class_name: window_class.to_wide()
	}
	if C.RegisterClassExW(&cls) == 0 {
		C.MessageBoxW(unsafe { nil }, 'Cannot register the main window class.'.to_wide(),
			app_title.to_wide(), mb_iconerror)
		return 1
	}
	s := app.settings
	mut x, mut y := cw_usedefault, cw_usedefault
	if s.x >= 0 && on_screen(s.x, s.y) {
		x, y = s.x, s.y
	}
	w, h := app.view_size(s.compact)
	// SetWindowPos(HWND_TOPMOST) does not stick while WM_CREATE is running,
	// so the saved preference is applied through the creation style.
	ex_style := ws_ex_layered | if s.topmost { ws_ex_topmost } else { u32(0) }
	hwnd := C.CreateWindowExW(ex_style, window_class.to_wide(), app_title.to_wide(), ws_overlappedwindow | ws_clipchildren,
		x, y, w, h, unsafe { nil }, unsafe { nil }, app.instance, voidptr(app))
	if hwnd == unsafe { nil } {
		C.MessageBoxW(unsafe { nil }, 'Cannot create the main window.'.to_wide(), app_title.to_wide(),
			mb_iconerror)
		return 1
	}
	if !start_hidden {
		C.ShowWindow(hwnd, sw_show)
	}
	mut msg := Msg{}
	for C.GetMessageW(&msg, unsafe { nil }, 0, 0) > 0 {
		if C.IsDialogMessageW(hwnd, &msg) != 0 {
			continue
		}
		C.TranslateMessage(&msg)
		C.DispatchMessageW(&msg)
	}
	return int(msg.wparam)
}
