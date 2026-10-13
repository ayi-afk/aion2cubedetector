module main

import math
import os
import remote
import wire

// Cube Watch tells the backend (server/, address fixed at build time from
// .env) where the character is and what happens to the things the backend
// tracks - cubes and whatever else its admin named. The connection lives on
// a worker thread (remote.Link); when the backend cannot be reached it
// tries again every 20 - 30 s and the app works as usual meanwhile.

const wm_remote = wm_app + 4
// Positions are reported at most this often (seconds) ...
const remote_min_interval = 1.0
// ... and at least this often, so the character stays on the backend's map.
const remote_heartbeat = 10.0

fn remote_notify(arg voidptr) {
	app := unsafe { &App(arg) }
	C.PostMessageW(app.hwnd, wm_remote, 0, 0)
}

fn (mut app App) start_remote() {
	// A replay is an old session; it is only reported when asked for.
	if remote_addr == '' || (app.replay_path != '' && '--replay-remote' !in os.args) {
		return
	}
	if app.settings.install_id == '' {
		app.settings.install_id = new_install_id()
		// kept also when this run is a replay: the id belongs to the PC
		save_settings(app.settings) or { eprintln('Cannot save settings: ${err}') }
	}
	mut link := remote.new_link(remote.Config{
		addr:    remote_addr
		key:     remote_key
		install: app.settings.install_id
	})
	link.on_change(remote_notify, app)
	link.start()
	app.remote = link
}

fn (app &App) remote_on() bool {
	return app.remote != unsafe { nil }
}

// on_remote runs on the GUI thread when the worker has news.
fn (mut app App) on_remote() {
	if !app.remote_on() {
		return
	}
	online := app.remote.is_online()
	if online != app.remote_online {
		app.remote_online = online
		app.dirty = true
	}
	// Say once why the backend cannot be reached (not at every retry).
	problem := app.remote.problem()
	if problem != app.remote_problem {
		app.remote_problem = problem
		if problem != '' {
			app.set_status('Hub offline: ${problem}', true)
		}
	}
	for msg in app.remote.take_inbox() {
		match msg.t {
			wire.t_kinds {
				app.remote_kinds.clear()
				for k in msg.kinds {
					app.remote_kinds[wire.kind_key(k.cat, k.tpl)] = k
				}
				app.objects_dirty = true
				// The backend is (back) online or tracks other things now:
				// tell it everything that is in view.
				app.remote_me(true)
				for o in app.objects {
					app.remote_seen(o)
				}
			}
			wire.t_error {
				app.set_status('The backend refused Cube Watch: ${msg.msg}', true)
			}
			wire.t_nearby {
				app.remote_near(msg.msg)
			}
			else {}
		}
	}
}

// kind_name is the name of a template: the user's own, else the backend's.
fn (app &App) kind_name(category string, template u32) string {
	name := app.objdb.name(category, template)
	if name != '' {
		return name
	}
	kind := app.remote_kinds[wire.kind_key(category, template)] or { return '' }
	return kind.name
}

fn (app &App) remote_tracks(category string, template u32) bool {
	return app.remote_online && wire.kind_key(category, template) in app.remote_kinds
}

// remote_me reports the character's last known position; `force` skips
// the rate limit.
fn (mut app App) remote_me(force bool) {
	if !app.remote_online {
		return
	}
	p := app.player or { return }
	now := now_seconds()
	if !force && now - app.remote_me_at < remote_min_interval {
		return
	}
	app.remote_me_at = now
	app.remote.send(wire.ClientMsg{
		t:      wire.t_me
		server: app.settings.character_server
		name:   app.settings.character
		map:    app.map_id
		x:      p.pos.x
		y:      p.pos.y
		z:      p.pos.z
	})
}

fn (app &App) remote_about(t string, o ObjectRow) wire.ClientMsg {
	return wire.ClientMsg{
		t:      t
		server: app.settings.character_server
		map:    app.map_id
		x:      o.pos.x
		y:      o.pos.y
		z:      o.pos.z
		cat:    o.category
		tpl:    o.template
		id:     o.id
	}
}

// remote_seen reports that a tracked object or NPC is in view.
fn (mut app App) remote_seen(o ObjectRow) {
	if !app.remote_tracks(o.category, o.template) {
		return
	}
	app.remote.send(wire.ClientMsg{
		...app.remote_about(wire.t_seen, o)
		age: if o.created > 0 { now_seconds() - o.created } else { -1.0 }
	})
}

// remote_left reports that a tracked object was opened by a player
// (`taken`, `mine` when it was this character) or destroyed.
fn (mut app App) remote_left(o ObjectRow, taken bool, mine bool) {
	if !app.remote_tracks(o.category, o.template) {
		return
	}
	app.remote.send(wire.ClientMsg{
		...app.remote_about(if taken { wire.t_taken } else { wire.t_gone }, o)
		mine: mine
	})
}

// remote_near answers the admin's "what is around this client": every
// object and NPC in view, nearest first - also the ones the backend does
// not track yet, so that they can be given a name there.
fn (mut app App) remote_near(request string) {
	mut items := []wire.NearItem{}
	for o in app.objects {
		dist := if p := app.player {
			math.hypot(o.pos.x - p.pos.x, o.pos.y - p.pos.y)
		} else {
			-1.0
		}
		items << wire.NearItem{o.category, o.template, o.id, o.pos.x, o.pos.y, o.pos.z, dist}
	}
	items.sort(a.dist < b.dist)
	if items.len > wire.max_near_items {
		items = items[..wire.max_near_items].clone()
	}
	app.remote.send(wire.ClientMsg{
		t:     wire.t_near
		key:   request
		items: items
	})
}

// tick_remote runs on the refresh timer.
fn (mut app App) tick_remote() {
	if app.remote_online && now_seconds() - app.remote_me_at >= remote_heartbeat {
		app.remote_me(true)
	}
}

// remote_text is the backend's state for the player line.
fn (app &App) remote_text() string {
	if !app.remote_on() {
		return ''
	}
	return if app.remote_online { ' | hub online' } else { ' | hub offline' }
}
