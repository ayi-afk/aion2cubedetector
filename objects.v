module main

import math
import objdb
import proto
import time

// Objects tab: every object and NPC the game server reports in view, with
// its template id, position, distance and the flags of its spawn message.
// A template can be given a name (double-click or F2 on the row); names go
// to data/names.csv, and every place a template was seen to data/db.csv
// (see the objdb module), so the files become a map of what is where.

// The list is rebuilt at most this often (seconds).
const objects_refresh_seconds = 0.5
// db.csv is written this often (seconds) while it has changes, and on exit.
const objects_save_seconds = 30.0

// Objects list columns.
const ocol_name = 0
const ocol_type = 1
const ocol_template = 2
const ocol_entity = 3
const ocol_distance = 4
const ocol_height = 5
const ocol_x = 6
const ocol_y = 7
const ocol_z = 8
const ocol_info = 9
const ocol_flags = 10
const ocol_seen = 11

struct ObjectRow {
	id       u64
	category string // objdb.category_object / category_npc
	template u32
	flags    string
	seen     f64 // first seen in this session
mut:
	pos      proto.Vec3
	hp       i64
	max_hp   i64
	created  f64 // when the server created the object (local clock), 0 unknown
	distance f64 = -1 // flat distance to the player, -1 unknown
}

struct NmItemActivate {
	hdr      NmHdr
	item     int
	sub_item int
}

struct NmLvKeyDown {
	hdr  NmHdr
	vkey u16
}

fn entity_category(c proto.EntityCategory) string {
	return match c {
		.object { objdb.category_object }
		.npc { objdb.category_npc }
	}
}

fn format_age(seconds f64) string {
	s := i64(math.max(seconds, 0))
	return if s < 60 {
		'${s}s'
	} else if s < 3600 {
		'${s / 60}m ${s % 60}s'
	} else if s < 86400 {
		'${s / 3600}h ${s % 3600 / 60}m'
	} else {
		'${s / 86400}d ${s % 86400 / 3600}h'
	}
}

fn local_time_text(timestamp f64) string {
	return time.unix(i64(timestamp)).local().format_ss()
}

fn (mut app App) init_objects_list(list voidptr) {
	C.SendMessageW(list, lvm_setextendedlistviewstyle, 0, lvs_ex_fullrowselect | lvs_ex_gridlines | lvs_ex_doublebuffer)
	// Order must match the ocol_* constants.
	columns := [['Name', '120', 'l'], ['Type', '50', 'l'], ['ID', '64', 'r'],
		['Entity', '52', 'r'], ['Distance', '64', 'r'], ['Height', '78', 'r'],
		['X', '76', 'r'], ['Y', '76', 'r'], ['Z', '64', 'r'],
		['Info', '160', 'l'], ['Flags', '92', 'l'], ['Seen', '60', 'l']]
	for i, c in columns {
		col := LvColumn{
			mask: lvcf_fmt | lvcf_width | lvcf_text
			fmt:  if c[2] == 'r' { lvcfmt_right } else { lvcfmt_left }
			cx:   app.s(c[1].int())
			text: c[0].to_wide()
		}
		C.SendMessageW(list, lvm_insertcolumnw, usize(i), ptr_param(&col))
	}
}

fn (app &App) object_index(id u64) int {
	for i, o in app.objects {
		if o.id == id {
			return i
		}
	}
	return -1
}

fn (mut app App) on_entity(ev proto.Event) {
	mut row := ObjectRow{
		id:       ev.id
		category: entity_category(ev.info.category)
		template: ev.info.template
		flags:    ev.info.flags
		seen:     ev.timestamp
		pos:      ev.pos
		hp:       ev.info.hp
		max_hp:   ev.info.max_hp
		created:  if ev.info.age >= 0 { ev.timestamp - ev.info.age } else { 0.0 }
	}
	i := app.object_index(ev.id)
	if i >= 0 {
		// The same entity came back into view.
		row = ObjectRow{
			...row
			seen: app.objects[i].seen
		}
		app.objects[i] = row
	} else {
		app.objects << row
	}
	app.objects_dirty = true
	app.remote_seen(row)
	// Replays would count the places of the original session again.
	if app.replay_path == '' {
		app.objdb.record(objdb.Place{
			map:      app.map_id
			category: row.category
			template: row.template
			x:        row.pos.x
			y:        row.pos.y
			z:        row.pos.z
			flags:    row.flags
			max_hp:   row.max_hp
		}, local_time_text(ev.timestamp))
	}
}

fn (mut app App) on_entity_moved(ev proto.Event) {
	i := app.object_index(ev.id)
	if i >= 0 {
		app.objects[i].pos = ev.pos
		app.objects_dirty = true
	}
}

fn (mut app App) on_entity_removed(ev proto.Event) {
	i := app.object_index(ev.id)
	if i >= 0 {
		o := app.objects[i]
		// Destroyed (collected, expired) or dead, not merely out of view.
		gone := if o.category == objdb.category_npc {
			ev.reason == proto.npc_removed_dead
		} else {
			ev.reason == proto.removed_destroyed
		}
		if gone {
			app.remote_left(o, false, false)
		}
		app.objects.delete(i)
		app.objects_dirty = true
	}
}

// on_entity_opened: a player finished opening an object.
fn (mut app App) on_entity_opened(ev proto.Event) {
	i := app.object_index(ev.id)
	if i >= 0 {
		app.remote_left(app.objects[i], true, app.is_self(ev.actor))
	}
}

// clear_objects empties the Objects list, e.g. when the game connects to
// another server: its entity ids mean something else.
fn (mut app App) clear_objects() {
	app.objects.clear()
	app.objects_dirty = true
	app.refresh_objects(true)
}

fn (app &App) selected_object() int {
	return int(C.SendMessageW(app.ctl(.objects), lvm_getnextitem, ~usize(0), lvni_selected))
}

fn (app &App) select_object(index int, selected bool) {
	item := LvItem{
		state:      if selected { lvis_selected | lvis_focused } else { u32(0) }
		state_mask: lvis_selected | lvis_focused
	}
	C.SendMessageW(app.ctl(.objects), lvm_setitemstate, usize(index), ptr_param(&item))
}

// refresh_objects sorts the rows nearest first and redraws the list. It
// waits while a name is being edited: the rows must not move under the
// edit box.
fn (mut app App) refresh_objects(now bool) {
	if !app.objects_view || !app.objects_dirty || app.objects_editing || app.settings.compact {
		return
	}
	t := now_seconds()
	if !now && t - app.objects_refreshed < objects_refresh_seconds {
		return
	}
	app.objects_refreshed = t
	app.objects_dirty = false
	list := app.ctl(.objects)
	selected := app.selected_object()
	selected_id := if selected >= 0 && selected < app.objects.len {
		app.objects[selected].id
	} else {
		u64(0)
	}
	for mut o in app.objects {
		o.distance = if p := app.player {
			math.hypot(o.pos.x - p.pos.x, o.pos.y - p.pos.y)
		} else {
			-1.0
		}
	}
	app.objects.sort_with_compare(fn (a &ObjectRow, b &ObjectRow) int {
		return if a.distance < b.distance {
			-1
		} else if a.distance > b.distance {
			1
		} else if a.seen > b.seen {
			-1
		} else if a.seen < b.seen {
			1
		} else {
			int(a.id) - int(b.id)
		}
	})
	C.SendMessageW(list, lvm_setitemcount, usize(app.objects.len), lvsicf_noinvalidateall | lvsicf_noscroll)
	// Keep the selection on the same entity.
	if selected >= 0 {
		at := if selected_id != 0 { app.object_index(selected_id) } else { -1 }
		if at != selected {
			app.select_object(selected, false)
			if at >= 0 {
				app.select_object(at, true)
			}
		}
	}
	C.InvalidateRect(list, unsafe { nil }, 0)
}

fn (app &App) object_cell(o ObjectRow, col int) string {
	return match col {
		ocol_name {
			app.kind_name(o.category, o.template)
		}
		ocol_type {
			if o.category == objdb.category_npc {
				'NPC'
			} else {
				'Object'
			}
		}
		ocol_template {
			o.template.str()
		}
		ocol_entity {
			o.id.str()
		}
		ocol_distance {
			if o.distance < 0 {
				'-'
			} else {
				format_units(o.distance)
			}
		}
		ocol_height {
			if p := app.player {
				height_text(o.pos.z - p.pos.z)
			} else {
				'-'
			}
		}
		ocol_x {
			'${o.pos.x:.1f}'
		}
		ocol_y {
			'${o.pos.y:.1f}'
		}
		ocol_z {
			'${o.pos.z:.1f}'
		}
		ocol_info {
			if o.max_hp >= 0 {
				'HP ${o.hp} / ${o.max_hp}'
			} else if o.created > 0 {
				'created ${format_age(now_seconds() - o.created)} ago'
			} else {
				''
			}
		}
		ocol_flags {
			o.flags
		}
		ocol_seen {
			time.unix(i64(o.seen)).local().hhmmss()
		}
		else {
			''
		}
	}
}

fn (app &App) objects_dispinfo(mut info NmLvDispInfo) {
	if info.item.item < 0 || info.item.item >= app.objects.len {
		return
	}
	dispinfo_text(mut info, app.object_cell(app.objects[info.item.item], info.item.sub_item))
}

// edit_object_name opens the in-place editor on a row's name.
fn (mut app App) edit_object_name(index int) {
	if index < 0 || index >= app.objects.len {
		return
	}
	C.SetFocus(app.ctl(.objects))
	C.SendMessageW(app.ctl(.objects), lvm_editlabelw, usize(index), 0)
}

// on_objects_notify handles the Objects list; the result goes back to the
// list view.
fn (mut app App) on_objects_notify(hdr &NmHdr, lparam isize) isize {
	match hdr.code {
		lvn_getdispinfow {
			mut info := unsafe { &NmLvDispInfo(voidptr(lparam)) }
			app.objects_dispinfo(mut info)
		}
		nm_dblclk {
			click := unsafe { &NmItemActivate(voidptr(lparam)) }
			app.edit_object_name(click.item)
		}
		lvn_keydown {
			key := unsafe { &NmLvKeyDown(voidptr(lparam)) }
			if key.vkey == vk_f2 {
				app.edit_object_name(app.selected_object())
			}
		}
		lvn_beginlabeleditw {
			info := unsafe { &NmLvDispInfo(voidptr(lparam)) }
			if info.item.item < 0 || info.item.item >= app.objects.len {
				return 1 // nothing to rename
			}
			// The row can move or vanish while the name is typed.
			o := app.objects[info.item.item]
			app.objects_editing = true
			app.edit_category = o.category
			app.edit_template = o.template
		}
		lvn_endlabeleditw {
			info := unsafe { &NmLvDispInfo(voidptr(lparam)) }
			app.objects_editing = false
			app.objects_dirty = true
			if info.item.text != unsafe { nil } {
				name := unsafe { string_from_wide(&u16(info.item.text)) }
				app.rename_template(app.edit_category, app.edit_template, name)
			}
		}
		else {}
	}
	return 0
}

fn (mut app App) rename_template(category string, template u32, name string) {
	app.objdb.rename(category, template, name)
	shown := app.objdb.name(category, template)
	app.save_objdb()
	if !app.objdb.names_dirty {
		app.set_status(if shown == '' {
			'Name of ${category} ${template} removed.'
		} else {
			'${category} ${template} is now "${shown}" (saved to data\\${objdb.names_file}).'
		}, false)
	}
}

// save_objdb writes names.csv / db.csv when they have changes.
fn (mut app App) save_objdb() {
	app.objdb_saved = now_seconds()
	app.objdb.save(data_dir()) or {
		app.set_status('Cannot save the object database (is the file open in another program?): ${err}',
			true)
	}
}

// tick_objects runs on the refresh timer.
fn (mut app App) tick_objects() {
	now := now_seconds()
	if app.objdb.places_dirty && now - app.objdb_saved >= objects_save_seconds {
		app.save_objdb()
	}
	// Ages and distances change while nothing else does.
	if app.objects_view && now - app.objects_refreshed >= 1.0 {
		app.objects_dirty = true
	}
	app.refresh_objects(false)
}

fn (app &App) objects_summary() string {
	map_text := if app.map_id != 0 { 'map ${app.map_id}' } else { 'map not known yet' }
	return 'Objects: ${app.objects.len} in view (${map_text}), ${app.objdb.places.len} places in data\\${objdb.places_file}. Double-click a row (or F2) to name it.'
}

// set_objects_view switches the list area between the cubes and the
// Objects tab.
fn (mut app App) set_objects_view(on bool) {
	app.objects_view = on
	C.SendMessageW(app.ctl(.tab_cubes), bm_setcheck, usize(!on), 0)
	C.SendMessageW(app.ctl(.tab_objects), bm_setcheck, usize(on), 0)
	app.layout()
	if on {
		app.objects_dirty = true
		app.refresh_objects(true)
		app.set_status(app.objects_summary(), false)
	}
}

// copy_object puts the selected object's coordinates on the clipboard.
fn (mut app App) copy_object() {
	index := app.selected_object()
	if index < 0 || index >= app.objects.len {
		app.set_status('Select a row in the list to copy its coordinates.', false)
		return
	}
	o := app.objects[index]
	text := format_pos(o.pos)
	if app.copy_text(text) {
		mut name := app.kind_name(o.category, o.template)
		if name == '' {
			name = '${o.category} ${o.template}'
		}
		app.set_status('Copied ${name} coordinates: ${text}', false)
	}
}
