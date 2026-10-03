module proto

import math

fn test_bearing_default_north_is_plus_x() {
	c := Compass{}
	assert math.abs(c.bearing(100, 0)) < 1e-9
	assert math.abs(c.bearing(0, 100) - 90) < 1e-9
	assert math.abs(c.bearing(-100, 0) - 180) < 1e-9
	assert math.abs(c.bearing(0, -100) - 270) < 1e-9
	assert point_short(c.bearing(100, 100)) == 'NE'
	assert point_short(c.bearing(-100, -100)) == 'SW'
}

fn test_bearing_rotated_north() {
	// North = -Y: east must be 90 degrees clockwise, i.e. +X.
	c := Compass{
		north_deg: 270
	}
	assert point_short(c.bearing(0, -50)) == 'N'
	assert point_short(c.bearing(50, 0)) == 'E'
	assert point_short(c.bearing(0, 50)) == 'S'
	assert point_short(c.bearing(-50, 0)) == 'W'
}

fn test_default_matches_aion_map() {
	// Walks measured in game: up on the minimap, then right.
	c := Compass{
		north_deg: default_north_deg
	}
	north_dx, north_dy := -142718.0 - -142618.0, -121027.0 - -119363.0
	east_dx, east_dy := -137538.0 - -142718.0, -119965.0 - -121027.0
	assert point_short(c.bearing(north_dx, north_dy)) == 'N'
	assert point_short(c.bearing(east_dx, east_dy)) == 'E'
	assert point_short(c.bearing(-north_dx, -north_dy)) == 'S'
	assert point_short(c.bearing(-east_dx, -east_dy)) == 'W'
	// Calibrating with the same north walk gives the default.
	assert north_from_walk(north_dx, north_dy) == default_north_deg
}

fn test_north_from_walk_snaps_to_axis() {
	assert north_from_walk(1000, 50) == 0 // slightly off +X
	assert north_from_walk(-30, -900) == 270 // -Y
	assert north_from_walk(-800, 100) == 180
	assert north_from_walk(100, 1000) == 90
	// Clearly diagonal walks are kept as measured.
	assert math.abs(north_from_walk(1000, 1000) - 45) < 1e-9
}

fn test_calibration_round_trip() {
	// Walking straight to map north must read as N afterwards.
	walk_dx, walk_dy := -40.0, -1200.0
	c := Compass{
		north_deg: north_from_walk(walk_dx, walk_dy)
	}
	assert point_short(c.bearing(walk_dx, walk_dy)) == 'N'
}

fn test_point_boundaries() {
	assert point_short(0) == 'N'
	assert point_short(22.4) == 'N'
	assert point_short(22.6) == 'NE'
	assert point_short(337.6) == 'N'
	assert point_name(270) == 'West'
	assert normalize_deg(-90) == 270
	assert normalize_deg(450) == 90
}
