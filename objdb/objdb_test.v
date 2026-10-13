module objdb

import os

fn cube_at(x f64, y f64) Place {
	return Place{
		map:      1110
		category: category_object
		template: 1301199
		x:        x
		y:        y
		z:        28616.0
		flags:    '0400 010101'
	}
}

fn test_names() {
	mut db := Db{}
	assert db.name(category_object, 1301199) == 'Cube'
	assert db.name(category_npc, 1301199) == ''
	db.rename(category_npc, 2400031, '  Wolf, "grey"\n')
	assert db.name(category_npc, 2400031) == 'Wolf, "grey"'
	assert db.names_dirty && db.places_dirty
	db.rename(category_object, 1301199, 'Kostka')
	assert db.name(category_object, 1301199) == 'Kostka'
	// An empty name brings the built-in one back.
	db.rename(category_object, 1301199, ' ')
	assert db.name(category_object, 1301199) == 'Cube'
	assert db.names.len == 1
	db.names_dirty = false
	db.rename(category_npc, 2400031, 'Wolf, "grey"')
	assert !db.names_dirty, 'the same name changes nothing'
}

fn test_places_are_grouped_by_grid() {
	mut db := Db{}
	db.record(cube_at(-134043.7, -54024.8), '2026-10-12 18:47:20')
	db.record(cube_at(-134040.0, -54030.0), '2026-10-12 19:10:00') // same spot
	db.record(cube_at(-133000.0, -54024.8), '2026-10-12 19:20:00')
	assert db.places.len == 2
	first := db.places.values()[0]
	assert first.times == 2
	assert first.first_seen == '2026-10-12 18:47:20'
	assert first.last_seen == '2026-10-12 19:10:00'
	assert first.x == -134043.7
	// NPCs roam: 1,000 units apart is still the same place, for objects it is not.
	npc := Place{
		category: category_npc
		template: 2400031
		x:        100.0
		y:        100.0
		max_hp:   50
	}
	db.record(npc, 't')
	db.record(Place{
		...npc
		x: 900.0
	}, 't')
	assert db.places.len == 3
	// The same coordinates on another map (or an unknown one) are another place.
	db.record(Place{
		...cube_at(-134043.7, -54024.8)
		map: 600001
	}, 't')
	db.record(Place{
		...cube_at(-134043.7, -54024.8)
		map: 0
	}, 't')
	assert db.places.len == 5
}

fn test_csv_round_trip() {
	dir := os.join_path(os.temp_dir(), 'cube_watch_objdb_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut db := Db{}
	db.rename(category_npc, 2400031, 'Wolf, "grey" żółw')
	db.record(cube_at(-134043.7, -54024.8), '2026-10-12 18:47:20')
	db.record(Place{
		category: category_npc
		template: 2400031
		x:        -134949.2
		y:        -54123.6
		z:        27188.0
		flags:    '042000 0002'
		max_hp:   50
	}, '2026-10-12 18:47:21')
	db.save(dir)!
	assert !db.names_dirty && !db.places_dirty
	text := os.read_file(os.join_path(dir, places_file))!
	assert text.starts_with(utf8_mark + places_header)
	assert text.contains('1110,object,1301199,Cube,-134043.7,-54024.8,28616.0,0400 010101,,2026-10-12 18:47:20,2026-10-12 18:47:20,1')
	// The map of this one is unknown.
	assert text.contains('\n,npc,2400031,"Wolf, ""grey"" żółw",-134949.2,-54123.6,27188.0,042000 0002,50,')

	back := load(dir)
	assert back.names == db.names
	assert back.places.len == 2
	assert back.places == db.places
	assert back.name(category_npc, 2400031) == 'Wolf, "grey" żółw'
	// A place loaded from the file is found again.
	mut again := load(dir)
	again.record(cube_at(-134043.7, -54024.8), '2026-10-13 10:00:00')
	assert again.places.len == 2
	assert again.places.values()[0].times == 2
}

fn test_bad_lines_are_skipped() {
	mut db := Db{}
	db.parse_names('type,template,name\nnpc,5,\nplayer,7,Somebody\n\nobject,9,Chest\n')
	assert db.names == {
		'object:9': 'Chest'
	}
	db.parse_places('garbage\n1110,object,9,Chest,1.0,2.0\nobject,9,Chest,1,2,3,0400,,a,b,1\n')
	assert db.places.len == 0
	assert load(os.join_path(os.temp_dir(), 'cube_watch_no_such_dir')).places.len == 0
}
