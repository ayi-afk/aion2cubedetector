module main

import db.sqlite
import x.json2

// The maps the backend can draw are compiled in: assets/maps.json says how
// world coordinates land on each image. The admin can change the list of
// map ids and the calibration of a built-in map without a rebuild; those
// changes are kept in the database (meta).
//
// Every other map is the admin's: a name and the map ids that belong to it
// (meta `map_names`, lines `id=name`; ids with the same name are one map).
// What is reported from such a map is drawn on a grid, never on another
// map's image. An id with the name of a built-in map is one more id of it.

const maps_json = $embed_file('assets/maps.json').to_string()
const map_asmodians_jpg = $embed_file('assets/map_asmodians.jpg')
const map_lower_reshanta_jpg = $embed_file('assets/map_lower_reshanta.jpg')

struct MapDef {
pub mut:
	key        string
	name       string
	image      string
	width      int
	height     int
	map_ids    []u32
	is_default bool @[json: 'default']
	// px = ox + sx * world x, py = oy + sy * world y
	sx f64
	sy f64
	ox f64
	oy f64
}

struct MapsFile {
	maps []MapDef
}

// map_image returns the embedded image of a built-in map.
fn map_image(name string) ?string {
	return match name {
		'map_asmodians.jpg' { map_asmodians_jpg.to_string() }
		'map_lower_reshanta.jpg' { map_lower_reshanta_jpg.to_string() }
		else { none }
	}
}

// load_maps reads the built-in maps and applies the admin's changes.
fn load_maps(db &sqlite.DB) ![]MapDef {
	file := json2.decode[MapsFile](maps_json)!
	mut maps := file.maps.clone()
	for mut m in maps {
		ids := meta_get(db, 'map.${m.key}.ids', '')
		if ids != '' {
			m.map_ids = ids.split(',').map(it.trim_space().u32()).filter(it != 0)
		}
		cal := meta_get(db, 'map.${m.key}.cal', '').split(',')
		if cal.len == 4 && cal[0].f64() != 0 && cal[1].f64() != 0 {
			m.sx, m.sy, m.ox, m.oy = cal[0].f64(), cal[1].f64(), cal[2].f64(), cal[3].f64()
		}
	}
	// the admin's maps
	for id, name in meta_names(db, 'map_names') {
		mut placed := false
		for m in maps {
			if u32(id) in m.map_ids {
				placed = true
				break
			}
		}
		if placed {
			continue
		}
		for mut m in maps {
			if m.name.to_lower() == name.to_lower() {
				m.map_ids << u32(id)
				placed = true
				break
			}
		}
		if !placed {
			maps << MapDef{
				key:     'map${id}'
				name:    name
				map_ids: [u32(id)]
			}
		}
	}
	return maps
}

fn save_map_settings(db &sqlite.DB, m MapDef) ! {
	meta_set(db, 'map.${m.key}.ids', m.map_ids.map(it.str()).join(','))!
	meta_set(db, 'map.${m.key}.cal', '${m.sx},${m.sy},${m.ox},${m.oy}')!
}
