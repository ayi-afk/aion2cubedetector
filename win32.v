module main

// Minimal Win32 bindings. Functions missing from the import libraries that
// ship with V's bundled tcc (comctl32, shell32, winmm, comdlg32 and some newer
// user32/kernel32 exports) are resolved at runtime with GetProcAddress, so the
// app builds with the default V toolchain and no extra SDK.

#flag windows -luser32
#flag windows -lgdi32

fn C.GetModuleHandleW(name &u16) voidptr
fn C.LoadLibraryW(name &u16) voidptr
fn C.LoadLibraryExW(name &u16, file voidptr, flags u32) voidptr
fn C.GetProcAddress(handle voidptr, procname &u8) voidptr
fn C.GetSystemDirectoryW(buf &u16, size u32) u32
fn C.GetLastError() u32
fn C.CreateMutexW(attrs voidptr, owner int, name &u16) voidptr
fn C.WaitForSingleObject(handle voidptr, ms u32) u32
fn C.Beep(freq u32, duration u32) int

fn C.RegisterClassExW(cls voidptr) u16
fn C.CreateWindowExW(ex_style u32, cls &u16, name &u16, style u32, x int, y int, w int, h int, parent voidptr, menu voidptr, inst voidptr, param voidptr) voidptr
fn C.DefWindowProcW(hwnd voidptr, msg u32, wparam usize, lparam isize) isize
fn C.GetMessageW(msg voidptr, hwnd voidptr, min u32, max u32) int
fn C.TranslateMessage(msg voidptr) int
fn C.DispatchMessageW(msg voidptr) isize
fn C.IsDialogMessageW(hwnd voidptr, msg voidptr) int
fn C.PostMessageW(hwnd voidptr, msg u32, wparam usize, lparam isize) int
fn C.SendMessageW(hwnd voidptr, msg u32, wparam usize, lparam isize) isize
fn C.PostQuitMessage(code int)
fn C.ShowWindow(hwnd voidptr, cmd int) int
fn C.IsWindowVisible(hwnd voidptr) int
fn C.IsIconic(hwnd voidptr) int
fn C.SetForegroundWindow(hwnd voidptr) int
fn C.DestroyWindow(hwnd voidptr) int
fn C.MoveWindow(hwnd voidptr, x int, y int, w int, h int, repaint int) int
fn C.SetWindowPos(hwnd voidptr, after voidptr, x int, y int, w int, h int, flags u32) int
fn C.GetClientRect(hwnd voidptr, rect voidptr) int
fn C.GetWindowRect(hwnd voidptr, rect voidptr) int
fn C.SetWindowTextW(hwnd voidptr, text &u16) int
fn C.GetWindowTextW(hwnd voidptr, buf &u16, max int) int
fn C.EnableWindow(hwnd voidptr, enable int) int
fn C.GetDlgItem(hwnd voidptr, id int) voidptr
fn C.SetWindowLongPtrW(hwnd voidptr, index int, value isize) isize
fn C.GetWindowLongPtrW(hwnd voidptr, index int) isize
fn C.FindWindowW(cls &u16, name &u16) voidptr
fn C.SetTimer(hwnd voidptr, id usize, ms u32, proc voidptr) usize
fn C.KillTimer(hwnd voidptr, id usize) int
fn C.LoadIconW(inst voidptr, name voidptr) voidptr
fn C.LoadCursorW(inst voidptr, name voidptr) voidptr
fn C.DestroyIcon(icon voidptr) int
fn C.CreateIconIndirect(info voidptr) voidptr
fn C.GetSysColorBrush(index int) voidptr
fn C.MessageBeep(kind u32) int
fn C.MessageBoxW(hwnd voidptr, text &u16, caption &u16, kind u32) int
fn C.CreatePopupMenu() voidptr
fn C.AppendMenuW(menu voidptr, flags u32, id usize, text &u16) int
fn C.TrackPopupMenu(menu voidptr, flags u32, x int, y int, reserved int, hwnd voidptr, rect voidptr) int
fn C.DestroyMenu(menu voidptr) int
fn C.GetCursorPos(point voidptr) int
fn C.RegisterWindowMessageW(name &u16) u32
fn C.GetDC(hwnd voidptr) voidptr
fn C.ReleaseDC(hwnd voidptr, dc voidptr) int
fn C.FlashWindowEx(info voidptr) int
fn C.SystemParametersInfoW(action u32, param u32, pv voidptr, win_ini u32) int

fn C.GetDeviceCaps(dc voidptr, index int) int
fn C.CreateFontIndirectW(font voidptr) voidptr
fn C.DeleteObject(obj voidptr) int
fn C.CreateCompatibleDC(dc voidptr) voidptr
fn C.DeleteDC(dc voidptr) int
fn C.CreateBitmap(w int, h int, planes u32, bpp u32, bits voidptr) voidptr
fn C.CreateDIBSection(dc voidptr, info voidptr, usage u32, bits voidptr, section voidptr, offset u32) voidptr
fn C.SetTextColor(dc voidptr, color u32) u32
fn C.BeginPaint(hwnd voidptr, ps voidptr) voidptr
fn C.EndPaint(hwnd voidptr, ps voidptr) int
fn C.InvalidateRect(hwnd voidptr, rect voidptr, erase int) int
fn C.FillRect(dc voidptr, rect voidptr, brush voidptr) int
fn C.Ellipse(dc voidptr, left int, top int, right int, bottom int) int
fn C.Polygon(dc voidptr, points voidptr, count int) int
fn C.CreatePen(style int, width int, color u32) voidptr
fn C.CreateSolidBrush(color u32) voidptr
fn C.SelectObject(dc voidptr, obj voidptr) voidptr
fn C.DrawTextW(dc voidptr, text &u16, count int, rect voidptr, format u32) int
fn C.CreateCompatibleBitmap(dc voidptr, w int, h int) voidptr
fn C.BitBlt(dst voidptr, x int, y int, w int, h int, src voidptr, sx int, sy int, rop u32) int
fn C.GetParent(hwnd voidptr) voidptr
fn C.SetBkMode(dc voidptr, mode int) int
fn C.SetBkColor(dc voidptr, color u32) u32
fn C.GetSystemMetrics(index int) int
fn C.OpenClipboard(hwnd voidptr) int
fn C.EmptyClipboard() int
fn C.SetClipboardData(format u32, mem voidptr) voidptr
fn C.CloseClipboard() int
fn C.GlobalAlloc(flags u32, size usize) voidptr
fn C.GlobalLock(mem voidptr) voidptr
fn C.GlobalUnlock(mem voidptr) int
fn C.GlobalFree(mem voidptr) voidptr

const wm_create = u32(0x0001)
const wm_destroy = u32(0x0002)
const wm_paint = u32(0x000F)
const wm_erasebkgnd = u32(0x0014)
const wm_size = u32(0x0005)
const wm_close = u32(0x0010)
const wm_endsession = u32(0x0016)
const wm_exitsizemove = u32(0x0232)
const wm_null = u32(0x0000)
const wm_setfont = u32(0x0030)
const wm_getminmaxinfo = u32(0x0024)
const wm_command = u32(0x0111)
const wm_notify = u32(0x004E)
const wm_timer = u32(0x0113)
const wm_hscroll = u32(0x0114)
const wm_ctlcolorstatic = u32(0x0138)
const wm_lbuttonup = u32(0x0202)
const wm_lbuttondblclk = u32(0x0203)
const wm_rbuttonup = u32(0x0205)
const wm_user = u32(0x0400)
const wm_app = u32(0x8000)

const ws_overlappedwindow = u32(0x00CF0000)
const ws_child = u32(0x40000000)
const ws_visible = u32(0x10000000)
const ws_tabstop = u32(0x00010000)
const ws_vscroll = u32(0x00200000)
const ws_clipchildren = u32(0x02000000)
const ws_ex_layered = u32(0x00080000)
const ws_ex_topmost = u32(0x00000008)
const ws_ex_clientedge = u32(0x00000200)

const bs_pushbutton = u32(0)
const bs_autocheckbox = u32(3)
const bm_getcheck = u32(0x00F0)
const bm_setcheck = u32(0x00F1)
const bm_setimage = u32(0x00F7)
const bn_clicked = 0
const ss_endellipsis = u32(0x4000)
const es_autohscroll = u32(0x0080)
const es_readonly = u32(0x0800)
const cbs_dropdownlist = u32(0x0003)
const cb_addstring = u32(0x0143)
const cb_getcursel = u32(0x0147)
const cb_resetcontent = u32(0x014B)
const cb_setcursel = u32(0x014E)
const cbn_selchange = 1

const sw_hide = 0
const sw_show = 5
const sw_restore = 9
const swp_nosize = u32(0x0001)
const swp_nomove = u32(0x0002)
const swp_noactivate = u32(0x0010)
const hwnd_topmost = -1
const hwnd_notopmost = -2
const gwlp_userdata = -21
const lwa_alpha = u32(0x2)
const cw_usedefault = int(u32(0x80000000))

const idi_application = voidptr(usize(32512))
const idi_warning = voidptr(usize(32515))
const idi_shield = voidptr(usize(32518))
const idc_arrow = voidptr(usize(32512))
const image_icon = usize(1)
const color_btnface = 15
const mb_iconexclamation = u32(0x30)
const mb_iconerror = u32(0x10)
const mf_string = u32(0)
const mf_checked = u32(0x8)
const mf_separator = u32(0x800)
const tpm_rightbutton = u32(0x0002)
const tpm_returncmd = u32(0x0100)
const error_already_exists = u32(183)
const load_with_altered_search_path = u32(0x8)
const spi_getnonclientmetrics = u32(0x0029)
const logpixelsy = 90

// comctl32
const icc_listview_classes = u32(0x1)
const icc_bar_classes = u32(0x4)
const tbm_getpos = wm_user
const tbm_setpos = wm_user + 5
const tbm_setrange = wm_user + 6
const tbm_setpagesize = wm_user + 21
const lvm_first = u32(0x1000)
const lvm_getitemcount = lvm_first + 4
const lvm_setitemcount = lvm_first + 47
const lvs_ownerdata = u32(0x1000)
const lvn_getdispinfow = -177
const lvm_deleteitem = lvm_first + 8
const lvm_deleteallitems = lvm_first + 9
const lvm_setextendedlistviewstyle = lvm_first + 54
const lvm_insertitemw = lvm_first + 77
const lvm_insertcolumnw = lvm_first + 97
const lvm_setitemtextw = lvm_first + 116
const lvm_getnextitem = lvm_first + 12
const lvs_report = u32(0x0001)
const lvs_showselalways = u32(0x0008)
const lvs_nosortheader = u32(0x8000)
const lvs_ex_gridlines = isize(0x1)
const lvs_ex_fullrowselect = isize(0x20)
const lvs_ex_doublebuffer = isize(0x10000)
const lvcf_fmt = u32(0x1)
const lvcf_width = u32(0x2)
const lvcf_text = u32(0x4)
const lvcfmt_left = 0
const lvcfmt_right = 1
const lvif_text = u32(0x1)
const lvni_selected = isize(0x2)

// shell32
const nim_add = u32(0)
const nim_modify = u32(1)
const nim_delete = u32(2)
const nif_message = u32(0x1)
const nif_icon = u32(0x2)
const nif_tip = u32(0x4)
const nif_info = u32(0x10)
const niif_info = u32(0x1)
const nin_balloonuserclick = wm_user + 5

// winmm
const snd_async = u32(0x0001)
const snd_nodefault = u32(0x0002)
const snd_alias = u32(0x00010000)
const snd_filename = u32(0x00020000)

// comdlg32
const ofn_filemustexist = u32(0x1000)
const ofn_pathmustexist = u32(0x0800)
const ofn_nochangedir = u32(0x0008)

struct Rect {
mut:
	left   int
	top    int
	right  int
	bottom int
}

struct Point {
	x int
	y int
}

struct PaintStruct {
	hdc      voidptr
	erase    int
	paint    Rect
	restore  int
	inc      int
	reserved [32]u8
}

const dt_left = u32(0x0)
const dt_center = u32(0x1)
const dt_vcenter = u32(0x4)
const dt_singleline = u32(0x20)
const dt_end_ellipsis = u32(0x8000)
const srccopy = u32(0x00CC0020)

struct NmHdr {
	hwnd_from voidptr
	id_from   usize
	code      int
}

// NMLVCUSTOMDRAW, used to color list rows.
struct NmLvCustomDraw {
	hdr         NmHdr
	draw_stage  u32
	hdc         voidptr
	rc          Rect
	item_spec   usize
	item_state  u32
	item_lparam isize
mut:
	clr_text    u32
	clr_text_bk u32
	sub_item    int
}

const nm_customdraw = -12
const cdds_prepaint = u32(0x1)
const cdds_itemprepaint = u32(0x10001)
const cdrf_dodefault = isize(0)
const cdrf_notifyitemdraw = isize(0x20)
const swp_nozorder = u32(0x0004)

struct Msg {
	hwnd    voidptr
	message u32
	wparam  usize
	lparam  isize
	time    u32
	pt      Point
	private u32
}

struct WndClassEx {
	size       u32
	style      u32
	wnd_proc   voidptr
	cls_extra  int
	wnd_extra  int
	instance   voidptr
	icon       voidptr
	cursor     voidptr
	background voidptr
	menu_name  voidptr
	class_name voidptr
	icon_small voidptr
}

struct CreateStruct {
	create_params voidptr
}

struct MinMaxInfo {
	reserved     Point
	max_size     Point
	max_position Point
mut:
	min_track Point
	max_track Point
}

// LogFont.quality: smooth (antialiased) text even if the system setting is off.
const cleartype_quality = u8(5)

struct LogFont {
mut:
	height           int
	width            int
	escapement       int
	orientation      int
	weight           int
	italic           u8
	underline        u8
	strike_out       u8
	char_set         u8
	out_precision    u8
	clip_precision   u8
	quality          u8
	pitch_and_family u8
	face_name        [32]u16
}

struct NonClientMetrics {
mut:
	size              u32
	border_width      int
	scroll_width      int
	scroll_height     int
	caption_width     int
	caption_height    int
	caption_font      LogFont
	sm_caption_width  int
	sm_caption_height int
	sm_caption_font   LogFont
	menu_width        int
	menu_height       int
	menu_font         LogFont
	status_font       LogFont
	message_font      LogFont
	padded_border     int
}

struct IconInfo {
	is_icon   int
	hotspot_x u32
	hotspot_y u32
	mask      voidptr
	color     voidptr
}

struct BitmapInfoHeader {
	size          u32
	width         int
	height        int
	planes        u16
	bit_count     u16
	compression   u32
	size_image    u32
	x_ppm         int
	y_ppm         int
	clr_used      u32
	clr_important u32
}

struct FlashWInfo {
	size    u32
	hwnd    voidptr
	flags   u32
	count   u32
	timeout u32
}

struct InitCommonControlsEx {
	size u32
	icc  u32
}

struct LvColumn {
	mask       u32
	fmt        int
	cx         int
	text       voidptr
	text_max   int
	sub_item   int
	image      int
	order      int
	cx_min     int
	cx_default int
	cx_ideal   int
}

struct LvItem {
	mask       u32
	item       int
	sub_item   int
	state      u32
	state_mask u32
	text       voidptr
	text_max   int
	image      int
	lparam     isize
	indent     int
	group_id   int
	columns    u32
	pu_columns voidptr
	pi_col_fmt voidptr
	group      int
}

struct NotifyIconData {
mut:
	size         u32
	hwnd         voidptr
	id           u32
	flags        u32
	callback_msg u32
	icon         voidptr
	tip          [128]u16
	state        u32
	state_mask   u32
	info         [256]u16
	timeout      u32
	info_title   [64]u16
	info_flags   u32
	guid         [4]u32
	balloon_icon voidptr
}

struct OpenFileName {
mut:
	struct_size     u32
	owner           voidptr
	instance        voidptr
	filter          voidptr
	custom_filter   voidptr
	max_cust_filter u32
	filter_index    u32
	file            voidptr
	max_file        u32
	file_title      voidptr
	max_file_title  u32
	initial_dir     voidptr
	title           voidptr
	flags           u32
	file_offset     u16
	file_extension  u16
	def_ext         voidptr
	cust_data       isize
	hook            voidptr
	template_name   voidptr
	reserved_ptr    voidptr
	reserved        u32
	flags_ex        u32
}

struct ActCtx {
	size               u32
	flags              u32
	source             voidptr
	processor_arch     u16
	lang_id            u16
	assembly_directory voidptr
	resource_name      voidptr
	application_name   voidptr
	module             voidptr
}

type FnInitCommonControlsEx = fn (voidptr) int

type FnShellNotifyIcon = fn (u32, voidptr) int

type FnShellExecute = fn (voidptr, &u16, &u16, voidptr, voidptr, int) voidptr

type FnPlaySound = fn (&u16, voidptr, u32) int

type FnMciSendString = fn (&u16, voidptr, u32, voidptr) u32

type FnGetOpenFileName = fn (voidptr) int

type FnSetLayeredWindowAttributes = fn (voidptr, u32, u8, u32) int

type FnSetProcessDpiAware = fn () int

type FnCreateActCtx = fn (voidptr) voidptr

type FnActivateActCtx = fn (voidptr, voidptr) int

type FnChangeWindowMessageFilterEx = fn (voidptr, u32, u32, voidptr) int

// proc_address loads `dll` (from the system search path) and resolves `name`.
fn proc_address(dll string, name string) voidptr {
	module_handle := C.LoadLibraryW(dll.to_wide())
	if module_handle == unsafe { nil } {
		return unsafe { nil }
	}
	return C.GetProcAddress(module_handle, &u8(name.str))
}

fn loword(v usize) int {
	return int(v & 0xffff)
}

fn hiword(v usize) int {
	return int((v >> 16) & 0xffff)
}

fn makelong(lo int, hi int) isize {
	return isize((u32(hi) << 16) | (u32(lo) & 0xffff))
}

fn ptr_param(p voidptr) isize {
	return isize(p)
}

fn window_text(hwnd voidptr) string {
	mut buf := []u16{len: 1024}
	n := C.GetWindowTextW(hwnd, buf.data, buf.len)
	return unsafe { string_from_wide2(buf.data, n) }
}

fn set_text(hwnd voidptr, text string) {
	C.SetWindowTextW(hwnd, text.to_wide())
}

// copy_wide writes a truncated, NUL-terminated UTF-16 copy of text into a
// fixed-size buffer of `capacity` code units.
fn copy_wide(dst &u16, capacity int, text string) {
	src := text.to_wide()
	mut i := 0
	unsafe {
		for i < capacity - 1 && src[i] != 0 {
			dst[i] = src[i]
			i++
		}
		dst[i] = 0
	}
}
