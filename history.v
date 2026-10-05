module main

import math
import os
import proto
import rand
import strings
import time

// Cube history: every cube of a session is appended to
// data/cubes_<8 random chars>.csv next to the exe once its fate is known
// (taken, destroyed, cleared or app exit). All data/cubes_*.csv files are
// loaded at startup for the History list and the overlay's history dots.
//
// Columns: appeared, spawned_in_range, x, y, z, taken_by_us, distance
//   spawned_in_range: 1 = it appeared already inside the view range (we
//     were there when it spawned), 0 = we came into range of an existing
//     cube; estimated from the distance at first sight (see
//     spawn_in_range_units), empty when our position was unknown
//   taken_by_us: 1 = we opened it, 0 = another player, empty = unknown
//     (vanished, cleared or still there)
//   distance: planar distance at first sight, so spawned_in_range can be
//     re-estimated later

const history_header = 'appeared,spawned_in_range,x,y,z,taken_by_us,distance'
// Cubes come into view about 15,000 units away; one first seen clearly
// closer than that most likely spawned while we were in range.
const spawn_in_range_units = 12000.0
// History dots: positions within this many world units share one spot.
const history_grid_units = 300.0

struct HistoryRow {
	appeared string // local time, 2026-10-05 14:03:22
	spawned  int    // 1 / 0 / -1 unknown
	pos      proto.Vec3
	taken    int // 1 us / 0 others / -1 unknown
	distance f64 // -1 unknown
}

// HistorySpot groups history rows at one spawn point for the overlay.
struct HistorySpot {
mut:
	x      f64
	y      f64
	us     int
	others int
	total  int
}

fn data_dir() string {
	return os.join_path(os.dir(os.executable()), 'data')
}

fn csv_int(v int) string {
	return if v < 0 { '' } else { v.str() }
}

fn (r HistoryRow) csv_line() string {
	dist := if r.distance < 0 { '' } else { '${r.distance:.0f}' }
	return '${r.appeared},${csv_int(r.spawned)},${r.pos.x:.1f},${r.pos.y:.1f},${r.pos.z:.1f},${csv_int(r.taken)},${dist}'
}

fn parse_csv_int(s string) int {
	t := s.trim_space()
	return if t == '' { -1 } else { t.int() }
}

fn parse_history_line(line string) ?HistoryRow {
	f := line.trim_space().split(',')
	if f.len < 6 || f[0] == 'appeared' {
		return none
	}
	return HistoryRow{
		appeared: f[0].trim_space()
		spawned:  parse_csv_int(f[1])
		pos:      proto.Vec3{f[2].f32(), f[3].f32(), f[4].f32()}
		taken:    parse_csv_int(f[5])
		distance: if f.len > 6 && f[6].trim_space() != '' { f[6].f64() } else { -1 }
	}
}

// load_history reads every data/cubes_*.csv, newest row first.
fn load_history() []HistoryRow {
	mut rows := []HistoryRow{}
	// os.ls + name check: os.glob does not match Windows paths reliably.
	names := os.ls(data_dir()) or { return rows }
	for name in names {
		if !name.starts_with('cubes_') || !name.to_lower().ends_with('.csv') {
			continue
		}
		lines := os.read_lines(os.join_path(data_dir(), name)) or { continue }
		for line in lines {
			if row := parse_history_line(line) {
				rows << row
			}
		}
	}
	rows.sort(a.appeared > b.appeared)
	return rows
}

fn random_tag() string {
	chars := 'abcdefghijklmnopqrstuvwxyz0123456789'
	mut sb := strings.new_builder(8)
	for _ in 0 .. 8 {
		sb.write_u8(chars[rand.intn(chars.len) or { 0 }])
	}
	return sb.str()
}

// write_history appends one row to this session's CSV (created on first use)
// and to the in-memory history.
fn (mut app App) write_history(row HistoryRow) {
	// Replays would duplicate rows of the original session.
	if app.replay_path != '' {
		return
	}
	if app.history_file == '' {
		os.mkdir_all(data_dir()) or {
			eprintln('Cannot create ${data_dir()}: ${err}')
			return
		}
		app.history_file = os.join_path(data_dir(), 'cubes_${random_tag()}.csv')
		os.write_file(app.history_file, history_header + '\n') or {
			eprintln('Cannot create ${app.history_file}: ${err}')
			app.history_file = ''
			return
		}
	}
	mut f := os.open_append(app.history_file) or {
		eprintln('Cannot write ${app.history_file}: ${err}')
		return
	}
	f.writeln(row.csv_line()) or {}
	f.close()
	app.history.insert(0, row)
	app.history_changed()
}

// log_cube records a cube once; taken: 1 us, 0 another player, -1 unknown.
fn (mut app App) log_cube(i int, taken int) {
	if i < 0 || i >= app.cubes.len || app.cubes[i].logged {
		return
	}
	app.cubes[i].logged = true
	c := app.cubes[i]
	app.write_history(HistoryRow{
		appeared: time.unix(i64(c.appeared)).local().format_ss()
		spawned:  c.spawned
		pos:      c.pos
		taken:    taken
		distance: c.first_distance
	})
}

// log_open_cubes records every cube not logged yet (clear / exit).
fn (mut app App) log_open_cubes() {
	for i in 0 .. app.cubes.len {
		app.log_cube(i, -1)
	}
}

// history_changed refreshes the History list and the overlay's dots.
fn (mut app App) history_changed() {
	app.history_spots = group_history(app.history)
	C.SendMessageW(app.ctl(.history), lvm_setitemcount, usize(app.history.len), 0)
	C.InvalidateRect(app.ctl(.history), unsafe { nil }, 0)
	if app.settings.overlay_history {
		app.render_overlay()
	}
}

fn group_history(rows []HistoryRow) []HistorySpot {
	mut index := map[string]int{}
	mut spots := []HistorySpot{}
	for r in rows {
		key := '${int(math.round(r.pos.x / history_grid_units))},${int(math.round(r.pos.y / history_grid_units))}'
		mut at := index[key] or {
			index[key] = spots.len
			spots << HistorySpot{
				x: r.pos.x
				y: r.pos.y
			}
			spots.len - 1
		}
		spots[at].total++
		if r.taken == 1 {
			spots[at].us++
		} else if r.taken == 0 {
			spots[at].others++
		}
	}
	return spots
}

// spot_color: green when mostly taken by us, red when mostly by others,
// grey when nobody was seen taking it; 70 % opacity.
fn spot_color(s HistorySpot) u32 {
	known := s.us + s.others
	if known == 0 {
		return 0xb3a0a0a0
	}
	f := f64(s.us) / f64(known)
	r := u32(math.min(255.0, 2 * (1 - f) * 255))
	g := u32(math.min(255.0, 2 * f * 255))
	return 0xb3000000 | (r << 16) | (g << 8) | 0x20
}

fn (app &App) history_summary() string {
	mut us, mut others := 0, 0
	for r in app.history {
		if r.taken == 1 {
			us++
		} else if r.taken == 0 {
			others++
		}
	}
	return 'History: ${app.history.len} cubes (taken by us ${us}, by others ${others}) from ${data_dir()}'
}

// ---- History list (virtual list view) -------------------------------------------

struct NmLvDispInfo {
	hdr  NmHdr
	item LvItem
}

fn (mut app App) init_history_list(list voidptr) {
	C.SendMessageW(list, lvm_setextendedlistviewstyle, 0, lvs_ex_fullrowselect | lvs_ex_gridlines | lvs_ex_doublebuffer)
	columns := [['Appeared', '130', 'l'], ['Spawned', '64', 'r'],
		['X', '76', 'r'], ['Y', '76', 'r'], ['Z', '64', 'r'],
		['Taken by', '72', 'l'], ['Distance', '70', 'r']]
	for i, c in columns {
		col := LvColumn{
			mask: lvcf_fmt | lvcf_width | lvcf_text
			fmt:  if c[2] == 'r' { lvcfmt_right } else { lvcfmt_left }
			cx:   app.s(c[1].int())
			text: c[0].to_wide()
		}
		C.SendMessageW(list, lvm_insertcolumnw, usize(i), ptr_param(&col))
	}
	C.SendMessageW(list, lvm_setitemcount, usize(app.history.len), 0)
}

fn (app &App) history_cell(r HistoryRow, col int) string {
	return match col {
		0 {
			r.appeared
		}
		1 {
			if r.spawned < 0 {
				'?'
			} else if r.spawned == 1 {
				'yes'
			} else {
				'no'
			}
		}
		2 {
			'${r.pos.x:.1f}'
		}
		3 {
			'${r.pos.y:.1f}'
		}
		4 {
			'${r.pos.z:.1f}'
		}
		5 {
			if r.taken < 0 {
				'?'
			} else if r.taken == 1 {
				'us'
			} else {
				'others'
			}
		}
		6 {
			if r.distance < 0 {
				'?'
			} else {
				format_units(r.distance)
			}
		}
		else {
			''
		}
	}
}

// history_dispinfo fills a cell of the virtual History list on request.
fn (app &App) history_dispinfo(mut info NmLvDispInfo) {
	if info.item.mask & lvif_text == 0 || info.item.item < 0 || info.item.item >= app.history.len
		|| info.item.text == unsafe { nil } || info.item.text_max <= 0 {
		return
	}
	text := app.history_cell(app.history[info.item.item], info.item.sub_item).to_wide()
	unsafe {
		mut dst := &u16(info.item.text)
		mut n := 0
		for n < info.item.text_max - 1 && text[n] != 0 {
			dst[n] = text[n]
			n++
		}
		dst[n] = 0
	}
}

fn (mut app App) set_history_view(on bool) {
	app.history_view = on
	C.SendMessageW(app.ctl(.history_toggle), bm_setcheck, usize(on), 0)
	app.layout()
	if on {
		app.set_status(app.history_summary(), false)
	}
}
