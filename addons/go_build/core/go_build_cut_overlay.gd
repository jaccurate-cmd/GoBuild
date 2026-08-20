## Draws the interactive cut tool's preview into the 3D viewport overlay.
##
## Consumes the screen-space dictionary produced by
## [method GoBuildCutController.overlay_data]: a marker on each cut point, a
## dashed rubber-band line between them, and the status line naming the step the
## tool is waiting on.
##
## The line turns red when the pending cut would be rejected, which is the same
## test the commit uses — so a red line always means "this click will do
## nothing".
@tool
class_name CutOverlay
extends RefCounted

const _VALID_COLOR: Color   = Color(0.45, 1.0, 0.6, 0.95)
const _INVALID_COLOR: Color = Color(1.0, 0.45, 0.4, 0.95)
const _ANCHOR_COLOR: Color  = Color(1.0, 0.9, 0.45, 0.95)
const _TEXT_COLOR: Color    = Color(0.65, 1.0, 0.75, 0.9)
const _SHADOW_COLOR: Color  = Color(0.0, 0.0, 0.0, 0.55)

const _MARKER_RADIUS: float = 5.0
const _LINE_WIDTH: float    = 2.0
const _DASH_LENGTH: float   = 6.0
const _MARGIN: float        = 8.0
const _FONT_SIZE: int       = 12


## Draw the preview described by [param data] onto [param overlay].
## A empty [param data] draws nothing, so callers can pass the controller's
## output through unconditionally.
static func draw(overlay: Control, data: Dictionary) -> void:
	if data.is_empty():
		return
	var valid: bool = data.get("valid", true)
	var color: Color = _VALID_COLOR if valid else _INVALID_COLOR
	var has_anchor: bool = data.get("has_anchor", false)
	var has_cursor: bool = data.get("has_cursor", false)
	var anchor: Vector2 = data.get("anchor", Vector2.ZERO)
	var cursor: Vector2 = data.get("cursor", Vector2.ZERO)

	if has_anchor and has_cursor:
		overlay.draw_dashed_line(anchor, cursor, color, _LINE_WIDTH, _DASH_LENGTH)
	if has_anchor:
		_draw_marker(overlay, anchor, _ANCHOR_COLOR)
	if has_cursor:
		_draw_marker(overlay, cursor, color)

	_draw_hint(overlay, data.get("hint", ""))


## An open diamond reads clearly on top of an edge without hiding the geometry
## underneath it, unlike a filled dot.
static func _draw_marker(overlay: Control, at: Vector2, color: Color) -> void:
	var r: float = _MARKER_RADIUS
	var points := PackedVector2Array([
		at + Vector2(0.0, -r),
		at + Vector2(r, 0.0),
		at + Vector2(0.0, r),
		at + Vector2(-r, 0.0),
		at + Vector2(0.0, -r),
	])
	overlay.draw_polyline(points, color, 2.0)


## Status line, in the same bottom-left slot the shape-draw tool uses — the two
## tools are mutually exclusive so they never compete for it.
static func _draw_hint(overlay: Control, hint: String) -> void:
	if hint.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	var pos := Vector2(_MARGIN, overlay.size.y - _MARGIN - 36.0)
	overlay.draw_string(font, pos + Vector2(1.0, 1.0), hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _FONT_SIZE, _SHADOW_COLOR)
	overlay.draw_string(font, pos, hint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _FONT_SIZE, _TEXT_COLOR)
