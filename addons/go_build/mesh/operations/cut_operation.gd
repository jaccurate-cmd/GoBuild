## Cut (knife) operation for [GoBuildMesh].
##
## Splits one face in two along a straight line drawn between two points on its
## boundary.  Each point is given as an edge index plus a parametric position
## [code]t[/code] along that edge (0 = [member GoBuildEdge.vertex_a],
## 1 = [member GoBuildEdge.vertex_b]), which is exactly what the interactive cut
## tool produces when the user clicks on an edge.
##
## Modelled on the Cut tool in s&box's Hammer: click a point on one edge, click a
## point on another edge of the same face, and the face becomes two faces joined
## by a new edge running between those points.
##
## Watertightness:
##   A point that lands in the middle of an edge inserts its new vertex into
##   [i]every[/i] face sharing that edge, not just the face being cut.  The
##   neighbour becomes an n-gon with one collinear vertex, which keeps the
##   surface free of T-junction cracks.  A point that lands on an existing
##   vertex ([code]t[/code] at either end) reuses it and splits nothing.
##
## Rejected — returns [code]-1[/code] with the mesh untouched — when:
##   - either edge does not border the face,
##   - both points are the same edge,
##   - the two points resolve to the same vertex, or to two vertices already
##     adjacent in the face loop.  Either way one side of the cut would be a
##     face with fewer than three vertices.
##
## [method GoBuildMesh.rebuild_edges] is called automatically inside
## [method apply].
@tool
class_name CutOperation
extends RefCounted

# Self-preloads — dependency order.
const _FACE_SCRIPT := preload("res://addons/go_build/mesh/go_build_face.gd")
const _EDGE_SCRIPT := preload("res://addons/go_build/mesh/go_build_edge.gd")
const _MESH_SCRIPT := preload("res://addons/go_build/mesh/go_build_mesh.gd")

## How close to an edge end a cut point has to be before it snaps onto the
## existing vertex instead of creating a near-coincident one.  This is a
## degeneracy guard, not a UX affordance — the interactive tool does its own
## screen-space vertex snapping and hands over an exact 0.0 or 1.0.
const _T_EPSILON: float = 1e-4


## Cut the face at [param face_index] along the line between the two points.
##
## [param edge_a] / [param edge_b] are indices into [member GoBuildMesh.edges];
## [param t_a] / [param t_b] are clamped to [0, 1].
## [method GoBuildMesh.rebuild_edges] is called automatically on completion.
##
## Returns the index of the new edge running along the cut, or [code]-1[/code]
## when the cut was rejected (see the class description for the rules).
static func apply(
		mesh: GoBuildMesh,
		face_index: int,
		edge_a: int,
		t_a: float,
		edge_b: int,
		t_b: float,
) -> int:
	var points: Dictionary = _resolve(mesh, face_index, edge_a, t_a, edge_b, t_b)
	if points.is_empty():
		return -1

	# Both splits happen before the face is divided.  Neither renumbers an
	# existing vertex, face, or edge, so the indices captured above stay valid.
	var vert_a: int = _split_edge(mesh, edge_a, points["a"])
	var vert_b: int = _split_edge(mesh, edge_b, points["b"])

	_split_face(mesh, face_index, vert_a, vert_b)
	mesh.rebuild_edges()
	return mesh.find_edge(vert_a, vert_b)


## Returns [code]true[/code] when [method apply] would accept this cut and leave
## the mesh changed.  The interactive tool calls this on every mouse move to
## colour its preview line, so it must not touch [param mesh].
static func can_apply(
		mesh: GoBuildMesh,
		face_index: int,
		edge_a: int,
		t_a: float,
		edge_b: int,
		t_b: float,
) -> bool:
	return not _resolve(mesh, face_index, edge_a, t_a, edge_b, t_b).is_empty()


## Bounds-check the arguments and locate both cut points on the face loop.
##
## Returns [code]{"a": Dictionary, "b": Dictionary}[/code] holding the two
## located points (see [method _locate]), or an empty [Dictionary] when the cut
## has to be rejected.  This is the single gate both [method apply] and
## [method can_apply] go through, so the preview can never disagree with what
## the commit actually does.
static func _resolve(
		mesh: GoBuildMesh,
		face_index: int,
		edge_a: int,
		t_a: float,
		edge_b: int,
		t_b: float,
) -> Dictionary:
	if mesh == null or edge_a == edge_b:
		return {}
	if face_index < 0 or face_index >= mesh.faces.size():
		return {}
	if edge_a < 0 or edge_a >= mesh.edges.size():
		return {}
	if edge_b < 0 or edge_b >= mesh.edges.size():
		return {}

	var loop: Array[int] = mesh.faces[face_index].vertex_indices
	if loop.size() < 3:
		return {}

	var point_a: Dictionary = _locate(mesh, loop, edge_a, clampf(t_a, 0.0, 1.0))
	var point_b: Dictionary = _locate(mesh, loop, edge_b, clampf(t_b, 0.0, 1.0))
	if point_a.is_empty() or point_b.is_empty():
		return {}
	if not _cut_is_valid(loop.size(), point_a, point_b):
		return {}
	return {"a": point_a, "b": point_b}


# ---------------------------------------------------------------------------
# Locating the cut points on the face loop
# ---------------------------------------------------------------------------

## Work out where the cut point sits on [param loop].
##
## Returns [code]{"loop_index": int, "vertex": int}[/code] when the point
## coincides with a loop vertex, or [code]{"segment": int, "edge_t": float}[/code]
## when it lies strictly inside the loop segment starting at that index.
## [code]edge_t[/code] stays in the edge's own [code]vertex_a → vertex_b[/code]
## direction so it can be reused for the neighbouring faces, which may walk the
## edge the other way round.
##
## Returns an empty [Dictionary] when the edge does not border the loop.
static func _locate(mesh: GoBuildMesh, loop: Array[int], ei: int, t: float) -> Dictionary:
	var edge: GoBuildEdge = mesh.edges[ei]
	var n: int = loop.size()
	for k: int in n:
		var next_k: int = (k + 1) % n
		var local_t: float
		if loop[k] == edge.vertex_a and loop[next_k] == edge.vertex_b:
			local_t = t
		elif loop[k] == edge.vertex_b and loop[next_k] == edge.vertex_a:
			local_t = 1.0 - t
		else:
			continue
		if local_t <= _T_EPSILON:
			return {"loop_index": k, "vertex": loop[k]}
		if local_t >= 1.0 - _T_EPSILON:
			return {"loop_index": next_k, "vertex": loop[next_k]}
		return {"segment": k, "edge_t": t}
	return {}


## Returns [code]true[/code] when both sides of the cut would keep at least
## three vertices.
##
## Walks the loop the way it will look once the mid-edge vertices are inserted
## and records the index each cut point lands on, so the check is exact rather
## than a tolerance on the original loop.
static func _cut_is_valid(n: int, point_a: Dictionary, point_b: Dictionary) -> bool:
	var index_a: int = -1
	var index_b: int = -1
	var cursor: int = 0
	for k: int in n:
		if point_a.get("loop_index", -1) == k:
			index_a = cursor
		if point_b.get("loop_index", -1) == k:
			index_b = cursor
		cursor += 1
		if point_a.get("segment", -1) == k:
			index_a = cursor
			cursor += 1
		if point_b.get("segment", -1) == k:
			index_b = cursor
			cursor += 1
	if index_a == -1 or index_b == -1:
		return false
	var forward: int = posmod(index_b - index_a, cursor)
	return forward >= 2 and cursor - forward >= 2


# ---------------------------------------------------------------------------
# Edge splitting
# ---------------------------------------------------------------------------

## Resolve [param point] to a vertex index, creating one on [param ei] and
## threading it through every adjacent face when the point is mid-edge.
static func _split_edge(mesh: GoBuildMesh, ei: int, point: Dictionary) -> int:
	if point.has("vertex"):
		return point["vertex"]

	var edge: GoBuildEdge = mesh.edges[ei]
	var va: int = edge.vertex_a
	var vb: int = edge.vertex_b
	var t: float = point["edge_t"]
	var pos: Vector3 = mesh.vertices[va].lerp(mesh.vertices[vb], t)
	var mid: int = mesh.append_vertex_lerp(va, vb, pos, t)
	for fi: int in edge.face_indices:
		_insert_into_face(mesh.faces[fi], va, vb, mid, t)
	return mid


## Insert [param mid] between [param va] and [param vb] in [param face]'s loop.
##
## [param t] runs [param va] → [param vb]; faces that walk the edge the other
## way use its complement so the interpolated UVs land in the same place.
static func _insert_into_face(
		face: GoBuildFace,
		va: int,
		vb: int,
		mid: int,
		t: float,
) -> void:
	var n: int = face.vertex_indices.size()
	for k: int in n:
		var next_k: int = (k + 1) % n
		var local_t: float
		if face.vertex_indices[k] == va and face.vertex_indices[next_k] == vb:
			local_t = t
		elif face.vertex_indices[k] == vb and face.vertex_indices[next_k] == va:
			local_t = 1.0 - t
		else:
			continue
		face.vertex_indices.insert(k + 1, mid)
		_insert_uv(face.uvs, n, k, next_k, local_t)
		_insert_uv(face.uv2s, n, k, next_k, local_t)
		return


## Insert the interpolated corner UV for a vertex added between [param k] and
## [param next_k].  Channels that are not parallel to the loop are left alone —
## [member GoBuildFace.uv2s] is legitimately empty on most faces.
static func _insert_uv(
		channel: Array[Vector2],
		n: int,
		k: int,
		next_k: int,
		t: float,
) -> void:
	if channel.size() != n:
		return
	channel.insert(k + 1, channel[k].lerp(channel[next_k], t))


# ---------------------------------------------------------------------------
# Face splitting
# ---------------------------------------------------------------------------

## Replace [param face_index] with the side of the cut running from
## [param vert_a] to [param vert_b], and append the other side.
static func _split_face(
		mesh: GoBuildMesh,
		face_index: int,
		vert_a: int,
		vert_b: int,
) -> void:
	var face: GoBuildFace = mesh.faces[face_index]
	var pa: int = face.vertex_indices.find(vert_a)
	var pb: int = face.vertex_indices.find(vert_b)
	if pa == -1 or pb == -1:
		return
	mesh.faces[face_index] = _slice_face(face, pa, pb)
	mesh.faces.append(_slice_face(face, pb, pa))


## Build the face running forward around [param face]'s loop from [param from]
## to [param to], both inclusive, carrying the per-corner and per-face data
## across so both halves keep the original's material, shading, and texturing.
static func _slice_face(face: GoBuildFace, from: int, to: int) -> GoBuildFace:
	var n: int = face.vertex_indices.size()
	var corners: Array[int] = []
	var k: int = from
	for _step: int in n:
		corners.append(k)
		if k == to:
			break
		k = (k + 1) % n

	var result := GoBuildFace.new()
	for c: int in corners:
		result.vertex_indices.append(face.vertex_indices[c])
	if face.uvs.size() == n:
		for c: int in corners:
			result.uvs.append(face.uvs[c])
	if face.uv2s.size() == n:
		for c: int in corners:
			result.uv2s.append(face.uv2s[c])

	result.material_index     = face.material_index
	result.smooth_group       = face.smooth_group
	result.uv_projection_mode = face.uv_projection_mode
	result.uv_scale           = face.uv_scale
	result.uv_offset          = face.uv_offset
	result.uv_seam_rotation   = face.uv_seam_rotation
	return result
