module main

import json
import net.http
import net.urllib
import time

// Character profiles come from the official AION 2 web API (the one the
// game's own site uses): class, level, combat power, item level, weapon,
// Daevanion boards, god stats and stigmas. One compact document per
// character is kept in memory and in the database: read when the character
// connects (unless a fresh copy is there already) and again every half
// hour while it is online.

const api_base = 'https://aion2.plaync.com'
const search_base = 'https://api-search.plaync.com/aion2global/search/v2/character'
const api_lang = 'en-US'
const user_agent = 'cubewatch-server/1.0'

// A profile is fetched again when it is older than this (seconds).
const profile_ttl = i64(30 * 60)
// The regions of the global game, for characters whose server is not known.
const api_regions = ['eu', 'nae', 'naw', 'la', 'as']
// How many profiles stay in memory; the oldest are dropped first.
const max_profiles = 1000

struct ProfileWeapon {
pub mut:
	name        string
	grade       string
	enchant     int
	max_enchant int
	exceed      int
	attack      string
}

struct ProfileBoard {
	n string // board name
	o int    // open nodes
	t int    // all nodes
}

struct ProfileNamed {
	n string
	v int
}

struct Profile {
pub mut:
	server      int
	name        string
	server_name string
	cls         string
	race        string
	level       int
	cp          i64
	item_level  int
	portrait    string
	weapon      ProfileWeapon
	boards      []ProfileBoard
	gods        []ProfileNamed
	stigmas     []ProfileNamed
	fetched_at  i64
}

// region_of maps a global server id (e.g. 2304) to its region; the 2nd digit is the region.
fn region_of(server_id int) string {
	s := server_id.str()
	if s.len != 4 {
		return 'eu'
	}
	return match s[1] {
		`1` { 'nae' }
		`2` { 'naw' }
		`4` { 'la' }
		`5` { 'as' }
		else { 'eu' }
	}
}

struct ApiServer {
	server_id   int    @[json: 'serverId']
	server_name string @[json: 'serverName']
}

struct ApiServerList {
	server_list []ApiServer @[json: 'serverList']
}

// fetch_server_names asks the official API for the game servers of every
// region: id -> name.
fn fetch_server_names() map[int]string {
	mut names := map[int]string{}
	for region in api_regions {
		body := api_get('${api_base}/en-us/api/gameinfo/servers?lang=${api_lang}&region=${region}') or {
			continue
		}
		list := json.decode(ApiServerList, body) or { continue }
		for s in list.server_list {
			if s.server_id > 0 && s.server_name != '' {
				names[s.server_id] = s.server_name
			}
		}
		time.sleep(300 * time.millisecond)
	}
	return names
}

struct ApiSearchHit {
	character_id string @[json: 'characterId']
	name         string
	level        int
	server_id    int @[json: 'serverId']
}

struct ApiSearch {
	list []ApiSearchHit
}

struct ApiProfile {
	character_level int    @[json: 'characterLevel']
	character_name  string @[json: 'characterName']
	class_name      string @[json: 'className']
	race_name       string @[json: 'raceName']
	combat_power    i64    @[json: 'combatPower']
	profile_image   string @[json: 'profileImage']
	server_name     string @[json: 'serverName']
}

struct ApiStat {
	name  string
	typ   string @[json: 'type']
	value int
}

struct ApiStatWrap {
	stat_list []ApiStat @[json: 'statList']
}

struct ApiBoard {
	name             string
	open_node_count  int @[json: 'openNodeCount']
	total_node_count int @[json: 'totalNodeCount']
}

struct ApiDaevanion {
	board_list []ApiBoard @[json: 'boardList']
}

struct ApiInfo {
	profile   ApiProfile
	stat      ApiStatWrap
	daevanion ApiDaevanion
}

struct ApiEquip {
	id            i64
	name          string
	grade         string
	enchant_level int    @[json: 'enchantLevel']
	exceed_level  int    @[json: 'exceedLevel']
	slot_pos      int    @[json: 'slotPos']
	slot_pos_name string @[json: 'slotPosName']
}

struct ApiEquipWrap {
	equipment_list []ApiEquip @[json: 'equipmentList']
}

struct ApiSkill {
	category    string
	name        string
	skill_level int @[json: 'skillLevel']
}

struct ApiSkillWrap {
	skill_list []ApiSkill @[json: 'skillList']
}

struct ApiEquipment {
	equipment ApiEquipWrap
	skill     ApiSkillWrap
}

struct ApiItemStat {
	id    string
	value string
	extra string
}

struct ApiItem {
	max_enchant_level int           @[json: 'maxEnchantLevel']
	main_stats        []ApiItemStat @[json: 'mainStats']
}

const god_types = ['justice', 'freedom', 'illusion', 'life', 'time', 'destruction', 'death', 'wisdom',
	'destiny', 'space']

fn api_get(url string) !string {
	mut last_err := ''
	for attempt in 0 .. 2 {
		if attempt > 0 {
			time.sleep(2 * time.second)
		}
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, user_agent)
		req.add_header(.accept, 'application/json')
		req.read_timeout = 20 * time.second
		req.write_timeout = 20 * time.second
		resp := req.do() or {
			last_err = err.msg()
			continue
		}
		if resp.status_code == 200 {
			return resp.body
		}
		last_err = 'HTTP ${resp.status_code}'
		if resp.status_code != 429 && resp.status_code < 500 {
			break
		}
	}
	return error(last_err)
}

fn strip_tags(s string) string {
	mut out := []u8{cap: s.len}
	mut in_tag := false
	for c in s {
		if c == `<` {
			in_tag = true
		} else if c == `>` {
			in_tag = false
		} else if !in_tag {
			out << c
		}
	}
	return out.bytestr()
}

// find_character searches one region for the exact name; `server` 0 = any
// server of that region.
fn find_character(region string, server int, name string) ![]ApiSearchHit {
	sid := if server > 0 { server.str() } else { '' }
	found := api_get('${search_base}?keyword=${urllib.query_escape(name)}&page=1&size=30&localeInfo=${api_lang}&region=${region}&serverId=${sid}')!
	hits := json.decode(ApiSearch, found)!
	return hits.list.filter(strip_tags(it.name).to_lower() == name.to_lower()
		&& (server <= 0 || it.server_id == server))
}

// fetch_profile looks the character up by name and reads its public
// profile. When the client does not know its game server yet (`server_in`
// 0) every region is searched; of several characters with that name the
// one on `prefer` (the server most of the other players are on) wins, else
// the one with the highest level.
//
// `unlisted` is a game server id the client reports that the official list
// does not have (3304 in the Abyss, for a character of 2304): the second
// digit is the region and the last two are the same as in the ids of the
// character's own server, so only that region is searched and a server
// with the same last digits wins.
fn fetch_profile(server_in int, name string, prefer int, unlisted int) !Profile {
	mut hits := []ApiSearchHit{}
	if server_in > 0 {
		hits = find_character(region_of(server_in), server_in, name)!
	} else {
		for region in api_regions {
			if unlisted > 0 && region != region_of(unlisted) {
				continue
			}
			hits << find_character(region, 0, name) or { continue }
			time.sleep(300 * time.millisecond)
		}
		hits.sort_with_compare(fn [prefer, unlisted] (a &ApiSearchHit, b &ApiSearchHit) int {
			if unlisted > 0
				&& (a.server_id % 100 == unlisted % 100) != (b.server_id % 100 == unlisted % 100) {
				return if a.server_id % 100 == unlisted % 100 { -1 } else { 1 }
			}
			if (a.server_id == prefer) != (b.server_id == prefer) {
				return if a.server_id == prefer { -1 } else { 1 }
			}
			return b.level - a.level
		})
	}
	if hits.len == 0 {
		return error('character not found')
	}
	server := hits[0].server_id
	region := region_of(server)
	character_id := urllib.query_unescape(hits[0].character_id) or { hits[0].character_id }
	query := 'lang=${api_lang}&characterId=${urllib.query_escape(character_id)}&serverId=${server}&region=${region}'
	time.sleep(400 * time.millisecond)
	info_body := api_get('${api_base}/api/character/info?${query}')!
	info := json.decode(ApiInfo, info_body)!
	if info.profile.character_name == '' {
		return error('empty profile')
	}
	time.sleep(400 * time.millisecond)
	eq_body := api_get('${api_base}/api/character/equipment?${query}')!
	eq := json.decode(ApiEquipment, eq_body)!

	mut p := Profile{
		server:      server
		name:        info.profile.character_name
		server_name: info.profile.server_name
		cls:         info.profile.class_name
		race:        info.profile.race_name
		level:       info.profile.character_level
		cp:          info.profile.combat_power
		portrait:    info.profile.profile_image
		fetched_at:  now_unix()
	}
	for st in info.stat.stat_list {
		if st.typ == 'ItemLevel' {
			p.item_level = st.value
		} else if st.typ.to_lower() in god_types {
			// "Justice [Nezekan]"
			p.gods << ProfileNamed{st.name, st.value}
		}
	}
	for b in info.daevanion.board_list {
		p.boards << ProfileBoard{b.name, b.open_node_count, b.total_node_count}
	}
	for sk in eq.skill.skill_list {
		if sk.category == 'Dp' && sk.skill_level > 0 { // Dp = stigma skills
			p.stigmas << ProfileNamed{sk.name, sk.skill_level}
		}
	}
	p.stigmas.sort(a.v > b.v)
	for it in eq.equipment.equipment_list {
		if it.slot_pos_name != 'MainHand' && it.slot_pos != 1 {
			continue
		}
		p.weapon = ProfileWeapon{
			name:    it.name
			grade:   it.grade
			enchant: it.enchant_level
			exceed:  it.exceed_level
		}
		time.sleep(400 * time.millisecond)
		body := api_get('${api_base}/api/character/equipment/item?id=${it.id}&enchantLevel=${it.enchant_level}&${query}&slotPos=${it.slot_pos}') or {
			''
		}
		if item := json.decode(ApiItem, body) {
			p.weapon.max_enchant = item.max_enchant_level
			for ms in item.main_stats {
				if ms.id == 'WeaponFixingDamage' {
					p.weapon.attack = if ms.extra != '' && ms.extra != '0' {
						'${ms.value} (+${ms.extra})'
					} else {
						ms.value
					}
				}
			}
		}
		break
	}
	return p
}
