## Interactive cut tool — draw a line from one edge of a face to another.
##
## Modelled on the Cut tool in s&box's Hammer.  Click a point on an edge to
## anchor the cut, then click a point on another edge of the same face; the face
## is split along the line between them by [CutOperation].  The tool stays armed
## after each cut so a run of cuts can be made without re-arming, and Escape
## steps back out (first dropping the anchor, then leaving the tool).
##
## Both cut points snap onto an edge endpoint when the cursor comes within
## [constant _VERTEX_SNAP_PX] of it, and holding Ctrl quantises the position to
## quarter steps along the edge.
##
## The controller owns no scene-tree nodes — the preview is a 2D overlay drawn
## by [CutOverlay] — so there is no ghost geometry to clean up if the editor
## pulls the rug out from under it.
##
## Owned by [GoBuildPlugin]; armed by the Cut button in [GoBuildEdgeDrawer] or
## the K shortcut.  The plugin routes viewport input here ahead of
## [SelectionInputController] so clicking does not disturb the selection.
@tool
class_name GoBuildCutController
extends RefCounted

## IDLE — tool not armed.  ARMED — waiting for the first point.
## PLACED — first point down, rubber-banding to the second.
enum CutState { IDLE, ARMED, PLACED }

# Self-preloads — dependency order.
const _EDGE_SCRIPT          := preload("res://addons/go_build/mesh/go_build_edge.gd")
const _MESH_SCRIPT          := preload("res://addons/go_build/mesh/go_build_mesh.gd")
const _CUT_OP_SCRIPT        := preload("res://addons/go_build/mesh/operations/cut_operation.gd")
const _MESH_INSTANCE_SCRIPT := preload("res://addons/go_build/core/go_build_mesh_instance.gd")
const _PICKING_SCRIPT       := preload("res://addons/go_build/core/picking_helper.gd")

## Screen distance within which a cut point snaps onto an edge endpoint, so
## corner-to-corner cuts are easy to hit without pixel-perfect aim.
const _VERTEX_SNAP_PX: float = 10.0

## Fraction of an edge Ctrl quantises the cut position to.
const _SNAP_STEP: float = 0.25

var _state: int = CutState.IDLE
var _node: GoBuildMeshInstance = null
var _commit_fn: Callable = Callable()

## Cut points, each [code]{"edge": int, "face": int, "t": float}[/code].
## [code]face[/code] is the face being cut and is only resolved for [member _hover]
## once an anchor is down; it is -1 before that.
var _anchor: Dictionary = {}
var _hover: Dictionary = {}

## Last cursor position, kept so the preview can be re-resolved when Ctrl is
## pressed or released without waiting for the next mouse move.
var _last_screen_pos: Vector2 = Vector2.ZERO

## Camera the last event arrived with.  The overlay pass is not handed one,
## and reaching for viewport 0 there would project onto the wrong viewport in
## a split layout — so the preview is projected with the camera the user is
## actually pointing at.
var _last_camera: Camera3D = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Arm the tool on [param node].  [param commit_fn] is called as
## [code]commit_fn(face_index, edge_a, t_a, edge_b, t_b)[/code] when a cut is
## confirmed; the owner is responsible for wrapping it in undo/redo.
func start(node: GoBuildMeshInstance, commit_fn: Callable) -> void:
	_node = node
	_commit_fn = commit_fn
	_anchor = {}
	_hover = {}
	_last_camera = null
	_state = CutState.ARMED


## Leave the tool, dropping any pending anchor.
func cancel() -> void:
	_state = CutState.IDLE
	_node = null
	_commit_fn = Callable()
	_anchor = {}
	_hover = {}
	_last_camera = null


## Drop a half-drawn cut without leaving the tool.
##
## Every cut point is an index into [member GoBuildMesh.edges], and
## [method GoBuildMesh.rebuild_edges] renumbers those on any topology change.
## An anchor that outlived its mesh would silently point at some other edge,
## so the owner calls this whenever the mesh changes underneath the tool.
func reset_anchor() -> void:
	if _state == CutState.IDLE:
		return
	_anchor = {}
	_hover = {}
	_state = CutState.ARMED


func is_active() -> bool:
	return _state != CutState.IDLE


func get_state() -> int:
	return _state


## The mesh instance the tool is armed on, or [code]null[/code].
func get_node_target() -> GoBuildMeshInstance:
	return _node


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## Route a viewport event to the tool.
##
## Returns 1 when the event was consumed.  Mouse motion is deliberately [i]not[/i]
## consumed — the plugin already withholds it from selection handling, and
## letting it through keeps editor camera navigation usable mid-cut.
func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if _state == CutState.IDLE or _node == null or not is_instance_valid(_node):
		return 0
	if camera != null:
		_last_camera = camera
	if event is InputEventMouseMotion:
		_hover = _pick(camera, (event as InputEventMouseMotion).position)
		return 0
	if event is InputEventKey:
		return _handle_key(camera, event as InputEventKey)
	if event is InputEventMouseButton:
		return _handle_button(camera, event as InputEventMouseButton)
	return 0


## Escape steps back one stage; Ctrl re-resolves the preview so the quarter-step
## snap engages the moment the modifier changes rather than on the next move.
func _handle_key(camera: Camera3D, key: InputEventKey) -> int:
	if key.keycode == KEY_CTRL:
		_hover = _pick(camera, _last_screen_pos)
		return 0
	if not key.pressed or key.echo or key.keycode != KEY_ESCAPE:
		return 0
	if _state == CutState.PLACED:
		_state = CutState.ARMED
		_anchor = {}
	else:
		cancel()
	return 1


## Left-click places the anchor, then confirms the cut.  Both press and release
## are swallowed so neither reaches selection or box-select handling.
func _handle_button(camera: Camera3D, event: InputEventMouseButton) -> int:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return 0
	if not event.pressed:
		return 1
	_hover = _pick(camera, event.position)
	if _hover.is_empty():
		return 1
	if _state == CutState.ARMED:
		_anchor = _hover
		_state = CutState.PLACED
		return 1
	_commit()
	return 1


## Hand the pending cut to the owner and re-arm for the next one.
## A click on an invalid target is ignored rather than cancelling, so the
## anchor survives a near miss.
func _commit() -> void:
	if not is_pending_valid():
		return
	if _commit_fn.is_valid():
		_commit_fn.call(
				int(_hover["face"]),
				int(_anchor["edge"]), float(_anchor["t"]),
				int(_hover["edge"]), float(_hover["t"]))
	_anchor = {}
	_hover = {}
	_state = CutState.ARMED


## Whether the anchor and the hovered point describe a cut [CutOperation] would
## accept.  Drives both the preview colour and the commit gate, so the line the
## user sees never promises something the click will not do.
func is_pending_valid() -> bool:
	if _state != CutState.PLACED or _anchor.is_empty() or _hover.is_empty():
		return false
	if _node == null or not is_instance_valid(_node):
		return false
	var gbm: GoBuildMesh = _node.go_build_mesh
	if gbm == null:
		return false
	return CutOperation.can_apply(
			gbm, int(_hover["face"]),
			int(_anchor["edge"]), float(_anchor["t"]),
			int(_hover["edge"]), float(_hover["t"]))


# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

## Resolve the cut point under [param screen_pos], or [code]{}[/code] when there
## is nothing to cut there.
##
## Before the anchor is down any visible edge is a candidate.  Afterwards the
## search is restricted to the edges around the anchor's faces, because the cut
## has to stay inside a single face — which also settles which face is being cut
## without a second raycast.
func _pick(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	_last_screen_pos = screen_pos
	if camera == null or _node == null or not is_instance_valid(_node):
		return {}
	var gbm: GoBuildMesh = _node.go_build_mesh
	if gbm == null or gbm.edges.is_empty():
		return {}

	var found: Dictionary
	if _state == CutState.PLACED:
		found = _nearest_candidate(camera, screen_pos, gbm)
	else:
		var ei: int = PickingHelper.find_nearest_edge(
				camera, screen_pos, _node, gbm, -1.0, true)
		found = {} if ei == -1 else {"edge": ei, "face": -1}
	if found.is_empty():
		return {}

	var raw_t: float = _edge_t(camera, gbm, int(found["edge"]), screen_pos)
	found["t"] = snap_t(raw_t, Input.is_key_pressed(KEY_CTRL))
	return found


## Nearest eligible edge for the second cut point, paired with its face.
##
## No distance threshold is applied: the cut always has to terminate somewhere
## on the face's boundary, so the nearest candidate is always the right answer
## however far the cursor has strayed.
func _nearest_candidate(
		camera: Camera3D,
		screen_pos: Vector2,
		gbm: GoBuildMesh,
) -> Dictionary:
	var gt: Transform3D = _node.global_transform
	var best: Dictionary = {}
	var best_dist: float = INF
	for candidate: Dictionary in candidate_edges(gbm, int(_anchor["edge"])):
		var edge: GoBuildEdge = gbm.edges[int(candidate["edge"])]
		var sa: Vector2 = camera.unproject_position(gt * gbm.vertices[edge.vertex_a])
		var sb: Vector2 = camera.unproject_position(gt * gbm.vertices[edge.vertex_b])
		var dist: float = PickingHelper.point_to_segment_dist(screen_pos, sa, sb)
		if dist < best_dist:
			best_dist = dist
			best = candidate
	return best


## Edges the second cut point may land on, each paired with the face that owns
## it.  Only the faces around [param edge_index] qualify, so the pairing doubles
## as the answer to "which face is being cut".
static func candidate_edges(gbm: GoBuildMesh, edge_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if gbm == null or edge_index < 0 or edge_index >= gbm.edges.size():
		return result
	var seen: Dictionary = {}
	for fi: int in gbm.edges[edge_index].face_indices:
		for ei: int in gbm.edges_of_face(fi):
			if ei == edge_index or seen.has(ei):
				continue
			seen[ei] = true
			result.append({"edge": ei, "face": fi})
	return result


## Parametric position of [param screen_pos] along edge [param ei].
##
## Measured in screen space rather than along the 3D edge so the marker tracks
## the cursor exactly, instead of drifting under perspective foreshortening.
## Snaps onto whichever endpoint is within [constant _VERTEX_SNAP_PX].
func _edge_t(
		camera: Camera3D,
		gbm: GoBuildMesh,
		ei: int,
		screen_pos: Vector2,
) -> float:
	var edge: GoBuildEdge = gbm.edges[ei]
	var gt: Transform3D = _node.global_transform
	var sa: Vector2 = camera.unproject_position(gt * gbm.vertices[edge.vertex_a])
	var sb: Vector2 = camera.unproject_position(gt * gbm.vertices[edge.vertex_b])
	var segment: Vector2 = sb - sa
	var length_sq: float = segment.length_squared()
	if length_sq < 1e-6:
		return 0.0
	var t: float = clampf((screen_pos - sa).dot(segment) / length_sq, 0.0, 1.0)
	var pixels: float = sqrt(length_sq)
	if t * pixels <= _VERTEX_SNAP_PX:
		return 0.0
	if (1.0 - t) * pixels <= _VERTEX_SNAP_PX:
		return 1.0
	return t


## Quantise [param t] to [constant _SNAP_STEP] when [param quarter] is set.
## Values already sitting on an endpoint are left exact so the modifier cannot
## undo the vertex snap.
static func snap_t(t: float, quarter: bool) -> float:
	if not quarter or t <= 0.0 or t >= 1.0:
		return t
	return clampf(roundf(t / _SNAP_STEP) * _SNAP_STEP, 0.0, 1.0)


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

## Screen-space preview data for [method CutOverlay.draw], projected with the
## camera the tool last saw an event from.
## Returns [code]{}[/code] when there is nothing to draw.
func overlay_data() -> Dictionary:
	var camera: Camera3D = _last_camera
	if _state == CutState.IDLE or camera == null or not is_instance_valid(camera):
		return {}
	if _node == null or not is_instance_valid(_node) or _node.go_build_mesh == null:
		return {}
	var data: Dictionary = {
		"has_anchor": false,
		"anchor": Vector2.ZERO,
		"has_cursor": false,
		"cursor": Vector2.ZERO,
		"valid": _state != CutState.PLACED or is_pending_valid(),
		"hint": hint_text(),
	}
	if not _anchor.is_empty():
		data["has_anchor"] = true
		data["anchor"] = camera.unproject_position(_point_world(_anchor))
	if not _hover.is_empty():
		data["has_cursor"] = true
		data["cursor"] = camera.unproject_position(_point_world(_hover))
	return data


## World position of a cut point, used to place the preview markers.
func _point_world(point: Dictionary) -> Vector3:
	var gbm: GoBuildMesh = _node.go_build_mesh
	var edge: GoBuildEdge = gbm.edges[int(point["edge"])]
	var local: Vector3 = gbm.vertices[edge.vertex_a].lerp(
			gbm.vertices[edge.vertex_b], float(point["t"]))
	return _node.global_transform * local


## Bottom-left status line naming the step the tool is waiting on.
func hint_text() -> String:
	match _state:
		CutState.ARMED:
			return "Cut — Click a point on an edge | Ctrl: ¼ snap | Esc: exit"
		CutState.PLACED:
			return "Cut — Click another edge of the same face" \
					+ " | Ctrl: ¼ snap | Esc: cancel"
	return ""
