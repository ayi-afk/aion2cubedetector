module main

// Antialiased shapes through GDI+ (gdiplus.dll ships with every Windows),
// loaded at runtime like Npcap so the build needs no import library. Plain
// GDI draws jagged circles and needles; callers fall back to it if GDI+ is
// missing.

type FnGdipStartup = fn (&usize, voidptr, voidptr) int

type FnGdipCreateFromHdc = fn (voidptr, &voidptr) int

type FnGdipDeleteGraphics = fn (voidptr) int

type FnGdipSetSmoothingMode = fn (voidptr, int) int

type FnGdipCreateSolidFill = fn (u32, &voidptr) int

type FnGdipDeleteBrush = fn (voidptr) int

type FnGdipCreatePen1 = fn (u32, f32, int, &voidptr) int

type FnGdipDeletePen = fn (voidptr) int

type FnGdipFillPolygon = fn (voidptr, voidptr, voidptr, int, int) int

type FnGdipFillEllipse = fn (voidptr, voidptr, f32, f32, f32, f32) int

type FnGdipDrawEllipse = fn (voidptr, voidptr, f32, f32, f32, f32) int

type FnGdipCreateBitmapFromScan0 = fn (int, int, int, int, voidptr, &voidptr) int

type FnGdipGetImageGraphicsContext = fn (voidptr, &voidptr) int

type FnGdipDisposeImage = fn (voidptr) int

type FnGdipGraphicsClear = fn (voidptr, u32) int

type FnGdipFillRectangle = fn (voidptr, voidptr, f32, f32, f32, f32) int

type FnGdipDrawRectangle = fn (voidptr, voidptr, f32, f32, f32, f32) int

type FnGdipDrawLine = fn (voidptr, voidptr, f32, f32, f32, f32) int

type FnGdipDrawPolygon = fn (voidptr, voidptr, voidptr, int) int

type FnGdipCreateFontFamilyFromName = fn (&u16, voidptr, &voidptr) int

type FnGdipDeleteFontFamily = fn (voidptr) int

type FnGdipCreateFont = fn (voidptr, f32, int, int, &voidptr) int

type FnGdipDeleteFont = fn (voidptr) int

type FnGdipDrawString = fn (voidptr, &u16, int, voidptr, voidptr, voidptr, voidptr) int

type FnGdipMeasureString = fn (voidptr, &u16, int, voidptr, voidptr, voidptr, voidptr, voidptr, voidptr) int

type FnGdipSetTextRenderingHint = fn (voidptr, int) int

type FnGdipTranslateWorldTransform = fn (voidptr, f32, f32, int) int

const gdip_smoothing_antialias = 4
const gdip_unit_pixel = 2
const gdip_fill_alternate = 0
const gdip_format_32bpp_pargb = 0x000E200B
const gdip_font_bold = 1
const gdip_text_antialias = 4 // grayscale: ClearType needs an opaque background

struct GdiplusStartupInput {
	version            u32 = 1
	debug_callback     voidptr
	suppress_bg_thread int
	suppress_ext_codec int
}

struct PointF {
	x f32
	y f32
}

struct Gdip {
	create_from_hdc  FnGdipCreateFromHdc    = unsafe { nil }
	delete_graphics  FnGdipDeleteGraphics   = unsafe { nil }
	set_smoothing    FnGdipSetSmoothingMode = unsafe { nil }
	create_fill      FnGdipCreateSolidFill  = unsafe { nil }
	delete_brush     FnGdipDeleteBrush      = unsafe { nil }
	create_pen       FnGdipCreatePen1       = unsafe { nil }
	delete_pen       FnGdipDeletePen        = unsafe { nil }
	fill_polygon_raw FnGdipFillPolygon      = unsafe { nil }
	fill_ellipse_raw FnGdipFillEllipse      = unsafe { nil }
	draw_ellipse_raw FnGdipDrawEllipse      = unsafe { nil }
	// Off-screen drawing for the per-pixel-alpha overlay window.
	create_bitmap  FnGdipCreateBitmapFromScan0   = unsafe { nil }
	image_graphics FnGdipGetImageGraphicsContext = unsafe { nil }
	dispose_image  FnGdipDisposeImage            = unsafe { nil }
	clear          FnGdipGraphicsClear           = unsafe { nil }
	fill_rect_raw  FnGdipFillRectangle           = unsafe { nil }
	draw_rect_raw  FnGdipDrawRectangle           = unsafe { nil }
	draw_line_raw  FnGdipDrawLine                = unsafe { nil }
	draw_poly_raw  FnGdipDrawPolygon             = unsafe { nil }
	// Text for the overlay labels.
	font_family     FnGdipCreateFontFamilyFromName = unsafe { nil }
	delete_family   FnGdipDeleteFontFamily         = unsafe { nil }
	create_font     FnGdipCreateFont               = unsafe { nil }
	delete_font     FnGdipDeleteFont               = unsafe { nil }
	draw_string_raw FnGdipDrawString               = unsafe { nil }
	measure_raw     FnGdipMeasureString            = unsafe { nil }
	text_hint       FnGdipSetTextRenderingHint     = unsafe { nil }
	translate       FnGdipTranslateWorldTransform  = unsafe { nil }
}

fn load_gdip() ?Gdip {
	names := ['GdiplusStartup', 'GdipCreateFromHDC', 'GdipDeleteGraphics', 'GdipSetSmoothingMode',
		'GdipCreateSolidFill', 'GdipDeleteBrush', 'GdipCreatePen1', 'GdipDeletePen',
		'GdipFillPolygon', 'GdipFillEllipse', 'GdipDrawEllipse', 'GdipCreateBitmapFromScan0',
		'GdipGetImageGraphicsContext', 'GdipDisposeImage', 'GdipGraphicsClear', 'GdipFillRectangle',
		'GdipDrawRectangle', 'GdipDrawLine', 'GdipDrawPolygon', 'GdipCreateFontFamilyFromName',
		'GdipDeleteFontFamily', 'GdipCreateFont', 'GdipDeleteFont', 'GdipDrawString',
		'GdipMeasureString', 'GdipSetTextRenderingHint', 'GdipTranslateWorldTransform']
	mut f := []voidptr{}
	for name in names {
		p := proc_address('gdiplus.dll', name)
		if p == unsafe { nil } {
			return none
		}
		f << p
	}
	startup := FnGdipStartup(f[0])
	token := usize(0)
	input := GdiplusStartupInput{}
	if startup(&token, &input, unsafe { nil }) != 0 {
		return none
	}
	return Gdip{
		create_from_hdc:  FnGdipCreateFromHdc(f[1])
		delete_graphics:  FnGdipDeleteGraphics(f[2])
		set_smoothing:    FnGdipSetSmoothingMode(f[3])
		create_fill:      FnGdipCreateSolidFill(f[4])
		delete_brush:     FnGdipDeleteBrush(f[5])
		create_pen:       FnGdipCreatePen1(f[6])
		delete_pen:       FnGdipDeletePen(f[7])
		fill_polygon_raw: FnGdipFillPolygon(f[8])
		fill_ellipse_raw: FnGdipFillEllipse(f[9])
		draw_ellipse_raw: FnGdipDrawEllipse(f[10])
		create_bitmap:    FnGdipCreateBitmapFromScan0(f[11])
		image_graphics:   FnGdipGetImageGraphicsContext(f[12])
		dispose_image:    FnGdipDisposeImage(f[13])
		clear:            FnGdipGraphicsClear(f[14])
		fill_rect_raw:    FnGdipFillRectangle(f[15])
		draw_rect_raw:    FnGdipDrawRectangle(f[16])
		draw_line_raw:    FnGdipDrawLine(f[17])
		draw_poly_raw:    FnGdipDrawPolygon(f[18])
		font_family:      FnGdipCreateFontFamilyFromName(f[19])
		delete_family:    FnGdipDeleteFontFamily(f[20])
		create_font:      FnGdipCreateFont(f[21])
		delete_font:      FnGdipDeleteFont(f[22])
		draw_string_raw:  FnGdipDrawString(f[23])
		measure_raw:      FnGdipMeasureString(f[24])
		text_hint:        FnGdipSetTextRenderingHint(f[25])
		translate:        FnGdipTranslateWorldTransform(f[26])
	}
}

// argb turns a GDI COLORREF (0x00BBGGRR) into an opaque GDI+ ARGB color.
fn argb(c u32) u32 {
	return 0xff000000 | ((c & 0xff) << 16) | (c & 0xff00) | ((c >> 16) & 0xff)
}

// graphics returns an antialiasing GDI+ surface over `dc`; free it with
// delete_graphics.
fn (g &Gdip) graphics(dc voidptr) ?voidptr {
	gr := unsafe { nil }
	if g.create_from_hdc(dc, &gr) != 0 || gr == unsafe { nil } {
		return none
	}
	g.set_smoothing(gr, gdip_smoothing_antialias)
	return gr
}

fn (g &Gdip) fill_polygon(dc voidptr, pts []PointF, color u32) bool {
	gr := g.graphics(dc) or { return false }
	brush := unsafe { nil }
	g.create_fill(argb(color), &brush)
	g.fill_polygon_raw(gr, brush, pts.data, pts.len, gdip_fill_alternate)
	g.delete_brush(brush)
	g.delete_graphics(gr)
	return true
}

// circle fills a circle and strokes a 1 px edge on it.
fn (g &Gdip) circle(dc voidptr, cx f32, cy f32, r f32, face u32, edge u32) bool {
	gr := g.graphics(dc) or { return false }
	brush := unsafe { nil }
	g.create_fill(argb(face), &brush)
	g.fill_ellipse_raw(gr, brush, cx - r, cy - r, 2 * r, 2 * r)
	g.delete_brush(brush)
	pen := unsafe { nil }
	g.create_pen(argb(edge), 1, gdip_unit_pixel, &pen)
	g.draw_ellipse_raw(gr, pen, cx - r + 0.5, cy - r + 0.5, 2 * r - 1, 2 * r - 1)
	g.delete_pen(pen)
	g.delete_graphics(gr)
	return true
}

// Canvas draws on a GDI+ graphics with ARGB colors (alpha included).
struct Canvas {
	g  &Gdip
	gr voidptr
}

// with_alpha turns a COLORREF into ARGB with the given alpha (0-255).
fn with_alpha(c u32, alpha int) u32 {
	return (u32(alpha) << 24) | (argb(c) & 0x00ffffff)
}

fn (c Canvas) fill_circle(x f32, y f32, r f32, color u32) {
	brush := unsafe { nil }
	c.g.create_fill(color, &brush)
	c.g.fill_ellipse_raw(c.gr, brush, x - r, y - r, 2 * r, 2 * r)
	c.g.delete_brush(brush)
}

fn (c Canvas) stroke_circle(x f32, y f32, r f32, width f32, color u32) {
	pen := unsafe { nil }
	c.g.create_pen(color, width, gdip_unit_pixel, &pen)
	c.g.draw_ellipse_raw(c.gr, pen, x - r, y - r, 2 * r, 2 * r)
	c.g.delete_pen(pen)
}

fn (c Canvas) fill_polygon(pts []PointF, color u32) {
	brush := unsafe { nil }
	c.g.create_fill(color, &brush)
	c.g.fill_polygon_raw(c.gr, brush, pts.data, pts.len, gdip_fill_alternate)
	c.g.delete_brush(brush)
}

fn (c Canvas) stroke_polygon(pts []PointF, width f32, color u32) {
	pen := unsafe { nil }
	c.g.create_pen(color, width, gdip_unit_pixel, &pen)
	c.g.draw_poly_raw(c.gr, pen, pts.data, pts.len)
	c.g.delete_pen(pen)
}

fn (c Canvas) fill_rect(x f32, y f32, w f32, h f32, color u32) {
	brush := unsafe { nil }
	c.g.create_fill(color, &brush)
	c.g.fill_rect_raw(c.gr, brush, x, y, w, h)
	c.g.delete_brush(brush)
}

fn (c Canvas) stroke_rect(x f32, y f32, w f32, h f32, width f32, color u32) {
	pen := unsafe { nil }
	c.g.create_pen(color, width, gdip_unit_pixel, &pen)
	c.g.draw_rect_raw(c.gr, pen, x, y, w, h)
	c.g.delete_pen(pen)
}

fn (c Canvas) line(x1 f32, y1 f32, x2 f32, y2 f32, width f32, color u32) {
	pen := unsafe { nil }
	c.g.create_pen(color, width, gdip_unit_pixel, &pen)
	c.g.draw_line_raw(c.gr, pen, x1, y1, x2, y2)
	c.g.delete_pen(pen)
}

struct RectF {
	x f32
	y f32
	w f32
	h f32
}

// GdipFont is a bold pixel-sized font; release it with free_font().
struct GdipFont {
	family voidptr
	font   voidptr
}

fn (c Canvas) new_font(name string, px f32) ?GdipFont {
	return c.new_font_style(name, px, gdip_font_bold)
}

// new_font_style: style 0 = regular, gdip_font_bold = bold.
fn (c Canvas) new_font_style(name string, px f32, style int) ?GdipFont {
	family := unsafe { nil }
	if c.g.font_family(name.to_wide(), unsafe { nil }, &family) != 0 || family == unsafe { nil } {
		return none
	}
	font := unsafe { nil }
	if c.g.create_font(family, px, style, gdip_unit_pixel, &font) != 0
		|| font == unsafe { nil } {
		c.g.delete_family(family)
		return none
	}
	c.g.text_hint(c.gr, gdip_text_antialias)
	return GdipFont{family, font}
}

fn (c Canvas) free_font(f GdipFont) {
	c.g.delete_font(f.font)
	c.g.delete_family(f.family)
}

fn (c Canvas) text_size(text string, f GdipFont) (f32, f32) {
	layout := RectF{0, 0, 10000, 10000}
	box := RectF{}
	c.g.measure_raw(c.gr, text.to_wide(), -1, f.font, &layout, unsafe { nil }, &box, unsafe { nil },
		unsafe { nil })
	return box.w, box.h
}

// outlined_text draws `text` with its top-left at (x, y) and a dark rim so
// it reads on light and dark map areas alike.
fn (c Canvas) outlined_text(x f32, y f32, text string, f GdipFont, color u32) {
	c.outlined_text_rim(x, y, text, f, color, 0xe0000000)
}

// outlined_text_rim: outlined_text with its own rim color (ARGB).
fn (c Canvas) outlined_text_rim(x f32, y f32, text string, f GdipFont, color u32, rim u32) {
	wide := text.to_wide()
	shadow := unsafe { nil }
	c.g.create_fill(rim, &shadow)
	for o in [[f32(-1), 0], [f32(1), 0], [f32(0), -1], [f32(0), 1],
		[f32(1), 1]] {
		rc := RectF{x + o[0], y + o[1], 10000, 10000}
		c.g.draw_string_raw(c.gr, wide, -1, f.font, &rc, unsafe { nil }, shadow)
	}
	c.g.delete_brush(shadow)
	brush := unsafe { nil }
	c.g.create_fill(color, &brush)
	rc := RectF{x, y, 10000, 10000}
	c.g.draw_string_raw(c.gr, wide, -1, f.font, &rc, unsafe { nil }, brush)
	c.g.delete_brush(brush)
}
