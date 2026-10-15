module main

import db.sqlite
import os
import server.world

// SQLite keeps what must survive a restart: the admin's configuration
// (groups, kinds, map settings), the spots and the history of what happened at
// them. What is at each spot right now and all counters live in memory
// (world.World) and are rebuilt from the history at start.

const schema = [
	"CREATE TABLE IF NOT EXISTS meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL DEFAULT ''
	) WITHOUT ROWID",
	"CREATE TABLE IF NOT EXISTS groups (
		id    INTEGER PRIMARY KEY AUTOINCREMENT,
		name  TEXT NOT NULL UNIQUE COLLATE NOCASE,
		color TEXT NOT NULL DEFAULT '#f5a623',
		sort  INTEGER NOT NULL DEFAULT 0
	)",
	"CREATE TABLE IF NOT EXISTS kinds (
		cat         TEXT NOT NULL,
		tpl         INTEGER NOT NULL,
		name        TEXT NOT NULL DEFAULT '',
		group_id    INTEGER NOT NULL DEFAULT 0,
		respawn_sec INTEGER NOT NULL DEFAULT 0,
		report      INTEGER NOT NULL DEFAULT 1,
		PRIMARY KEY(cat, tpl)
	) WITHOUT ROWID",
	// skey = world.spot_key(...): the map, kind and position rounded to a metre
	"CREATE TABLE IF NOT EXISTS spots (
		id         INTEGER PRIMARY KEY,
		skey       TEXT NOT NULL UNIQUE,
		map        INTEGER NOT NULL,
		cat        TEXT NOT NULL,
		tpl        INTEGER NOT NULL,
		x          REAL NOT NULL,
		y          REAL NOT NULL,
		z          REAL NOT NULL,
		label      TEXT NOT NULL DEFAULT '',
		hidden     INTEGER NOT NULL DEFAULT 0,
		first_seen INTEGER NOT NULL DEFAULT 0
	)",
	"CREATE TABLE IF NOT EXISTS events (
		id      INTEGER PRIMARY KEY AUTOINCREMENT,
		ts      INTEGER NOT NULL,
		server  INTEGER NOT NULL,
		spot_id INTEGER NOT NULL,
		typ     TEXT NOT NULL,
		created INTEGER NOT NULL DEFAULT 0,
		who     TEXT NOT NULL DEFAULT '',
		entity  INTEGER NOT NULL DEFAULT 0,
		UNIQUE(server, spot_id, ts, typ, who)
	)",
	'CREATE INDEX IF NOT EXISTS events_spot ON events(spot_id, ts)',
	// which characters were played from which Cube Watch installation
	'CREATE TABLE IF NOT EXISTS owners (
		install   TEXT NOT NULL,
		server    INTEGER NOT NULL,
		name      TEXT NOT NULL COLLATE NOCASE,
		last_seen INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY(install, server, name)
	) WITHOUT ROWID',
	// one JSON document per character, as the map page shows it
	'CREATE TABLE IF NOT EXISTS profiles (
		server     INTEGER NOT NULL,
		name       TEXT NOT NULL COLLATE NOCASE,
		json       TEXT NOT NULL,
		fetched_at INTEGER NOT NULL,
		PRIMARY KEY(server, name)
	) WITHOUT ROWID',
]

// History is read back in pieces of this many events.
const events_chunk = 20000

// open_more_db opens one more connection to the database open_db made:
// for the background writes, or (`read_only`) for the statistics.
fn open_more_db(path string, read_only bool) !sqlite.DB {
	mut db := sqlite.connect(path)!
	db.busy_timeout(15000)
	db.exec_none('PRAGMA synchronous=NORMAL')
	if read_only {
		db.exec_none('PRAGMA query_only=1')
	}
	return db
}

fn open_db(path string) !sqlite.DB {
	mut db := sqlite.connect(path)!
	db.busy_timeout(15000)
	db.exec_none('PRAGMA journal_mode=WAL')
	db.exec_none('PRAGMA synchronous=NORMAL')
	for stmt in schema {
		q(db, stmt)!
	}
	// added later: the address a character's client last connected from
	if q(db, "SELECT count(*) FROM pragma_table_info('owners') WHERE name='ip'")![0].vals[0] == '0' {
		q(db, "ALTER TABLE owners ADD COLUMN ip TEXT NOT NULL DEFAULT ''")!
	}
	// Each known kind is added once: what the admin renames, moves or
	// deletes afterwards stays that way. (A database from before this list
	// was counted already has the first one, the cube.)
	mut seeded := meta_get(db, 'kinds_seeded', '').int()
	if seeded == 0 && q(db, 'SELECT count(*) FROM kinds')![0].vals[0] != '0' {
		seeded = 1
	}
	for i in seeded .. known_kinds.len {
		k := known_kinds[i]
		q(db, 'INSERT OR IGNORE INTO groups(name,color,sort) VALUES(?,?,?)', k.group,
			k.color, i.str())!
		q(db, 'INSERT OR IGNORE INTO kinds(cat,tpl,name,group_id) VALUES(?,?,?,(SELECT id FROM groups WHERE name=?))',
			k.cat, k.tpl.str(), k.name, k.group)!
	}
	if seeded != known_kinds.len {
		meta_set(db, 'kinds_seeded', known_kinds.len.str())!
	}
	// The maps known by their id get their names once, too; from then on
	// they are the admin's like any map added in the panel.
	if meta_get(db, 'map_names_seeded', '') == '' {
		mut names := meta_names(db, 'map_names')
		for id, name in known_maps {
			if id !in names {
				names[id] = name
			}
		}
		meta_set_names(db, 'map_names', names)!
		meta_set(db, 'map_names_seeded', '1')!
	}
	return db
}

// Map ids whose map is known (the ones with an image are in assets/maps.json).
const known_maps = {
	600001: 'Caro Cave'
}

struct KnownKind {
	cat   string
	tpl   u32
	name  string
	group string
	color string
}

// The kinds known when the backend was built. New ones go to the end.
const known_kinds = [
	KnownKind{'object', 1301199, 'Cube', 'Cubes', '#f5a623'},
	KnownKind{'object', 1500062, 'Odyle', 'Expedition', '#4fc3f7'},
]

// q runs a statement with bound parameters and propagates errors.
fn q(db &sqlite.DB, query string, params ...string) ![]sqlite.Row {
	return db.exec_param_many(query, params)
}

fn flag01(b bool) string {
	return if b { '1' } else { '0' }
}

// load_world reads the configuration and the spots, then replays the history.
fn load_world(db &sqlite.DB) !&world.World {
	mut w := &world.World{}
	for r in q(db, 'SELECT id,name,color,sort FROM groups')! {
		w.groups[r.vals[0].int()] = world.Group{
			id:    r.vals[0].int()
			name:  r.vals[1]
			color: r.vals[2]
			sort:  r.vals[3].int()
		}
	}
	for r in q(db, 'SELECT cat,tpl,name,group_id,respawn_sec,report FROM kinds')! {
		k := world.Kind{
			cat:         r.vals[0]
			tpl:         r.vals[1].u32()
			name:        r.vals[2]
			group_id:    r.vals[3].int()
			respawn_sec: r.vals[4].int()
			report:      r.vals[5] == '1'
		}
		w.kinds[k.key()] = k
	}
	for r in q(db, 'SELECT id,map,cat,tpl,x,y,z,label,hidden,first_seen FROM spots')! {
		w.add_spot(world.Spot{
			id:         r.vals[0].int()
			map:        r.vals[1].u32()
			cat:        r.vals[2]
			tpl:        r.vals[3].u32()
			x:          r.vals[4].f64()
			y:          r.vals[5].f64()
			z:          r.vals[6].f64()
			label:      r.vals[7]
			hidden:     r.vals[8] == '1'
			first_seen: r.vals[9].i64()
		})
	}
	w.begin_replay()
	mut last := i64(0)
	for {
		rows := q(db, 'SELECT id,ts,server,spot_id,typ,created,who,entity FROM events WHERE id>? ORDER BY id LIMIT ${events_chunk}',
			last.str())!
		for r in rows {
			last = r.vals[0].i64()
			w.replay(world.Event{
				ts:      r.vals[1].i64()
				server:  r.vals[2].int()
				spot_id: r.vals[3].int()
				typ:     r.vals[4]
				created: r.vals[5].i64()
				who:     r.vals[6]
				entity:  r.vals[7].u64()
			})
		}
		if rows.len < events_chunk {
			break
		}
	}
	w.refresh_expected()
	w.take_dirty_spots()
	return w
}

fn save_spot(db &sqlite.DB, s world.Spot) ! {
	q(db, 'INSERT INTO spots(id,skey,map,cat,tpl,x,y,z,label,hidden,first_seen) VALUES(?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET label=excluded.label, hidden=excluded.hidden',
		s.id.str(), world.spot_key(s.map, s.cat, s.tpl, s.x, s.y, s.z), s.map.str(), s.cat,
		s.tpl.str(), s.x.str(), s.y.str(), s.z.str(), s.label, flag01(s.hidden), s.first_seen.str())!
}

// save_changes writes the spots and events collected since the last call
// in one transaction.
fn save_changes(db &sqlite.DB, spots []world.Spot, events []world.Event) ! {
	if spots.len == 0 && events.len == 0 {
		return
	}
	q(db, 'BEGIN IMMEDIATE')!
	for s in spots {
		save_spot(db, s) or {
			db.exec_none('ROLLBACK')
			return err
		}
	}
	for e in events {
		q(db, 'INSERT OR IGNORE INTO events(ts,server,spot_id,typ,created,who,entity) VALUES(?,?,?,?,?,?,?)',
			e.ts.str(), e.server.str(), e.spot_id.str(), e.typ, e.created.str(), e.who,
			e.entity.str()) or {
			db.exec_none('ROLLBACK')
			return err
		}
	}
	q(db, 'COMMIT')!
}

// ---- export / import -------------------------------------------------------------

// export_database returns a consistent copy of the database file.
fn export_database(db &sqlite.DB) !string {
	tmp := os.join_path(os.temp_dir(), 'cubewatch_export_${os.getpid()}_${now_unix()}.db')
	q(db, "VACUUM INTO '${tmp.replace("'", "''")}'")!
	defer {
		os.rm(tmp) or {}
	}
	return os.read_file(tmp)!
}

struct ImportResult {
	groups_added int
	kinds_added  int
	spots_added  int
	events_added int
	events_total int
}

// merge_database merges another backend database file into `db`: groups
// are matched by name, kinds by (category, template), spots by position
// (the same metre on the same map), events by (server, spot, time, type,
// who). What is already here stays, so importing the same file
// twice changes nothing.
fn merge_database(db &sqlite.DB, file string) !ImportResult {
	mut f := os.open(file)!
	mut header := []u8{len: 16}
	f.read(mut header) or {}
	f.close()
	if header[..15].bytestr() != 'SQLite format 3' {
		return error('this is not an SQLite database')
	}
	q(db, "ATTACH DATABASE '${file.replace("'", "''")}' AS imp") or {
		return error('cannot open the file: ${err.msg()}')
	}
	defer {
		db.exec_none('DETACH DATABASE imp')
	}
	for t in ['groups', 'kinds', 'spots', 'events'] {
		n := q(db, "SELECT count(*) FROM imp.sqlite_master WHERE type='table' AND name=?",
			t)!
		if n[0].vals[0] == '0' {
			return error('not a Cube Watch backend database: table "${t}" is missing')
		}
	}
	total := q(db, 'SELECT count(*) FROM imp.events')![0].vals[0].int()
	q(db, 'BEGIN IMMEDIATE')!
	mut committed := false
	defer {
		if !committed {
			db.exec_none('ROLLBACK')
		}
	}
	q(db, 'INSERT OR IGNORE INTO groups(name,color,sort) SELECT name,color,sort FROM imp.groups')!
	groups_added := db.get_affected_rows_count()
	q(db, 'INSERT OR IGNORE INTO kinds(cat,tpl,name,group_id,respawn_sec,report)
		SELECT k.cat, k.tpl, k.name,
			coalesce((SELECT g.id FROM groups g JOIN imp.groups ig ON ig.name = g.name WHERE ig.id = k.group_id), 0),
			k.respawn_sec, k.report
		FROM imp.kinds k')!
	kinds_added := db.get_affected_rows_count()
	// New spots get ids after the ones that are here.
	q(db, 'INSERT OR IGNORE INTO spots(id,skey,map,cat,tpl,x,y,z,label,hidden,first_seen)
		SELECT (SELECT coalesce(max(id),0) FROM spots) + row_number() OVER (ORDER BY s.id),
			s.skey, s.map, s.cat, s.tpl, s.x, s.y, s.z, s.label, s.hidden, s.first_seen
		FROM imp.spots s WHERE s.skey NOT IN (SELECT skey FROM spots)')!
	spots_added := db.get_affected_rows_count()
	q(db, 'INSERT OR IGNORE INTO events(ts,server,spot_id,typ,created,who,entity)
		SELECT e.ts, e.server, s.id, e.typ, e.created, e.who, e.entity
		FROM imp.events e JOIN imp.spots i ON i.id = e.spot_id JOIN spots s ON s.skey = i.skey
		ORDER BY e.id')!
	events_added := db.get_affected_rows_count()
	q(db, 'COMMIT')!
	committed = true
	return ImportResult{groups_added, kinds_added, spots_added, events_added, total}
}

// ---- meta -------------------------------------------------------------------------

fn meta_get(db &sqlite.DB, key string, def string) string {
	rows := db.exec_param('SELECT value FROM meta WHERE key=?', key) or { return def }
	return if rows.len == 0 { def } else { rows[0].vals[0] }
}

fn meta_set(db &sqlite.DB, key string, value string) ! {
	q(db, 'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
		key, value)!
}

// meta_names reads a list of names kept as lines `id=name`.
fn meta_names(db &sqlite.DB, key string) map[int]string {
	mut names := map[int]string{}
	for line in meta_get(db, key, '').split('\n') {
		id, name := line.split_once('=') or { continue }
		if id.int() > 0 && name != '' {
			names[id.int()] = name
		}
	}
	return names
}

fn meta_set_names(db &sqlite.DB, key string, names map[int]string) ! {
	mut lines := []string{}
	for id, name in names {
		lines << '${id}=${name}'
	}
	meta_set(db, key, lines.join('\n'))!
}

// ---- profiles ---------------------------------------------------------------------

fn profile_put(db &sqlite.DB, server int, name string, doc string, fetched_at i64) ! {
	q(db, 'INSERT INTO profiles(server,name,json,fetched_at) VALUES(?,?,?,?)
		ON CONFLICT(server,name) DO UPDATE SET json=excluded.json, fetched_at=excluded.fetched_at',
		server.str(), name, doc, fetched_at.str())!
}
