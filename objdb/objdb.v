// Package objdb keeps what the Objects tab learns about the game world:
// the names the user gave to object / NPC templates (names.csv) and where
// each template was seen (db.csv). No Windows dependencies.
module objdb

import math
import os
import strings

pub const names_file = 'names.csv'
pub const places_file = 'db.csv'

const names_header = 'type,template,name'
const places_header = 'map,type,template,name,x,y,z,flags,max_hp,first_seen,last_seen,times_seen'

// Excel reads a CSV as UTF-8 only when it starts with this mark.
const utf8_mark = '\xef\xbb\xbf'

// Sightings of one template closer together than this (world units, flat)
// are one place: objects stand still, NPCs roam around their spot.
pub const object_grid_units = 200.0
pub const npc_grid_units = 2000.0

pub const category_object = 'object'
pub const category_npc = 'npc'

// Names shown until the user chooses another one.
const default_names = {
	'object:1301199': 'Cube'
}

// Place is one spot where a template was seen.
pub struct Place {
pub:
	map      u32    // map the character was on, 0 unknown
	category string // category_object / category_npc
	template u32
	x        f64 // position of the first sighting
	y        f64
	z        f64
	flags    string
	max_hp   i64 = -1 // NPCs only
pub mut:
	first_seen string // local time, 2026-10-05 14:03:22
	last_seen  string
	times      int // how often it came into view here
}

pub struct Db {
pub mut:
	names  map[string]string // template key -> name given by the user
	places map[string]Place  // place key -> place, in the order first seen
	// Something changed since the files were written.
	names_dirty  bool
	places_dirty bool
}

// key identifies a template: the same number can be an object and an NPC.
pub fn key(category string, template u32) string {
	return '${category}:${template}'
}

// place_key: the same coordinates on another map are another place.
fn place_key(p Place) string {
	grid := if p.category == category_npc { npc_grid_units } else { object_grid_units }
	return '${p.map}:${p.category}:${p.template}:${i64(math.round(p.x / grid))}:${i64(math.round(p.y / grid))}'
}

// name returns the user's name for a template, else the built-in one, else ''.
pub fn (db &Db) name(category string, template u32) string {
	k := key(category, template)
	return db.names[k] or { default_names[k] or { '' } }
}

// rename sets the name of a template; an empty name removes it.
pub fn (mut db Db) rename(category string, template u32, name string) {
	k := key(category, template)
	clean := name.replace_each(['\r', ' ', '\n', ' ']).trim_space()
	if clean == db.names[k] or { '' } {
		return
	}
	if clean == '' {
		db.names.delete(k)
	} else {
		db.names[k] = clean
	}
	db.names_dirty = true
	db.places_dirty = true // db.csv repeats the names
}

// record notes that `p` came into view at the local time `when`.
pub fn (mut db Db) record(p Place, when string) {
	k := place_key(p)
	if k in db.places {
		db.places[k].last_seen = when
		db.places[k].times++
	} else {
		db.places[k] = Place{
			...p
			first_seen: when
			last_seen:  when
			times:      1
		}
	}
	db.places_dirty = true
}

// csv_field quotes a value when it needs it.
fn csv_field(s string) string {
	if !s.contains_any(',"\r\n') {
		return s
	}
	return '"' + s.replace('"', '""') + '"'
}

// split_csv splits one CSV line, honouring quoted fields.
fn split_csv(line string) []string {
	mut fields := []string{}
	mut sb := strings.new_builder(32)
	mut quoted := false
	mut i := 0
	for i < line.len {
		c := line[i]
		if quoted {
			if c == `"` && i + 1 < line.len && line[i + 1] == `"` {
				sb.write_u8(`"`)
				i++
			} else if c == `"` {
				quoted = false
			} else {
				sb.write_u8(c)
			}
		} else if c == `"` {
			quoted = true
		} else if c == `,` {
			fields << sb.str()
		} else {
			sb.write_u8(c)
		}
		i++
	}
	fields << sb.str()
	return fields
}

fn csv_lines(text string) []string {
	return text.trim_string_left(utf8_mark).split_into_lines()
}

pub fn (db &Db) names_csv() string {
	mut sb := strings.new_builder(256)
	sb.writeln(utf8_mark + names_header)
	mut keys := db.names.keys()
	keys.sort()
	for k in keys {
		parts := k.split(':')
		sb.writeln('${parts[0]},${parts[1]},${csv_field(db.names[k])}')
	}
	return sb.str()
}

pub fn (mut db Db) parse_names(text string) {
	for line in csv_lines(text) {
		f := split_csv(line)
		if f.len < 3 || f[0] !in [category_object, category_npc] || f[2].trim_space() == '' {
			continue
		}
		db.names[key(f[0], f[1].trim_space().u32())] = f[2].trim_space()
	}
}

pub fn (db &Db) places_csv() string {
	mut sb := strings.new_builder(4096)
	sb.writeln(utf8_mark + places_header)
	for _, p in db.places {
		hp := if p.max_hp < 0 { '' } else { p.max_hp.str() }
		map_id := if p.map == 0 { '' } else { p.map.str() }
		sb.writeln('${map_id},${p.category},${p.template},${csv_field(db.name(p.category,
			p.template))},${p.x:.1f},${p.y:.1f},${p.z:.1f},${csv_field(p.flags)},${hp},${p.first_seen},${p.last_seen},${p.times}')
	}
	return sb.str()
}

// parse_places reads db.csv; its name column is only for the reader of the
// file (names.csv holds the names).
pub fn (mut db Db) parse_places(text string) {
	for line in csv_lines(text) {
		f := split_csv(line)
		if f.len < 12 || f[1] !in [category_object, category_npc] {
			continue
		}
		p := Place{
			map:        f[0].trim_space().u32()
			category:   f[1]
			template:   f[2].trim_space().u32()
			x:          f[4].f64()
			y:          f[5].f64()
			z:          f[6].f64()
			flags:      f[7]
			max_hp:     if f[8].trim_space() == '' { i64(-1) } else { f[8].trim_space().i64() }
			first_seen: f[9]
			last_seen:  f[10]
			times:      f[11].trim_space().int()
		}
		db.places[place_key(p)] = p
	}
}

// load reads names.csv and db.csv from `dir`; missing files give an empty Db.
pub fn load(dir string) Db {
	mut db := Db{}
	db.parse_names(os.read_file(os.join_path(dir, names_file)) or { '' })
	db.parse_places(os.read_file(os.join_path(dir, places_file)) or { '' })
	return db
}

// save writes the files that changed. A file that cannot be written (e.g.
// open in Excel) stays marked as changed, so a later save tries again.
pub fn (mut db Db) save(dir string) ! {
	if !db.names_dirty && !db.places_dirty {
		return
	}
	os.mkdir_all(dir)!
	if db.names_dirty {
		os.write_file(os.join_path(dir, names_file), db.names_csv())!
		db.names_dirty = false
	}
	if db.places_dirty {
		os.write_file(os.join_path(dir, places_file), db.places_csv())!
		db.places_dirty = false
	}
}
