module world

fn new_world() World {
	mut w := World{}
	w.groups[1] = Group{
		id:   1
		name: 'Cubes'
	}
	w.kinds['object:1301199'] = Kind{
		cat:      category_object
		tpl:      1301199
		name:     'Cube'
		group_id: 1
	}
	return w
}

fn cube(server int, who string, entity u64, created i64) Sighting {
	return Sighting{
		server:  server
		who:     who
		map:     1110
		cat:     category_object
		tpl:     1301199
		x:       -134043.7
		y:       -54024.8
		z:       28616.0
		entity:  entity
		created: created
	}
}

fn test_untracked_kinds_are_ignored() {
	mut w := new_world()
	other := Sighting{
		...cube(2304, 'A', 1, 1000)
		tpl: 1300011
	}
	assert w.seen(other, 1010) == none
	assert w.spots.len == 0
	w.kinds['object:1301199'].report = false
	assert w.seen(cube(2304, 'A', 1, 1000), 1010) == none
}

fn test_spawn_take_and_respawn_estimate() {
	mut w := new_world()
	st := w.seen(cube(2304, 'Ann', 7, 1000), 1060) or { panic('tracked') }
	assert st.present && st.created == 1000 && st.seen_at == 1060 && st.spot_id == 1
	// Another client sees the same cube (creation time a second off) a bit later.
	again := w.seen(cube(2304, 'Bob', 7, 1001), 1100) or { panic('tracked') }
	assert again.seen_at == 1100
	assert w.spots[1].spawns == 1
	// A position within the same metre is the same spot, another one is not.
	near := Sighting{
		...cube(2304, 'Ann', 7, 1000)
		x: -134043.7 + 30
	}
	assert (w.seen(near, 1101) or { panic('tracked') }).spot_id == 1
	// The same place on another game server has its own state.
	assert (w.seen(cube(2318, 'Cid', 9, 500), 1102) or { panic('tracked') }).server == 2318
	assert w.spots.len == 1 && w.states.len == 2 && w.spots[1].spawns == 2

	// Bob watches Ann open it; both report, then both see it destroyed.
	t1 := w.left(cube(2304, 'Bob', 7, 0), true, false, 1200) or { panic('known spot') }
	assert !t1.present && t1.taken_at == 1200 && t1.taken_by == '' && t1.expected == 0
	t2 := w.left(cube(2304, 'Ann', 7, 0), true, true, 1201) or { panic('the opener is news') }
	assert t2.taken_by == 'Ann' && t2.taken_at == 1200
	assert w.left(cube(2304, 'Bob', 7, 0), false, false, 1202) == none
	assert w.left(cube(2304, 'Ann', 7, 0), false, false, 1202) == none
	assert w.spots[1].takes == 1
	// Created at 1000, taken at 1200: it stayed 200 s.
	assert w.spots[1].avg_pickup() == 200

	// The next one is created 600 s after the take: that is the respawn delay.
	w.seen(cube(2304, 'Bob', 8, 1800), 1900)
	assert w.spots[1].delays == [600]
	assert w.respawn_seconds(1) == 600
	gone := w.left(cube(2304, 'Bob', 8, 0), false, false, 2000) or { panic('known spot') }
	assert gone.taken_by == '' && gone.expected == 2600

	events := w.take_events()
	assert events.map(it.typ) == [event_seen, event_seen, event_taken, event_taken, event_seen,
		event_gone]
	assert events[3].who == 'Ann' && events[3].ts == 1200
	assert w.take_events().len == 0
	assert w.take_dirty_spots().map(it.id) == [1]
	assert w.take_dirty_spots().len == 0
}

fn test_estimate_falls_back_to_the_kind_and_the_admin_wins() {
	mut w := new_world()
	// Three spots with delays 300, 500, 700; a fourth spot has none of its own.
	for i, delay in [300, 500, 700] {
		s := Sighting{
			...cube(1, 'A', u64(i + 1), 1000)
			x: f64(i) * 1000
		}
		w.seen(s, 1000)
		w.left(s, true, true, 2000)
		w.seen(Sighting{
			...s
			created: 2000 + delay
		}, 3000)
	}
	fourth := Sighting{
		...cube(1, 'A', 9, 1000)
		x: 9000
	}
	w.seen(fourth, 1000)
	st := w.left(fourth, false, false, 5000) or { panic('known spot') }
	assert st.expected == 5500
	// Unbelievable delays are not counted.
	w.add_delay(4, 2)
	w.add_delay(4, 30 * 86400)
	assert w.spots[4].delays.len == 0
	w.kinds['object:1301199'].respawn_sec = 900
	w.refresh_expected()
	assert w.states[state_key(1, 4)].expected == 5900
}

fn test_history_replay_rebuilds_the_same_world() {
	mut w := new_world()
	w.seen(cube(2304, 'Ann', 7, 1000), 1060)
	w.left(cube(2304, 'Bob', 7, 0), true, false, 1200)
	w.left(cube(2304, 'Ann', 7, 0), true, true, 1201)
	w.seen(cube(2304, 'Bob', 8, 1800), 1900)
	w.left(cube(2304, 'Bob', 8, 0), false, false, 2000)
	w.seen(cube(2304, 'Bob', 9, 2600), 2700)
	events := w.take_events()

	mut back := new_world()
	for s in w.take_dirty_spots() {
		back.add_spot(s)
	}
	back.begin_replay()
	for e in events {
		back.replay(e)
	}
	assert back.take_events().len == 0, 'replaying records nothing'
	assert back.spots[1].spawns == 3 && back.spots[1].takes == 2
	assert back.spots[1].delays == w.spots[1].delays
	assert back.spots[1].avg_pickup() == w.spots[1].avg_pickup() && back.spots[1].life_n == 2
	assert back.states == w.states
	assert back.kind_delays == w.kind_delays
	// A new spot gets the next free id.
	far := Sighting{
		...cube(2304, 'Ann', 20, 3000)
		x: 5000
	}
	assert (back.seen(far, 3000) or { panic('tracked') }).spot_id == 2
	back.remove_spot(1)
	assert back.states.len == 1 && back.spots.len == 1
	assert (back.seen(cube(2304, 'Ann', 7, 4000), 4000) or { panic('tracked') }).spot_id == 3
}

fn test_people_come_and_go() {
	mut w := new_world()
	key := w.me(2304, 'ChanterMain', 1110, 1, 2, 3, 100)
	assert key == '2304:chantermain'
	w.me(2304, 'chantermain', 1110, 4, 5, 6, 130)
	w.me(2318, 'Other', 600001, 0, 0, 0, 100)
	assert w.people.len == 2 && w.people[key].x == 4
	assert w.expire_people(200, 90) == ['2318:other']
	assert w.people.len == 1
}

fn test_noted_history_counts_without_a_state() {
	mut w := new_world()
	assert w.noted(cube(0, '', 0, 0), 500) == 1
	assert w.noted(cube(0, '', 0, 0), 900) == 1
	assert w.spots[1].spawns == 2 && w.spots[1].first_seen == 500
	assert w.states.len == 0, 'nothing is known to be there now'
	events := w.take_events()
	assert events.map(it.typ) == [event_noted, event_noted]
	mut back := new_world()
	for s in w.take_dirty_spots() {
		back.add_spot(s)
	}
	back.begin_replay()
	for e in events {
		back.replay(e)
	}
	assert back.spots[1].spawns == 2 && back.states.len == 0
	assert back.take_events().len == 0
}
