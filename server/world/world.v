// Package world is the backend's picture of the game: the templates it
// tracks (kinds, in groups), the spots where they spawn, what is at each
// spot on each game server right now, and where the players are. It only
// keeps state and does the arithmetic (no sockets, no database), so it is
// unit tested; main.v feeds it reports and stores what it hands back.
module world

import math

pub const category_object = 'object'
pub const category_npc = 'npc'

// Reports within this many world units of each other are the same spot (1 m).
pub const spot_grid_units = 100.0
// Two reports whose creation times differ by less are the same spawn.
const same_spawn_seconds = i64(5)
// Several clients watch the same cube: a second "taken" / "gone" within
// this time is the same event.
const same_take_seconds = i64(60)
// Respawn delays outside this range are not believable (missed events).
const min_delay_seconds = i64(5)
const max_delay_seconds = i64(7 * 86400)
// How many delays are remembered per spot / per kind.
const spot_delays_kept = 20
const kind_delays_kept = 200
// A kind-wide estimate needs at least this many observed delays.
const kind_delays_needed = 3

pub const event_seen = 'seen' // a new one was created at the spot
pub const event_taken = 'taken' // a player opened it
pub const event_gone = 'gone' // it was destroyed, opener unknown
pub const event_noted = 'noted' // one was there at that time (imported history); says nothing about now

pub struct Group {
pub mut:
	id    int
	name  string
	color string = '#f5a623'
	sort  int
}

// Kind is one template (what a thing is) the backend tracks.
pub struct Kind {
pub mut:
	cat         string
	tpl         u32
	name        string
	group_id    int
	respawn_sec int // set by the admin; 0 = estimate from what was observed
	report      bool = true // clients are asked to report it
}

pub fn (k Kind) key() string {
	return '${k.cat}:${k.tpl}'
}

// Spot is a place where a kind spawns.
pub struct Spot {
pub mut:
	id         int
	map        u32
	cat        string
	tpl        u32
	x          f64
	y          f64
	z          f64
	label      string // set by the admin
	hidden     bool   // set by the admin: not shown on the map
	first_seen i64
	spawns     int   // spawns observed here, all game servers together
	takes      int   // times it was taken / destroyed here
	delays     []int // observed respawn delays in seconds, newest last
	// How long the ones whose creation time was known stayed before they
	// were taken or destroyed: sum of seconds and how many.
	life_sum i64
	life_n   int
}

// avg_pickup is how long, on average, one stays here before it is taken
// (seconds, 0 = not known).
pub fn (s Spot) avg_pickup() int {
	return if s.life_n > 0 { int(s.life_sum / s.life_n) } else { 0 }
}

// State is what is at a spot on one game server.
pub struct State {
pub mut:
	server   int
	spot_id  int
	present  bool
	entity   u64
	created  i64    // when the game server created the current / last one, 0 unknown
	seen_at  i64    // last report that it is there
	taken_at i64    // when the last one was taken or destroyed, 0 unknown
	taken_by string // character that opened it, '' unknown
	expected i64    // when the next one should spawn, 0 unknown
}

pub struct Person {
pub mut:
	server  int
	name    string
	map     u32
	x       f64
	y       f64
	z       f64
	seen_at i64
}

// Event is one line of a spot's history; the database keeps them and the
// world is rebuilt from them at start.
pub struct Event {
pub:
	ts      i64
	server  int
	spot_id int
	typ     string // event_seen / event_taken / event_gone
	created i64    // event_seen: when the game server created it
	who     string // event_taken: the character, '' unknown
	entity  u64
}

// Sighting is a report about one entity at a position.
pub struct Sighting {
pub:
	server  int
	who     string // the reporting character, '' unknown
	map     u32
	cat     string
	tpl     u32
	x       f64
	y       f64
	z       f64
	entity  u64
	created i64 // when the game server created it, 0 unknown
}

@[heap]
pub struct World {
pub mut:
	groups    map[int]Group
	kinds     map[string]Kind
	spots     map[int]Spot
	states    map[string]State  // state_key(server, spot id)
	people    map[string]Person // person_key(server, name)
	spot_keys map[string]int    // spot_key(...) -> spot id
	next_spot int = 1
	// Respawn delays of every spot of a kind together.
	kind_delays map[string][]int
	// Filled while reports are applied, emptied by the caller.
	new_events  []Event
	dirty_spots map[int]bool
	// While the stored history is replayed nothing is recorded again.
	replaying bool
}

pub fn person_key(server int, name string) string {
	return '${server}:${name.to_lower()}'
}

pub fn state_key(server int, spot_id int) string {
	return '${server}:${spot_id}'
}

fn cell(v f64) i64 {
	return i64(math.round(v / spot_grid_units))
}

pub fn spot_key(map_id u32, cat string, tpl u32, x f64, y f64, z f64) string {
	return '${map_id}:${cat}:${tpl}:${cell(x)}:${cell(y)}:${cell(z)}'
}

// tracks reports whether clients should report this template.
pub fn (w &World) tracks(cat string, tpl u32) bool {
	k := w.kinds['${cat}:${tpl}'] or { return false }
	return k.report
}

// add_spot puts a stored spot back (at start).
pub fn (mut w World) add_spot(s Spot) {
	w.spots[s.id] = s
	w.spot_keys[spot_key(s.map, s.cat, s.tpl, s.x, s.y, s.z)] = s.id
	if s.id >= w.next_spot {
		w.next_spot = s.id + 1
	}
}

// remove_spot forgets a spot and what is known about it on every server.
pub fn (mut w World) remove_spot(id int) {
	s := w.spots[id] or { return }
	w.spot_keys.delete(spot_key(s.map, s.cat, s.tpl, s.x, s.y, s.z))
	w.spots.delete(id)
	for key, st in w.states {
		if st.spot_id == id {
			w.states.delete(key)
		}
	}
	w.dirty_spots.delete(id)
}

fn (mut w World) spot_for(s Sighting, now i64, create bool) ?int {
	key := spot_key(s.map, s.cat, s.tpl, s.x, s.y, s.z)
	if id := w.spot_keys[key] {
		return id
	}
	if !create {
		return none
	}
	id := w.next_spot
	w.next_spot++
	w.spots[id] = Spot{
		id:         id
		map:        s.map
		cat:        s.cat
		tpl:        s.tpl
		x:          s.x
		y:          s.y
		z:          s.z
		first_seen: now
	}
	w.spot_keys[key] = id
	w.dirty_spots[id] = true
	return id
}

fn (mut w World) record(e Event) {
	if !w.replaying {
		w.new_events << e
	}
}

fn median(values []int) int {
	if values.len == 0 {
		return 0
	}
	mut sorted := values.clone()
	sorted.sort()
	mid := sorted.len / 2
	return if sorted.len % 2 == 1 { sorted[mid] } else { (sorted[mid - 1] + sorted[mid]) / 2 }
}

// respawn_seconds is how long after being taken a spot gets its next one:
// the admin's value, else what was observed at this spot, else what was
// observed for the kind; 0 = not known.
pub fn (w &World) respawn_seconds(spot_id int) int {
	s := w.spots[spot_id] or { return 0 }
	key := '${s.cat}:${s.tpl}'
	if k := w.kinds[key] {
		if k.respawn_sec > 0 {
			return k.respawn_sec
		}
	}
	if s.delays.len > 0 {
		return median(s.delays)
	}
	all := w.kind_delays[key] or { return 0 }
	return if all.len >= kind_delays_needed { median(all) } else { 0 }
}

fn (mut w World) add_delay(spot_id int, delay i64) {
	if delay < min_delay_seconds || delay > max_delay_seconds {
		return
	}
	mut s := w.spots[spot_id] or { return }
	s.delays << int(delay)
	if s.delays.len > spot_delays_kept {
		s.delays.delete(0)
	}
	w.spots[spot_id] = s
	key := '${s.cat}:${s.tpl}'
	mut all := w.kind_delays[key] or { []int{} }
	all << int(delay)
	if all.len > kind_delays_kept {
		all.delete(0)
	}
	w.kind_delays[key] = all
}

// seen applies "this entity is there". It returns the state to show, or
// none when the kind is not tracked.
pub fn (mut w World) seen(s Sighting, now i64) ?State {
	if !w.replaying && !w.tracks(s.cat, s.tpl) {
		return none
	}
	spot_id := w.spot_for(s, now, true)?
	key := state_key(s.server, spot_id)
	mut st := w.states[key] or {
		State{
			server:  s.server
			spot_id: spot_id
		}
	}
	// Without a creation time a sighting of an absent thing is a new spawn.
	created := if s.created > 0 {
		s.created
	} else if st.present {
		st.created
	} else {
		now
	}
	is_new := st.created == 0 || math.abs(created - st.created) > same_spawn_seconds
	if is_new {
		if st.taken_at > 0 && created > st.taken_at {
			w.add_delay(spot_id, created - st.taken_at)
		}
		mut spot := w.spots[spot_id]
		spot.spawns++
		w.spots[spot_id] = spot
		w.dirty_spots[spot_id] = true
		w.record(Event{
			ts:      now
			server:  s.server
			spot_id: spot_id
			typ:     event_seen
			created: created
			entity:  s.entity
		})
		st.taken_at = 0
		st.taken_by = ''
	}
	st.present = true
	st.entity = s.entity
	st.created = created
	st.seen_at = now
	st.expected = 0
	w.states[key] = st
	return st
}

// noted counts a sighting from the past (an imported history): the spot is
// known and was used once more, but what is there now stays unknown.
pub fn (mut w World) noted(s Sighting, when i64) int {
	spot_id := w.spot_for(s, when, true) or { return 0 }
	mut spot := w.spots[spot_id]
	spot.spawns++
	if when < spot.first_seen || spot.first_seen == 0 {
		spot.first_seen = when
	}
	w.spots[spot_id] = spot
	w.dirty_spots[spot_id] = true
	w.record(Event{
		ts:      when
		server:  s.server
		spot_id: spot_id
		typ:     event_noted
		created: when
	})
	return spot_id
}

// left applies "this entity was opened by a player" (taken = true, `mine`
// when the reporter did it) or "it was destroyed" (taken = false).
pub fn (mut w World) left(s Sighting, taken bool, mine bool, now i64) ?State {
	spot_id := w.spot_for(s, now, false)?
	key := state_key(s.server, spot_id)
	mut st := w.states[key] or { return none }
	who := if taken && mine { s.who } else { '' }
	if !st.present && st.taken_at > 0 && now - st.taken_at < same_take_seconds {
		// Already known; another client may know who did it.
		if who != '' && st.taken_by == '' {
			st.taken_by = who
			w.states[key] = st
			w.record(Event{
				ts:      st.taken_at
				server:  s.server
				spot_id: spot_id
				typ:     event_taken
				who:     who
				entity:  s.entity
			})
			return st
		}
		return none
	}
	if !st.present {
		return none
	}
	st.present = false
	st.taken_at = now
	st.taken_by = who
	delay := w.respawn_seconds(spot_id)
	st.expected = if delay > 0 { now + delay } else { 0 }
	w.states[key] = st
	mut spot := w.spots[spot_id]
	spot.takes++
	if st.created > 0 && now >= st.created && now - st.created <= max_delay_seconds {
		spot.life_sum += now - st.created
		spot.life_n++
	}
	w.spots[spot_id] = spot
	w.dirty_spots[spot_id] = true
	w.record(Event{
		ts:      now
		server:  s.server
		spot_id: spot_id
		typ:     if taken { event_taken } else { event_gone }
		who:     who
		entity:  s.entity
	})
	return st
}

// replay applies one stored event (at start); the spot must be there.
pub fn (mut w World) replay(e Event) {
	spot := w.spots[e.spot_id] or { return }
	s := Sighting{
		server:  e.server
		who:     e.who
		map:     spot.map
		cat:     spot.cat
		tpl:     spot.tpl
		x:       spot.x
		y:       spot.y
		z:       spot.z
		entity:  e.entity
		created: e.created
	}
	w.replaying = true
	if e.typ == event_noted {
		w.noted(s, e.ts)
	} else if e.typ == event_seen {
		w.seen(s, e.ts)
	} else {
		key := state_key(e.server, e.spot_id)
		if st := w.states[key] {
			if !st.present && st.taken_by == '' && e.who != '' {
				// The name of the opener arrived after the take itself.
				w.states[key] = State{
					...st
					taken_by: e.who
				}
				w.replaying = false
				return
			}
		}
		w.left(s, e.typ == event_taken, e.who != '', e.ts)
	}
	w.replaying = false
}

// begin_replay forgets the counters that replaying the history rebuilds.
pub fn (mut w World) begin_replay() {
	for id, s in w.spots {
		w.spots[id] = Spot{
			...s
			spawns:   0
			takes:    0
			delays:   []int{}
			life_sum: 0
			life_n:   0
		}
	}
	w.states.clear()
	w.kind_delays.clear()
}

// refresh_expected recomputes when absent spots should respawn, e.g. after
// the admin changed a kind's respawn time.
pub fn (mut w World) refresh_expected() {
	for key, st in w.states {
		if st.present || st.taken_at == 0 {
			continue
		}
		delay := w.respawn_seconds(st.spot_id)
		w.states[key] = State{
			...st
			expected: if delay > 0 { st.taken_at + delay } else { 0 }
		}
	}
}

// me applies a player's position; it returns the person's key.
pub fn (mut w World) me(server int, name string, map_id u32, x f64, y f64, z f64, now i64) string {
	key := person_key(server, name)
	w.people[key] = Person{
		server:  server
		name:    name
		map:     map_id
		x:       x
		y:       y
		z:       z
		seen_at: now
	}
	return key
}

// expire_people drops the players not heard from for `ttl` seconds and
// returns their keys.
pub fn (mut w World) expire_people(now i64, ttl i64) []string {
	mut gone := []string{}
	for key, p in w.people {
		if now - p.seen_at > ttl {
			gone << key
		}
	}
	for key in gone {
		w.people.delete(key)
	}
	return gone
}

// take_events hands over the events recorded since the last call.
pub fn (mut w World) take_events() []Event {
	events := w.new_events
	w.new_events = []Event{}
	return events
}

// take_dirty_spots hands over the spots changed since the last call.
pub fn (mut w World) take_dirty_spots() []Spot {
	mut out := []Spot{}
	for id, _ in w.dirty_spots {
		if s := w.spots[id] {
			out << s
		}
	}
	w.dirty_spots.clear()
	return out
}
