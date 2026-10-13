module main

import flag
import x.json2
import net.http
import os
import rand
import sync
import time
import wire
import server.world

// Cube Watch backend: one executable with the web pages, the map and
// SQLite inside. Cube Watch clients report over a websocket where their
// characters are and what they see; browsers get a live map of it.

const app_version = '1.0.0'

const index_html = $embed_file('web/index.html').to_string()
const admin_html = $embed_file('web/admin.html').to_string()

// After this many wrong passwords an IP is blocked for login_block_sec.
const login_max_fails = 5
const login_block_sec = 60
const session_seconds = i64(30 * 86400)

// The template id of a cube, for importing Cube Watch history files.
const cube_template = u32(1301199)

const user_cookie = 'cw_user'
const admin_cookie = 'cw_admin'

struct LoginFails {
mut:
	count         int
	blocked_until i64
}

fn C.GC_expand_hp(bytes usize) int

// The collector stops every thread while it runs, and each connection has
// two threads. Starting with a roomy heap (--heap-mb) makes collections
// rare, which is what keeps hundreds of clients cheap.

pub struct App {
mut:
	hub &Hub = unsafe { nil }
	// Requests are handled on many threads: the session and login maps
	// below are only touched with `mu` held.
	mu             &sync.Mutex = sync.new_mutex()
	password       string
	password_admin string
	db_path        string
	user_sessions  map[string]i64 // token -> expiry
	admin_sessions map[string]i64
	login_fails    map[string]LoginFails
}

fn main() {
	default_db := os.join_path(os.dir(os.executable()), 'cubewatch.db')
	mut fp := flag.new_flag_parser(os.args)
	fp.application('cubewatch-server')
	fp.version(app_version)
	fp.description(
		'Cube Watch backend: collects what Cube Watch clients see and shows it on a live map.\n' +
		'  /        the map (needs --password when one is set)\n' +
		'  /admin   kinds, groups, spots, maps, database (needs --password-admin; without one only from localhost)')
	fp.skip_executable()
	port := fp.int('port', `p`, 8081, 'HTTP / websocket port (default 8081)')
	host := fp.string('host', 0, '0.0.0.0', 'listen address (default 0.0.0.0 = all interfaces)')
	password_flag := fp.string('password', 0, '', 'password for the map page (or CW_PASSWORD); empty = no login')
	admin_flag := fp.string('password-admin', 0, '', 'password for /admin (or CW_PASSWORD_ADMIN); empty = /admin only from localhost')
	key_flag := fp.string('client-key', 0, '', 'key Cube Watch clients must send, REMOTE_KEY in their .env (or CW_CLIENT_KEY); empty = any client')
	db_path := fp.string('db', 0, default_db, 'SQLite database file (default: cubewatch.db next to the executable)')
	heap_mb := fp.int('heap-mb', 0, 128, 'memory (MB) set aside at start so the garbage collector runs rarely (default 128; 0 = grow on demand)')
	fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		exit(1)
	}
	if port < 1 || port > 65535 {
		eprintln('invalid port: ${port}')
		exit(1)
	}
	password := if password_flag != '' { password_flag } else { os.getenv('CW_PASSWORD') }
	password_admin := if admin_flag != '' { admin_flag } else { os.getenv('CW_PASSWORD_ADMIN') }
	client_key := if key_flag != '' { key_flag } else { os.getenv('CW_CLIENT_KEY') }

	$if gcboehm ? {
		if heap_mb > 0 {
			C.GC_expand_hp(usize(heap_mb) * 1024 * 1024)
		}
	}
	db := open_db(db_path) or {
		eprintln('cannot open the database ${db_path}: ${err}')
		exit(1)
	}
	mut hub := new_hub(db, client_key) or {
		eprintln('cannot load the database ${db_path}: ${err}')
		exit(1)
	}
	spawn hub.people_loop()
	spawn hub.servers_loop()
	spawn hub.flush_loop()
	spawn hub.profile_loop()

	println('Cube Watch backend v${app_version}')
	println('  database: ${db_path} (${hub.w.spots.len} spots, ${hub.w.kinds.len} kinds)')
	println('  map:      http://localhost:${port}/' + if password == '' {
		'  (no --password: open to everybody)'
	} else {
		'  (password)'
	})
	println('  admin:    http://localhost:${port}/admin' + if password_admin == '' {
		'  (no --password-admin: only from localhost)'
	} else {
		'  (password)'
	})
	println('  clients:  ws://<this host>:${port}${wire.client_path}' + if client_key == '' {
		'  (no --client-key: any client may report)'
	} else {
		'  (key)'
	})
	mut app := &App{
		hub:            hub
		password:       password
		password_admin: password_admin
		db_path:        db_path
	}
	app.serve(host, port) or {
		eprintln('cannot start the server: ${err}')
		exit(1)
	}
}

// ---- helpers ---------------------------------------------------------------------------

fn (mut ctx Context) json_raw(status http.Status, body string) Result {
	ctx.set_status(status)
	ctx.set_header(.cache_control, 'no-store')
	return ctx.send_response_to_client('application/json; charset=utf-8', body)
}

struct ErrorOut {
	error string
}

fn (mut ctx Context) fail(status http.Status, message string) Result {
	return ctx.json_raw(status, json2.encode(ErrorOut{message}))
}

fn (mut ctx Context) ok_json(body string) Result {
	return ctx.json_raw(.ok, body)
}

fn is_loopback(ip string) bool {
	return ip == '::1' || ip.starts_with('127.') || ip.starts_with('::ffff:127.')
}

// is_local checks the socket peer (not spoofable headers). Requests that
// came through a reverse proxy on this machine carry forwarding headers
// and count as remote.
fn (ctx &Context) is_local() bool {
	ip := ctx.conn.peer_ip() or { return false }
	if !is_loopback(ip) {
		return false
	}
	for h in ['X-Forwarded-For', 'X-Real-Ip', 'Forwarded', 'CF-Connecting-IP', 'True-Client-IP'] {
		if v := ctx.req.header.get_custom(h) {
			if v != '' {
				return false
			}
		}
	}
	return true
}

// client_ip identifies the client for the login limiter: the socket peer,
// or the last X-Forwarded-For entry when the peer is a proxy on this machine.
fn (ctx &Context) client_ip() string {
	ip := ctx.conn.peer_ip() or { return '?' }
	if is_loopback(ip) {
		if xff := ctx.req.header.get_custom('X-Forwarded-For') {
			last := xff.all_after_last(',').trim_space()
			if last != '' {
				return last
			}
		}
	}
	return ip
}

fn (mut app App) session_ok(admin bool, token string) bool {
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	exp := if admin { app.admin_sessions[token] or { i64(0) } } else { app.user_sessions[token] or {
			i64(0)} }
	if exp >= now_unix() {
		return true
	}
	if admin {
		app.admin_sessions.delete(token)
	} else {
		app.user_sessions.delete(token)
	}
	return false
}

fn (mut app App) end_session(admin bool, token string) {
	app.mu.lock()
	if admin {
		app.admin_sessions.delete(token)
	} else {
		app.user_sessions.delete(token)
	}
	app.mu.unlock()
}

// user_ok: may this request see the map?
fn (mut app App) user_ok(ctx &Context) bool {
	if app.password == '' {
		return true
	}
	token := ctx.get_cookie(user_cookie) or { return false }
	return app.session_ok(false, token)
}

// admin_denied tells why /admin is refused outright (none = go on to the login).
fn (app &App) admin_denied(ctx &Context) ?string {
	if app.password_admin == '' && !ctx.is_local() {
		return 'without --password-admin the admin panel only works from localhost'
	}
	return none
}

fn (mut app App) admin_ok(ctx &Context) bool {
	if app.admin_denied(ctx) != none {
		return false
	}
	if app.password_admin == '' {
		return true
	}
	token := ctx.get_cookie(admin_cookie) or { return false }
	return app.session_ok(true, token)
}

// admin_guard returns an error response when the request may not use the
// admin API. Changes must carry the X-CW header, which a cross-site form
// cannot set.
fn (mut app App) admin_guard(mut ctx Context) ?Result {
	if denied := app.admin_denied(ctx) {
		return ctx.fail(.forbidden, denied)
	}
	if ctx.req.method == .post && (ctx.req.header.get_custom('X-CW') or { '' }) != '1' {
		return ctx.fail(.forbidden, 'missing X-CW header')
	}
	if !app.admin_ok(ctx) {
		return ctx.fail(.unauthorized, 'login required')
	}
	return none
}

struct LoginIn {
	password string
}

// login checks a password with the brute-force limit; on success it sets the cookie.
fn (mut app App) login(mut ctx Context, expected string, cookie string, admin bool) Result {
	ip := ctx.client_ip()
	now := now_unix()
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	mut fails := app.login_fails[ip] or { LoginFails{} }
	if fails.blocked_until > now {
		return ctx.fail(.too_many_requests, 'too many wrong passwords, try again in ${fails.blocked_until - now} s')
	}
	inp := json2.decode[LoginIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	if expected != '' && !same_secret(inp.password, expected) {
		fails.count++
		if fails.count >= login_max_fails {
			fails = LoginFails{
				blocked_until: now + login_block_sec
			}
			eprintln('[login] ${login_max_fails} wrong passwords from ${ip}: blocked for ${login_block_sec} s')
		}
		app.login_fails[ip] = fails
		if app.login_fails.len > 1000 {
			for k, f in app.login_fails.clone() {
				if f.blocked_until <= now && k != ip {
					app.login_fails.delete(k)
				}
			}
		}
		return ctx.fail(.unauthorized, 'wrong password')
	}
	app.login_fails.delete(ip)
	token := rand.uuid_v4() + rand.uuid_v4()
	if admin {
		app.admin_sessions[token] = now + session_seconds
	} else {
		app.user_sessions[token] = now + session_seconds
	}
	ctx.set_cookie(http.Cookie{
		name:      cookie
		value:     token
		path:      '/'
		http_only: true
		same_site: .same_site_strict_mode
		max_age:   int(session_seconds)
	})
	return ctx.ok_json('{"ok":true}')
}

fn (mut ctx Context) clear_cookie(name string) {
	ctx.set_cookie(http.Cookie{
		name:    name
		value:   ''
		path:    '/'
		max_age: -1
	})
}

// page returns an embedded page; CW_WEB_DIR makes it read web/*.html from
// disk instead, to work on the pages without rebuilding.
fn page(embedded string, name string) string {
	dir := os.getenv('CW_WEB_DIR')
	if dir != '' {
		return os.read_file(os.join_path(dir, name)) or { embedded }
	}
	return embedded
}

// ---- pages ---------------------------------------------------------------------------------

pub fn (mut app App) index(mut ctx Context) Result {
	ctx.set_header(.cache_control, 'no-cache')
	return ctx.html(page(index_html, 'index.html'))
}

pub fn (mut app App) admin_page(mut ctx Context) Result {
	if denied := app.admin_denied(ctx) {
		ctx.set_status(.forbidden)
		return ctx.html('<!doctype html><meta charset="utf-8"><title>403</title><body style="background:#0b0f17;color:#cfd8e6;font:16px system-ui;display:grid;place-items:center;height:100vh;margin:0"><div><h1>403</h1><p>${denied}.</p><p><a style="color:#f5a623" href="/">&larr; map</a></p></div>')
	}
	ctx.set_header(.cache_control, 'no-store')
	return ctx.html(page(admin_html, 'admin.html'))
}

pub fn (mut app App) favicon(mut ctx Context) Result {
	ctx.set_header(.cache_control, 'public, max-age=86400')
	return ctx.send_response_to_client('image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#0b0f17"/><path d="M16 5 27 11v10l-11 6-11-6V11z" fill="none" stroke="#f5a623" stroke-width="2.4" stroke-linejoin="round"/><path d="M5 11l11 6 11-6M16 17v10" fill="none" stroke="#f5a623" stroke-width="2.4" stroke-linejoin="round"/></svg>')
}

pub fn (mut app App) map_img(mut ctx Context, name string) Result {
	if !app.user_ok(ctx) && !app.admin_ok(ctx) {
		return ctx.fail(.unauthorized, 'login required')
	}
	data := map_image(name) or { return ctx.not_found() }
	ctx.set_header(.cache_control, 'public, max-age=86400')
	mime := if name.ends_with('.png') { 'image/png' } else { 'image/jpeg' }
	return ctx.send_response_to_client(mime, data)
}

// ---- map page API -----------------------------------------------------------------------

pub fn (mut app App) api_me(mut ctx Context) Result {
	return ctx.ok_json('{"authed":${app.user_ok(ctx)},"password_set":${app.password != ''},"version":"${app_version}"}')
}

pub fn (mut app App) api_login(mut ctx Context) Result {
	return app.login(mut ctx, app.password, user_cookie, false)
}

pub fn (mut app App) api_logout(mut ctx Context) Result {
	if token := ctx.get_cookie(user_cookie) {
		app.end_session(false, token)
	}
	ctx.clear_cookie(user_cookie)
	return ctx.ok_json('{"ok":true}')
}

// /api/profile?key=<server>:<name> - the cached profile of a character.
pub fn (mut app App) api_profile(mut ctx Context) Result {
	if !app.user_ok(ctx) {
		return ctx.fail(.unauthorized, 'login required')
	}
	key := (ctx.query['key'] or { '' }).to_lower()
	app.hub.mu.lock()
	prof := app.hub.profiles[key] or {
		app.hub.mu.unlock()
		return ctx.fail(.not_found, 'no profile yet')
	}
	app.hub.mu.unlock()
	return ctx.ok_json(json2.encode(prof))
}

// /api/stats?server=<game server id> - numbers for the map's statistics box.
pub fn (mut app App) api_stats(mut ctx Context) Result {
	if !app.user_ok(ctx) {
		return ctx.fail(.unauthorized, 'login required')
	}
	server := (ctx.query['server'] or { '0' }).int()
	app.hub.mu.lock()
	body := app.hub.stats_json(server)
	app.hub.mu.unlock()
	return ctx.ok_json(body)
}

// ---- websockets ---------------------------------------------------------------------------

pub fn (mut app App) ws_view(mut ctx Context) Result {
	if !app.user_ok(ctx) {
		return ctx.fail(.unauthorized, 'login required')
	}
	return ctx.websocket(mut app.hub.wss_view)
}

// Cube Watch clients prove themselves with the key in their first message.
pub fn (mut app App) ws_client(mut ctx Context) Result {
	return ctx.websocket(mut app.hub.wss_client)
}

// ---- admin ----------------------------------------------------------------------------------

pub fn (mut app App) admin_me(mut ctx Context) Result {
	if denied := app.admin_denied(ctx) {
		return ctx.fail(.forbidden, denied)
	}
	return ctx.ok_json('{"authed":${app.admin_ok(ctx)},"password_set":${app.password_admin != ''}}')
}

pub fn (mut app App) admin_login(mut ctx Context) Result {
	if denied := app.admin_denied(ctx) {
		return ctx.fail(.forbidden, denied)
	}
	return app.login(mut ctx, app.password_admin, admin_cookie, true)
}

pub fn (mut app App) admin_logout(mut ctx Context) Result {
	if token := ctx.get_cookie(admin_cookie) {
		app.end_session(true, token)
	}
	ctx.clear_cookie(admin_cookie)
	return ctx.ok_json('{"ok":true}')
}

struct StatusOut {
	now          i64
	started      i64
	version      string
	clients      int
	viewers      int
	people       int
	spots        int
	events       int
	reports      i64
	profiles     int
	db_path      string
	db_size      i64
	password_set bool
	key_set      bool
}

struct SessionOut {
	id      string
	owner   string
	server  int
	name    string
	since   i64
	last    i64
	near_at i64
	near    []wire.NearItem
	map     u32 // the map id the client reports (0 not known yet)
}

// CharacterOut is a character Cube Watch was ever run with, online or not.
struct CharacterOut {
	owner     string // short tag of the installation: the same for one player's characters
	server    int
	name      string
	last_seen i64
	online    bool
	cls       string
	level     int
}

struct OverviewOut {
mut:
	status   StatusOut
	chars    []CharacterOut
	servers  []ServerName
	groups   []world.Group
	kinds    []KindOut
	spots    []SpotOut
	states   []world.State
	people   []PersonOut
	sessions []SessionOut
	maps     []MapDef
}

pub fn (mut app App) admin_overview(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	mut h := app.hub
	clients := h.connected(false)
	viewers := h.connected(true)
	h.mu.lock()
	events := (q(h.db, 'SELECT count(*) FROM events') or { [] })
	mut out := OverviewOut{
		status:  StatusOut{
			now:          now_unix()
			started:      h.started
			version:      app_version
			clients:      clients
			viewers:      viewers
			people:       h.w.people.len
			spots:        h.w.spots.len
			events:       if events.len > 0 { events[0].vals[0].int() } else { 0 }
			reports:      h.reports
			profiles:     h.profiles.len
			db_path:      app.db_path
			db_size:      i64(os.file_size(app.db_path) + os.file_size(app.db_path + '-wal'))
			password_set: app.password != ''
			key_set:      h.client_key != ''
		}
		servers: h.servers_out()
		groups:  h.w.groups.values()
		states:  h.w.states.values()
		maps:    h.maps
	}
	for _, k in h.w.kinds {
		out.kinds << KindOut{k.cat, k.tpl, k.name, k.group_id, k.respawn_sec, k.report}
	}
	for _, s in h.w.spots {
		out.spots << h.spot_out(s)
	}
	for key, p in h.w.people {
		out.people << h.person_out(key, p)
	}
	for install, chars in h.owned {
		for key, name in chars {
			prof := h.profiles[key] or { Profile{} }
			out.chars << CharacterOut{
				owner:     owner_tag(install)
				server:    key.all_before(':').int()
				name:      name
				last_seen: h.char_seen[key]
				online:    key in h.w.people
				cls:       prof.cls
				level:     prof.level
			}
		}
	}
	for sid, s in h.sessions {
		if s.authed {
			out.sessions << SessionOut{sid, owner_tag(s.install), s.server, s.name, s.since, s.last, s.near_at, s.near, s.map}
		}
	}
	h.mu.unlock()
	return ctx.ok_json(json2.encode(out))
}

fn valid_color(c string) bool {
	if c.len != 7 || c[0] != `#` {
		return false
	}
	for ch in c[1..] {
		if !ch.is_hex_digit() {
			return false
		}
	}
	return true
}

pub fn (mut app App) admin_group_save(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[world.Group](ctx.req.data) or {
		return ctx.fail(.bad_request, 'bad request')
	}
	name := inp.name.trim_space()
	if name == '' || !valid_color(inp.color) {
		return ctx.fail(.bad_request, 'a group needs a name and a color like #f5a623')
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	mut id := inp.id
	if id == 0 {
		q(h.db, 'INSERT INTO groups(name,color,sort) VALUES(?,?,?)', name, inp.color,
			inp.sort.str()) or { return ctx.fail(.conflict, 'a group with this name exists') }
		id = int(h.db.last_insert_rowid())
	} else {
		q(h.db, 'UPDATE groups SET name=?, color=?, sort=? WHERE id=?', name, inp.color,
			inp.sort.str(), id.str()) or {
			return ctx.fail(.conflict, 'a group with this name exists')
		}
	}
	h.w.groups[id] = world.Group{
		id:    id
		name:  name
		color: inp.color
		sort:  inp.sort
	}
	h.config_changed()
	return ctx.ok_json('{"ok":true,"id":${id}}')
}

pub fn (mut app App) admin_group_delete(mut ctx Context, id int) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	q(h.db, 'UPDATE kinds SET group_id=0 WHERE group_id=?', id.str()) or {}
	q(h.db, 'DELETE FROM groups WHERE id=?', id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	h.w.groups.delete(id)
	for key, k in h.w.kinds {
		if k.group_id == id {
			h.w.kinds[key] = world.Kind{
				...k
				group_id: 0
			}
		}
	}
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

struct KindIn {
	cat     string
	tpl     u32
	name    string
	group   int
	respawn int // seconds; 0 = estimate
	report  bool
}

pub fn (mut app App) admin_kind_save(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[KindIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	name := inp.name.trim_space()
	if inp.cat !in [world.category_object, world.category_npc] || inp.tpl == 0 || name == ''
		|| inp.respawn < 0 {
		return ctx.fail(.bad_request, 'a kind needs a type (object / npc), a template id and a name')
	}
	k := world.Kind{
		cat:         inp.cat
		tpl:         inp.tpl
		name:        name
		group_id:    inp.group
		respawn_sec: inp.respawn
		report:      inp.report
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	q(h.db, 'INSERT INTO kinds(cat,tpl,name,group_id,respawn_sec,report) VALUES(?,?,?,?,?,?)
		ON CONFLICT(cat,tpl) DO UPDATE SET name=excluded.name, group_id=excluded.group_id, respawn_sec=excluded.respawn_sec, report=excluded.report',
		k.cat, k.tpl.str(), k.name, k.group_id.str(), k.respawn_sec.str(), flag01(k.report)) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	h.w.kinds[k.key()] = k
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

// Deleting a kind also deletes its spots and their history.
pub fn (mut app App) admin_kind_delete(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[KindIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	q(h.db, 'DELETE FROM events WHERE spot_id IN (SELECT id FROM spots WHERE cat=? AND tpl=?)',
		inp.cat, inp.tpl.str()) or { return ctx.fail(.internal_server_error, err.msg()) }
	q(h.db, 'DELETE FROM spots WHERE cat=? AND tpl=?', inp.cat, inp.tpl.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	q(h.db, 'DELETE FROM kinds WHERE cat=? AND tpl=?', inp.cat, inp.tpl.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	for id, s in h.w.spots.clone() {
		if s.cat == inp.cat && s.tpl == inp.tpl {
			h.w.remove_spot(id)
		}
	}
	h.w.kinds.delete('${inp.cat}:${inp.tpl}')
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

struct SpotIn {
	id     int
	label  string
	hidden bool
}

pub fn (mut app App) admin_spot_save(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[SpotIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	mut s := h.w.spots[inp.id] or { return ctx.fail(.not_found, 'no such spot') }
	s.label = inp.label.trim_space()
	s.hidden = inp.hidden
	h.w.spots[inp.id] = s
	save_spot(h.db, s) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

pub fn (mut app App) admin_spot_delete(mut ctx Context, id int) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	q(h.db, 'DELETE FROM events WHERE spot_id=?', id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	q(h.db, 'DELETE FROM spots WHERE id=?', id.str()) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	h.w.remove_spot(id)
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

struct ClientIn {
	id string
}

// Asks one client what is around it; the answer shows up in the overview.
pub fn (mut app App) admin_client_nearby(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[ClientIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	app.hub.mu.lock()
	ok := app.hub.ask_nearby(inp.id)
	app.hub.mu.unlock()
	if !ok {
		return ctx.fail(.not_found, 'that client is not connected any more')
	}
	return ctx.ok_json('{"ok":true}')
}

struct ClientMapIn {
	id   string
	name string
}

struct ClientMapOut {
	ok   bool = true
	map  u32
	name string
}

// The admin says on which map a client's character is right now, and the
// map id that client reports gets that name: a map that exists takes the
// id as one more of its ids, another name makes a new map.
pub fn (mut app App) admin_client_map(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[ClientMapIn](ctx.req.data) or {
		return ctx.fail(.bad_request, 'bad request')
	}
	mut name := inp.name.replace_each(['\r', ' ', '\n', ' ']).trim_space()
	if name == '' || name.len > 60 {
		return ctx.fail(.bad_request, 'a map name of at most 60 characters')
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	ses := h.sessions[inp.id] or {
		return ctx.fail(.not_found, 'that client is not connected any more')
	}
	id := ses.map
	if id == 0 {
		return ctx.fail(.bad_request, 'that client does not know its map id yet - the game tells it when the character changes zone')
	}
	mut names := meta_names(h.db, 'map_names')
	mut target := ''
	for m in h.maps {
		if m.name.to_lower() == name.to_lower() {
			target = m.key
			name = m.name
		}
	}
	for m in h.maps {
		if id !in m.map_ids {
			continue
		}
		if m.key == target {
			return ctx.ok_json(json2.encode(ClientMapOut{ map: id, name: name }))
		}
		if int(id) !in names {
			return ctx.fail(.bad_request, 'map id ${id} is the built-in map "${m.name}" - take it out of that map under Maps first')
		}
	}
	names[int(id)] = name
	meta_set_names(h.db, 'map_names', names) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	maps := load_maps(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.set_maps(maps)
	h.config_changed()
	return ctx.ok_json(json2.encode(ClientMapOut{ map: id, name: name }))
}

struct HistoryResult {
	rows  int
	added int
	spots int
}

// Imports a Cube Watch history file (data\cubes_*.csv: appeared, spawned_in_range,
// x, y, z, taken_by_us, distance[, map]) as sightings of cubes, so that the
// places known before the backend existed are on the map.
pub fn (mut app App) admin_import_history(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	before_spots := h.w.spots.len
	mut rows := 0
	for line in ctx.req.data.split_into_lines() {
		f := line.split(',')
		if f.len < 6 || f[0].trim_space() == 'appeared' {
			continue
		}
		when := time.parse(f[0].trim_space()) or { continue }
		// the file has local times
		ts := when.unix() - time.offset()
		map_id := if f.len > 7 { f[7].trim_space().u32() } else { u32(0) }
		rows++
		h.w.noted(world.Sighting{
			server: 0
			map:    h.canonical_map(map_id)
			cat:    world.category_object
			tpl:    cube_template
			x:      f[2].f64()
			y:      f[3].f64()
			z:      f[4].f64()
		}, ts)
	}
	spots := h.w.take_dirty_spots()
	events := h.w.take_events()
	before := (q(h.db, 'SELECT count(*) FROM events') or { [] })
	save_changes(h.db, spots, events) or { return ctx.fail(.internal_server_error, err.msg()) }
	after := (q(h.db, 'SELECT count(*) FROM events') or { [] })
	added := if before.len > 0 && after.len > 0 {
		after[0].vals[0].int() - before[0].vals[0].int()
	} else {
		0
	}
	// the file may have been imported before: build the counters from what is stored
	people := h.w.people.clone()
	h.w = load_world(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.w.people = people.clone()
	h.config_changed()
	return ctx.ok_json(json2.encode(HistoryResult{rows, added, h.w.spots.len - before_spots}))
}

struct MapIn {
	key     string
	map_ids []u32
	sx      f64
	sy      f64
	ox      f64
	oy      f64
}

// The ids and the calibration of a built-in map; its image is compiled in.
pub fn (mut app App) admin_map_save(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[MapIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	ids := inp.map_ids.filter(it != 0)
	if ids.len == 0 || inp.sx == 0 || inp.sy == 0 {
		return ctx.fail(.bad_request, 'a map needs at least one map id and a scale that is not zero')
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	mut target := MapDef{}
	for m in h.maps {
		if m.image == '' {
			continue
		}
		if m.key == inp.key {
			target = m
			continue
		}
		for id in ids {
			if id in m.map_ids {
				return ctx.fail(.bad_request, 'map id ${id} already belongs to "${m.name}"')
			}
		}
	}
	if target.key == '' {
		return ctx.fail(.not_found, 'no such map')
	}
	// The ids typed here are this map's ids from now on: they leave the
	// admin's maps, and ids that had joined this map by its name are in
	// the list or gone.
	mut names := meta_names(h.db, 'map_names')
	for id, name in names.clone() {
		if u32(id) in ids || name.to_lower() == target.name.to_lower() {
			names.delete(id)
		}
	}
	meta_set_names(h.db, 'map_names', names) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	target.map_ids = ids
	target.sx, target.sy, target.ox, target.oy = inp.sx, inp.sy, inp.ox, inp.oy
	save_map_settings(h.db, target) or { return ctx.fail(.internal_server_error, err.msg()) }
	maps := load_maps(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.set_maps(maps)
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

struct MapDefineIn {
	old  string // the name it had; '' for a new map
	name string
	ids  []u32
}

// A map of the admin's: a name and its map ids. With `old` the map of
// that name is replaced (renamed, other ids); without ids it is deleted.
pub fn (mut app App) admin_map_define(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[MapDefineIn](ctx.req.data) or {
		return ctx.fail(.bad_request, 'bad request')
	}
	name := inp.name.replace_each(['\r', ' ', '\n', ' ']).trim_space()
	old := inp.old.trim_space().to_lower()
	ids := inp.ids.filter(it != 0)
	if ids.len == 0 && old == '' {
		return ctx.fail(.bad_request, 'a map needs at least one map id')
	}
	if ids.len > 0 && (name == '' || name.len > 60) {
		return ctx.fail(.bad_request, 'a map needs a name (at most 60 characters)')
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	mut names := meta_names(h.db, 'map_names')
	for m in h.maps {
		if m.image == '' {
			continue
		}
		if old != '' && m.name.to_lower() == old {
			return ctx.fail(.bad_request, '"${m.name}" is built in')
		}
		for id in ids {
			if id in m.map_ids && int(id) !in names {
				return ctx.fail(.bad_request, 'map id ${id} is the built-in map "${m.name}" - take it out of that map first')
			}
		}
	}
	if old != '' {
		for id, n in names.clone() {
			if n.to_lower() == old {
				names.delete(id)
			}
		}
	}
	for id in ids {
		names[int(id)] = name
	}
	meta_set_names(h.db, 'map_names', names) or {
		return ctx.fail(.internal_server_error, err.msg())
	}
	maps := load_maps(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.set_maps(maps)
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

struct NameIn {
	what string // server | map
	id   int
	name string
}

// A name for a game server (one the official list does not have, or a
// better one) or for a map. An empty name takes the admin's name away.
pub fn (mut app App) admin_name_save(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	inp := json2.decode[NameIn](ctx.req.data) or { return ctx.fail(.bad_request, 'bad request') }
	name := inp.name.replace_each(['\r', ' ', '\n', ' ']).trim_space()
	if inp.id <= 0 || name.len > 60 {
		return ctx.fail(.bad_request, 'an id above zero and a name of at most 60 characters')
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	match inp.what {
		'server' {
			if name == '' {
				h.custom_names.delete(inp.id)
			} else {
				h.custom_names[inp.id] = name
			}
			meta_set_names(h.db, 'server_names_custom', h.custom_names) or {
				return ctx.fail(.internal_server_error, err.msg())
			}
		}
		'map' {
			mut names := meta_names(h.db, 'map_names')
			if name == '' {
				names.delete(inp.id)
			} else {
				names[inp.id] = name
			}
			meta_set_names(h.db, 'map_names', names) or {
				return ctx.fail(.internal_server_error, err.msg())
			}
			maps := load_maps(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
			h.set_maps(maps)
		}
		else {
			return ctx.fail(.bad_request, 'bad request')
		}
	}
	h.config_changed()
	return ctx.ok_json('{"ok":true}')
}

pub fn (mut app App) admin_export(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	mut h := app.hub
	h.mu.lock()
	// What is still waiting in memory belongs into the copy too.
	save_changes(h.db, h.w.take_dirty_spots(), h.w.take_events()) or {}
	data := export_database(h.db) or {
		h.mu.unlock()
		return ctx.fail(.internal_server_error, err.msg())
	}
	h.mu.unlock()
	stamp := time.now().custom_format('YYYYMMDD-HHmm')
	ctx.set_custom_header('Content-Disposition', 'attachment; filename="cubewatch-${stamp}.db"') or {}
	ctx.set_header(.cache_control, 'no-store')
	return ctx.send_response_to_client('application/octet-stream', data)
}

pub fn (mut app App) admin_import(mut ctx Context) Result {
	if res := app.admin_guard(mut ctx) {
		return res
	}
	if ctx.req.data.len < 100 {
		return ctx.fail(.bad_request, 'the file is empty')
	}
	tmp := os.join_path(os.temp_dir(), 'cubewatch_import_${now_unix()}_${rand.u32()}.db')
	os.write_file(tmp, ctx.req.data) or { return ctx.fail(.internal_server_error, err.msg()) }
	defer {
		os.rm(tmp) or {}
		os.rm(tmp + '-wal') or {}
		os.rm(tmp + '-shm') or {}
	}
	mut h := app.hub
	h.mu.lock()
	defer {
		h.mu.unlock()
	}
	save_changes(h.db, h.w.take_dirty_spots(), h.w.take_events()) or {}
	res := merge_database(h.db, tmp) or { return ctx.fail(.bad_request, err.msg()) }
	// The merged history changes counters and states: build the world again.
	people := h.w.people.clone()
	h.w = load_world(h.db) or { return ctx.fail(.internal_server_error, err.msg()) }
	h.w.people = people.clone()
	h.config_changed()
	return ctx.ok_json(json2.encode(res))
}

// route finds the handler of a request.
fn (mut app App) route(mut ctx Context) Result {
	p := ctx.path
	// HEAD is answered like GET, without the body.
	m := if ctx.req.method == .head { http.Method.get } else { ctx.req.method }
	if m == .get && p == '/' {
		return app.index(mut ctx)
	}
	if m == .get && (p == '/admin' || p == '/admin/') {
		return app.admin_page(mut ctx)
	}
	if m == .get && p == '/favicon.ico' {
		return app.favicon(mut ctx)
	}
	if m == .get && p.starts_with('/mapimg/') && p.ends_with('') && p.len > 8 {
		return app.map_img(mut ctx, p[8..p.len - 0])
	}
	if m == .get && p == '/api/me' {
		return app.api_me(mut ctx)
	}
	if m == .post && p == '/api/login' {
		return app.api_login(mut ctx)
	}
	if m == .post && p == '/api/logout' {
		return app.api_logout(mut ctx)
	}
	if m == .get && p == '/api/profile' {
		return app.api_profile(mut ctx)
	}
	if m == .get && p == '/api/stats' {
		return app.api_stats(mut ctx)
	}
	if m == .post && p == '/api/admin/client/nearby' {
		return app.admin_client_nearby(mut ctx)
	}
	if m == .post && p == '/api/admin/client/map' {
		return app.admin_client_map(mut ctx)
	}
	if m == .post && p == '/api/admin/import_history' {
		return app.admin_import_history(mut ctx)
	}
	if m == .get && p == '/ws/view' {
		return app.ws_view(mut ctx)
	}
	if m == .get && p == '/ws/client' {
		return app.ws_client(mut ctx)
	}
	if m == .get && p == '/api/admin/me' {
		return app.admin_me(mut ctx)
	}
	if m == .post && p == '/api/admin/login' {
		return app.admin_login(mut ctx)
	}
	if m == .post && p == '/api/admin/logout' {
		return app.admin_logout(mut ctx)
	}
	if m == .get && p == '/api/admin/overview' {
		return app.admin_overview(mut ctx)
	}
	if m == .post && p == '/api/admin/group/save' {
		return app.admin_group_save(mut ctx)
	}
	if m == .post && p.starts_with('/api/admin/group/') && p.ends_with('/delete') && p.len > 24 {
		return app.admin_group_delete(mut ctx, p[17..p.len - 7].int())
	}
	if m == .post && p == '/api/admin/kind/save' {
		return app.admin_kind_save(mut ctx)
	}
	if m == .post && p == '/api/admin/kind/delete' {
		return app.admin_kind_delete(mut ctx)
	}
	if m == .post && p == '/api/admin/spot/save' {
		return app.admin_spot_save(mut ctx)
	}
	if m == .post && p.starts_with('/api/admin/spot/') && p.ends_with('/delete') && p.len > 23 {
		return app.admin_spot_delete(mut ctx, p[16..p.len - 7].int())
	}
	if m == .post && p == '/api/admin/map/save' {
		return app.admin_map_save(mut ctx)
	}
	if m == .post && p == '/api/admin/map/define' {
		return app.admin_map_define(mut ctx)
	}
	if m == .post && p == '/api/admin/name/save' {
		return app.admin_name_save(mut ctx)
	}
	if m == .get && p == '/api/admin/export' {
		return app.admin_export(mut ctx)
	}
	if m == .post && p == '/api/admin/import' {
		return app.admin_import(mut ctx)
	}
	return ctx.not_found()
}
