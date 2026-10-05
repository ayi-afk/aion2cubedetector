module main

// Light / dark color themes. Dark mode uses the documented DWM title bar
// attribute, the Windows 10 "DarkMode_*" control themes, and our own colors
// for everything drawn through WM_CTLCOLOR* and the compass.

// Colors are COLORREF values (0x00BBGGRR).
struct Theme {
	dark       bool
	bg         u32 // window and panel background
	field      u32 // edit / combo / list background
	text       u32
	dim        u32 // secondary text
	error      u32
	warn       u32 // yellow: old position kept while re-detecting
	fresh      u32 // green: position just updated
	contested  u32
	dial_face  u32
	dial_edge  u32
	ended      u32 // opened / vanished cubes
	cube_color []u32
}

const light_theme = Theme{
	dark:       false
	bg:         0x00F0F0F0
	field:      0x00FFFFFF
	text:       0x00000000
	dim:        0x00606060
	error:      0x002020C0
	warn:       0x000090B8
	fresh:      0x00209020
	contested:  0x00007FE0
	dial_face:  0x00FFFFFF
	dial_edge:  0x00909090
	ended:      0x00909090
	cube_color: [u32(0x003C9E2E), 0x00DC6E1E, 0x00AA32BE, 0x001478D2, 0x00A09600, 0x002828C8,
		0x00C84696, 0x00008282]
}

// Brighter cube colors so they stay readable on the dark background.
const dark_theme = Theme{
	dark:       true
	bg:         0x00202020
	field:      0x002B2B2B
	text:       0x00E8E8E8
	dim:        0x00A8A8A8
	error:      0x006A6AFF
	warn:       0x0030D0F0
	fresh:      0x0040C040
	contested:  0x0040A8FF
	dial_face:  0x00303030
	dial_edge:  0x00707070
	ended:      0x00707070
	cube_color: [u32(0x0064D25A), 0x00FFA05A, 0x00DC6EE6, 0x003CA0FF, 0x00D2D23C, 0x006464FF,
		0x00FF8CB4, 0x0050C8C8]
}

const theme_system = 'system'
const theme_light = 'light'
const theme_dark = 'dark'

const wm_ctlcoloredit = u32(0x0133)
const wm_ctlcolorlistbox = u32(0x0134)
const wm_ctlcolorbtn = u32(0x0135)
const wm_settingchange = u32(0x001A)
const wm_ncactivate = u32(0x0086)
const lvm_setbkcolor = lvm_first + 1
const lvm_settextcolor = lvm_first + 36
const lvm_settextbkcolor = lvm_first + 38
const lvm_getheader = lvm_first + 31
const dwmwa_use_immersive_dark_mode = u32(20)
const dwmwa_use_immersive_dark_mode_old = u32(19) // Windows 10 before 20H1
const rdw_invalidate = u32(0x0001)
const rdw_erase = u32(0x0004)
const rdw_allchildren = u32(0x0080)
const rdw_frame = u32(0x0400)

fn C.RedrawWindow(hwnd voidptr, rect voidptr, region voidptr, flags u32) int
fn C.GetActiveWindow() voidptr

type FnSetWindowTheme = fn (voidptr, voidptr, voidptr) i32

type FnDwmSetWindowAttribute = fn (voidptr, u32, voidptr, u32) i32

type FnSetPreferredAppMode = fn (int) int

type FnFlushMenuThemes = fn ()

// system_prefers_dark reads the Windows "app mode" setting.
fn system_prefers_dark() bool {
	f := proc_address('advapi32.dll', 'RegGetValueW')
	if f == unsafe { nil } {
		return false
	}
	reg_get_value := FnRegGetValue(f)
	mut value := u32(1)
	mut size := u32(sizeof(u32))
	rc := reg_get_value(voidptr(usize(0x80000001)), 'Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'.to_wide(),
		'AppsUseLightTheme'.to_wide(), rrf_rt_reg_dword, unsafe { nil }, &value, &size)
	return rc == 0 && value == 0
}

fn theme_for(setting string) Theme {
	dark := match setting {
		theme_dark { true }
		theme_light { false }
		else { system_prefers_dark() }
	}
	return if dark { dark_theme } else { light_theme }
}

// proc_ordinal resolves an export that has no name (undocumented uxtheme
// entry points used by Windows itself for dark context menus).
fn proc_ordinal(dll string, ordinal u16) voidptr {
	h := C.LoadLibraryW(dll.to_wide())
	if h == unsafe { nil } {
		return unsafe { nil }
	}
	return C.GetProcAddress(h, &u8(voidptr(usize(ordinal))))
}

// set_app_dark_menus switches popup menus (tray menu) between dark and
// light. Missing on older Windows builds, in which case menus stay light.
fn set_app_dark_menus(dark bool) {
	set_mode := proc_ordinal('uxtheme.dll', 135)
	flush := proc_ordinal('uxtheme.dll', 136)
	if set_mode == unsafe { nil } || flush == unsafe { nil } {
		return
	}
	set_preferred_app_mode := FnSetPreferredAppMode(set_mode)
	flush_menu_themes := FnFlushMenuThemes(flush)
	set_preferred_app_mode(if dark { 2 } else { 3 }) // ForceDark / ForceLight
	flush_menu_themes()
}

fn set_window_theme(hwnd voidptr, name string) {
	f := proc_address('uxtheme.dll', 'SetWindowTheme')
	if f == unsafe { nil } {
		return
	}
	set_theme := FnSetWindowTheme(f)
	if name == '' {
		set_theme(hwnd, unsafe { nil }, unsafe { nil }) // back to the default theme
	} else if name == '-' {
		// No visual style: classic checkboxes honour WM_CTLCOLORSTATIC text color.
		empty := ''.to_wide()
		set_theme(hwnd, empty, empty)
	} else {
		set_theme(hwnd, name.to_wide(), unsafe { nil })
	}
}

fn set_dark_title_bar(hwnd voidptr, dark bool) {
	f := proc_address('dwmapi.dll', 'DwmSetWindowAttribute')
	if f == unsafe { nil } {
		return
	}
	set_attribute := FnDwmSetWindowAttribute(f)
	mut value := int(dark)
	if set_attribute(hwnd, dwmwa_use_immersive_dark_mode, &value, 4) != 0 {
		set_attribute(hwnd, dwmwa_use_immersive_dark_mode_old, &value, 4)
	}
}

// Controls grouped by how they are themed.
const themed_push_buttons = [Ctl.install_npcap, .run_as_admin, .start_stop, .redetect, .view_toggle,
	.clear, .copy, .browse, .test_sound, .calibrate, .rotate_north, .overlay_unlock, .overlay_reset]
const themed_checkboxes = [Ctl.topmost, .close_to_tray, .dark_mode, .overlay, .history_toggle,
	.overlay_xyz, .overlay_ring, .overlay_history]
const themed_fields = [Ctl.adapter, .sound_mode, .sound_file, .compass_range, .overlay_ui,
	.overlay_zoom, .overlay_opacity]

// apply_theme recolors every control for the current theme setting.
fn (mut app App) apply_theme() {
	app.theme = theme_for(app.settings.theme)
	dark := app.theme.dark
	if app.bg_brush != unsafe { nil } {
		C.DeleteObject(app.bg_brush)
		C.DeleteObject(app.field_brush)
	}
	app.bg_brush = C.CreateSolidBrush(app.theme.bg)
	app.field_brush = C.CreateSolidBrush(app.theme.field)

	set_app_dark_menus(dark)
	set_dark_title_bar(app.hwnd, dark)
	for id in themed_push_buttons {
		set_window_theme(app.ctl(id), if dark { 'DarkMode_Explorer' } else { '' })
	}
	for id in themed_checkboxes {
		set_window_theme(app.ctl(id), if dark { '-' } else { '' })
	}
	for id in themed_fields {
		set_window_theme(app.ctl(id), if dark { 'DarkMode_CFD' } else { '' })
	}
	for list in [app.ctl(.list), app.ctl(.history)] {
		set_window_theme(list, if dark { 'DarkMode_Explorer' } else { '' })
		header := voidptr(C.SendMessageW(list, lvm_getheader, 0, 0))
		set_window_theme(header, if dark { 'DarkMode_ItemsView' } else { '' })
		C.SendMessageW(list, lvm_setbkcolor, 0, isize(app.theme.field))
		C.SendMessageW(list, lvm_settextbkcolor, 0, isize(app.theme.field))
		C.SendMessageW(list, lvm_settextcolor, 0, isize(app.theme.text))
		// Light grid lines look harsh on the dark list.
		C.SendMessageW(list, lvm_setextendedlistviewstyle, usize(lvs_ex_gridlines), if dark {
			isize(0)
		} else {
			lvs_ex_gridlines
		})
	}
	C.SendMessageW(app.ctl(.dark_mode), bm_setcheck, usize(dark), 0)
	app.render_overlay() // contested color follows the theme
	if app.ctl(.opacity) != unsafe { nil } {
		app.create_opacity_bar()
		app.create_trackbars()
	}

	C.RedrawWindow(app.hwnd, unsafe { nil }, unsafe { nil }, rdw_invalidate | rdw_erase | rdw_allchildren | rdw_frame)
	// Windows 10 repaints the title bar color only on (de)activation.
	if C.GetActiveWindow() == app.hwnd {
		C.SendMessageW(app.hwnd, wm_ncactivate, 0, 0)
		C.SendMessageW(app.hwnd, wm_ncactivate, 1, 0)
	}
}

type FnSetWindowSubclass = fn (voidptr, voidptr, usize, usize) int

type FnDefSubclassProc = fn (voidptr, u32, usize, isize) isize

// subclass_list hooks the list view so it can recolor its header text,
// which the dark header theme draws too dark.
fn subclass_list(list voidptr, app &App) {
	f := proc_address('comctl32.dll', 'SetWindowSubclass')
	if f == unsafe { nil } {
		return
	}
	set_subclass := FnSetWindowSubclass(f)
	set_subclass(list, voidptr(list_subclass_proc), 1, usize(voidptr(app)))
}

fn list_subclass_proc(hwnd voidptr, msg u32, wparam usize, lparam isize, id usize, data usize) isize {
	if msg == wm_notify && data != 0 {
		app := unsafe { &App(voidptr(data)) }
		hdr := unsafe { &NmHdr(voidptr(lparam)) }
		if app.theme.dark && hdr.code == nm_customdraw {
			cd := unsafe { &NmLvCustomDraw(voidptr(lparam)) }
			if cd.draw_stage == cdds_prepaint {
				return cdrf_notifyitemdraw
			}
			if cd.draw_stage == cdds_itemprepaint {
				C.SetTextColor(cd.hdc, app.theme.text)
				return cdrf_dodefault
			}
		}
	}
	f := proc_address('comctl32.dll', 'DefSubclassProc')
	def_subclass := FnDefSubclassProc(f)
	return def_subclass(hwnd, msg, wparam, lparam)
}

fn (app &App) cube_color(c CubeRow) u32 {
	return if c.is_target() {
		app.theme.cube_color[(c.number - 1) % app.theme.cube_color.len]
	} else {
		app.theme.ended
	}
}

// on_ctl_color colors labels, checkboxes, edits and combo lists.
fn (app &App) on_ctl_color(msg u32, hdc voidptr, hwnd voidptr) isize {
	t := app.theme
	is_field := msg == wm_ctlcoloredit || msg == wm_ctlcolorlistbox || hwnd == app.ctl(.sound_file)
	if hwnd == app.ctl(.status) && app.status_is_error {
		C.SetTextColor(hdc, t.error)
	} else {
		C.SetTextColor(hdc, t.text)
	}
	if is_field {
		C.SetBkColor(hdc, t.field)
		return isize(app.field_brush)
	}
	C.SetBkMode(hdc, 1) // TRANSPARENT
	C.SetBkColor(hdc, t.bg)
	return isize(app.bg_brush)
}
