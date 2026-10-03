module proto

import math

// Compass maps world X/Y offsets to minimap directions.
//
// The packets do not say where the minimap's north is, so it can be
// calibrated by the user (walk "up" on the minimap). Only the north
// direction is needed: Unreal's world is left-handed with Z up, so seen
// from above east is always 90 degrees clockwise from north, the same way
// the minimap shows it.
pub struct Compass {
pub:
	north_deg f64 // world direction of map north: atan2(y, x) in degrees
}

// Measured in AION 2 by walking on the minimap: north is world -Y, east +X.
pub const default_north_deg = 270.0

// Walks closer than this to a world axis are snapped onto it; zone maps
// are axis-aligned and nobody walks perfectly straight.
const snap_tolerance_deg = 20.0

const compass_points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']
const compass_names = ['North', 'North-East', 'East', 'South-East', 'South', 'South-West', 'West',
	'North-West']

// bearing returns the direction of the world offset (dx, dy) in degrees
// clockwise from map north, in [0, 360).
pub fn (c Compass) bearing(dx f64, dy f64) f64 {
	a := math.radians(c.north_deg)
	nx, ny := math.cos(a), math.sin(a)
	north := dx * nx + dy * ny
	east := -dx * ny + dy * nx
	return normalize_deg(math.degrees(math.atan2(east, north)))
}

// north_from_walk turns a walk the user made towards map north into the
// north direction, snapped to the nearest world axis when close to one.
pub fn north_from_walk(dx f64, dy f64) f64 {
	deg := normalize_deg(math.degrees(math.atan2(dy, dx)))
	axis := math.round(deg / 90.0) * 90.0
	if math.abs(deg - axis) <= snap_tolerance_deg {
		return normalize_deg(axis)
	}
	return deg
}

pub fn normalize_deg(d f64) f64 {
	mut r := math.fmod(d, 360.0)
	if r < 0 {
		r += 360.0
	}
	// Avoid returning 360 for tiny negative inputs.
	return if r >= 360.0 { 0.0 } else { r }
}

// point_index maps a bearing to one of 8 compass points (0 = N, 2 = E).
pub fn point_index(bearing f64) int {
	return int(math.round(bearing / 45.0)) % 8
}

pub fn point_short(bearing f64) string {
	return compass_points[point_index(bearing)]
}

pub fn point_name(bearing f64) string {
	return compass_names[point_index(bearing)]
}
