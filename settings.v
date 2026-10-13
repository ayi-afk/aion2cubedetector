module main

import json
import os
import proto
import rand

enum SoundMode {
	windows
	melody
	custom
	off
}

struct Settings {
mut:
	opacity       int = 100
	topmost       bool
	close_to_tray bool      = true
	sound_mode    SoundMode = .windows
	sound_file    string
	adapter       string
	port          int = proto.default_port
	// World direction of minimap north (degrees, see proto.Compass) and
	// whether the user calibrated it.
	north_deg        f64 = proto.default_north_deg
	north_calibrated bool
	// 1 = north_deg default is the measured AION 2 north (older files used +X).
	compass_version int
	// Cubes farther than this (planar world units) are left off the compass; 0 = no limit.
	compass_range int = default_compass_range
	// Map overlay over the game's minimap: game UI proportion (%), world units
	// across the minimap, marker opacity (%) and a moved position as fractions
	// of the screen (width 0 = default spot for the UI proportion).
	overlay         bool
	overlay_ui_pct  int = 100
	overlay_zoom    int = default_overlay_zoom
	overlay_opacity int = 100
	overlay_x       f64
	overlay_y       f64
	overlay_w       f64
	overlay_h       f64
	// Overlay extras: your X / Y / Z above the minimap, the freshness ring and
	// its radius (1 = default, +1 px per step), history dots from data/cubes_*.csv.
	overlay_xyz       bool   = true
	overlay_ring      bool   = true
	overlay_ring_size int    = ring_size_max // ring radius, 100 = default = largest
	overlay_xyz_alpha int    = 60            // % opacity of the X / Y / Z line
	xyz_order         string = 'XYZ'         // axis order of the X / Y / Z line
	overlay_history   bool
	// Second overlay, over the game's large see-through map (overlay2.v):
	// world units across it, opacity (%), position as fractions of the screen
	// (width 0 = the default spot) and what it shows from the backend.
	overlay2         bool
	overlay2_zoom    int = default_overlay2_zoom
	overlay2_opacity int = 100
	overlay2_x       f64
	overlay2_y       f64
	overlay2_w       f64
	overlay2_h       f64
	overlay2_history bool = true
	overlay2_players bool = true
	// The character last seen logging in (name and game server id), for the
	// backend; the game only says it when the character enters a zone.
	character        string
	character_server int
	// Random id made on the first run. The backend uses it to tell that
	// several characters are played from the same installation.
	install_id string
	// Cubes older than this many minutes leave the list (0 = never).
	auto_clear_minutes int = 20
	// Compact view: only position and compass; it keeps its own window size.
	theme          string = theme_system // system / light / dark
	compact        bool
	compact_width  int
	compact_height int
	x              int = -1
	y              int = -1
	width          int
	height         int
}

fn settings_dir() string {
	return os.join_path(os.config_dir() or { os.home_dir() }, 'CubeWatch')
}

fn settings_path() string {
	return os.join_path(settings_dir(), 'settings.json')
}

fn load_settings() Settings {
	raw := os.read_file(settings_path()) or { return Settings{
		compass_version: 1
	} }
	mut s := json.decode(Settings, raw) or {
		eprintln('Ignoring unreadable settings file: ${err}')
		return Settings{
			compass_version: 1
		}
	}
	s.opacity = clamp(s.opacity, 20, 100)
	if s.port <= 0 || s.port > 65535 {
		s.port = proto.default_port
	}
	if s.compass_version < 1 {
		// Files from before the measured default kept north = +X unless calibrated.
		if !s.north_calibrated {
			s.north_deg = proto.default_north_deg
		}
		s.compass_version = 1
	}
	if s.overlay_ui_pct !in ui_proportion_pcts {
		s.overlay_ui_pct = 100
	}
	if s.overlay_zoom < overlay_zoom_min || s.overlay_zoom > overlay_zoom_max {
		s.overlay_zoom = default_overlay_zoom
	}
	if s.overlay_opacity !in overlay_opacities {
		s.overlay_opacity = 100
	}
	if s.overlay2_zoom < overlay2_zoom_min || s.overlay2_zoom > overlay2_zoom_max {
		s.overlay2_zoom = default_overlay2_zoom
	}
	if s.overlay2_opacity !in overlay_opacities {
		s.overlay2_opacity = 100
	}
	s.overlay_ring_size = clamp(s.overlay_ring_size, 1, ring_size_max)
	s.overlay_xyz_alpha = clamp(s.overlay_xyz_alpha, 10, 100)
	if s.xyz_order !in xyz_orders {
		s.xyz_order = 'XYZ'
	}
	s.auto_clear_minutes = clamp(s.auto_clear_minutes, 0, 60)
	if s.compass_range !in compass_ranges {
		s.compass_range = default_compass_range
	}
	return s
}

// new_install_id makes the id of an installation: 16 random hex digits.
fn new_install_id() string {
	return rand.hex(16)
}

fn save_settings(s Settings) ! {
	os.mkdir_all(settings_dir())!
	os.write_file(settings_path(), json.encode_pretty(s))!
}

fn clamp(v int, lo int, hi int) int {
	return if v < lo {
		lo
	} else if v > hi {
		hi
	} else {
		v
	}
}
