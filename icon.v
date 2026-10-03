module main

const icon_size = 32

// make_cube_icon renders a small isometric cube as the window/tray icon so
// the app needs no resource file.
fn make_cube_icon() voidptr {
	header := BitmapInfoHeader{
		size:      u32(sizeof(BitmapInfoHeader))
		width:     icon_size
		height:    -icon_size // top-down rows
		planes:    1
		bit_count: 32
	}
	mut bits := unsafe { nil }
	screen := C.GetDC(unsafe { nil })
	color := C.CreateDIBSection(screen, &header, 0, voidptr(&bits), unsafe { nil }, 0)
	C.ReleaseDC(unsafe { nil }, screen)
	if color == unsafe { nil } || bits == unsafe { nil } {
		return C.LoadIconW(unsafe { nil }, idi_application)
	}
	pixels := unsafe { &u32(bits) }
	// Hexagon outline of the cube and the shared centre vertex.
	top, ur, lr := [16.0, 1.5], [29.5, 8.5], [29.5, 23.5]
	bottom, ll, ul := [16.0, 30.5], [2.5, 23.5], [2.5, 8.5]
	center := [16.0, 15.5]
	faces := [
		[top, ur, center, ul], // top face, lightest
		[ul, center, bottom, ll], // left face
		[center, ur, lr, bottom], // right face, darkest
	]
	shades := [u32(0xFFFFD45C), 0xFFE0A21E, 0xFFA8700C]
	for y in 0 .. icon_size {
		for x in 0 .. icon_size {
			px, py := f64(x) + 0.5, f64(y) + 0.5
			mut argb := u32(0)
			for i, face in faces {
				if inside_convex(face, px, py) {
					argb = shades[i]
					break
				}
			}
			unsafe {
				pixels[y * icon_size + x] = argb
			}
		}
	}
	mask_bits := []u8{len: icon_size * icon_size / 8}
	mask := C.CreateBitmap(icon_size, icon_size, 1, 1, &mask_bits[0])
	info := IconInfo{
		is_icon: 1
		mask:    mask
		color:   color
	}
	icon := C.CreateIconIndirect(&info)
	C.DeleteObject(mask)
	C.DeleteObject(color)
	if icon == unsafe { nil } {
		return C.LoadIconW(unsafe { nil }, idi_application)
	}
	return icon
}

// inside_convex tests a point against a clockwise (screen coordinates)
// convex polygon.
fn inside_convex(poly [][]f64, x f64, y f64) bool {
	for i in 0 .. poly.len {
		a := poly[i]
		b := poly[(i + 1) % poly.len]
		cross := (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])
		if cross < 0 {
			return false
		}
	}
	return true
}
