## Edge extrude operation for [GoBuildMesh].
##
## Extrudes each selected edge by creating two new vertices at the same
## positions as the original edge endpoints and adding a new quad face that
## connects the original edge to the new one.
##
## The new face starts as a zero-area (degenerate) quad — both pairs of
## vertices are coincident — so the caller is expected to immediately move
## the new boundary edge (the [code]na[/code]/[code]nb[/code] pair) away from
## the mesh to give the face area.
##
## Both boundary and interior edges are processed.  Extruding an interior
## edge creates a T-junction (the original edge gains a third adjacent face)
## which matches Blender's "Extrude Edges and Move" behaviour for interior edges.
##
## The new face walks the shared edge in the opposite direction to the adjacent
## face, which is the condition for two neighbouring faces to be consistently
## oriented -- so the extruded quad keeps the source face's outward side.
##
## [method GoBuildMesh.rebuild_edges] is called automatically inside
## [method apply]. The method returns the indices of all newly created edges
## that form the new boundary (the [code]na[/code]↔[code]nb[/code] pairs) so
## callers can update the selection to point at the extruded edge.
@tool
class_name EdgeExtrudeOperation
extends RefCounted

# Self-preloads — dependency order.
const _FACE_SCRIPT := preload("res://addons/go_build/mesh/go_build_face.gd")
const _EDGE_SCRIPT := preload("res://addons/go_build/mesh/go_build_edge.gd")
const _MESH_SCRIPT := preload("res://addons/go_build/mesh/go_build_mesh.gd")


## Extrude the boundary edges at [param edge_indices] on [param mesh].
##
## Returns the new boundary edge indices (one per successfully extruded source
## edge) so callers can update the selection.
## [method GoBuildMesh.rebuild_edges] is called automatically on completion.
## [param width] offsets the new edge vertices by this distance along the
## average outward normal of the adjacent face(s).  0.0 creates a zero-area
## face (caller moves the vertices later, e.g. via Shift+drag).
static func apply(
		mesh: GoBuildMesh,
		edge_indices: Array[int],
		width: float = 0.0,
) -> Array[int]:
	if mesh == null or edge_indices.is_empty():
		return []

	# Collect valid edge indices (bounds-checked).  Snapshot before mutating
	# because rebuild_edges invalidates face_indices on existing edges.
	var valid_indices: Array[int] = []
	for ei: int in edge_indices:
		if ei >= 0 and ei < mesh.edges.size():
			valid_indices.append(ei)

	if valid_indices.is_empty():
		return []

	# Precompute per-edge extrude offset BEFORE altering topology.
	# Direction = average normal of adjacent faces, then scaled by width.
	var edge_offsets: Dictionary = {}  # ei -> Vector3
	if width != 0.0:
		for ei: int in valid_indices:
			var edge: GoBuildEdge = mesh.edges[ei]
			var avg_normal := Vector3.ZERO
			for fi: int in edge.face_indices:
				avg_normal += mesh.compute_face_normal(mesh.faces[fi])
			if avg_normal.length_squared() > 1e-8:
				avg_normal = avg_normal.normalized()
			edge_offsets[ei] = avg_normal * width

	# Track the vertex index range before any additions.
	# After rebuild_edges the returned edge indices are found by matching
	# the na/nb vertex index pairs, which are stored per-extrusion below.
	var new_vert_pairs: Array = []  # Array of [na, nb] int pairs.

	for ei: int in valid_indices:
		var edge: GoBuildEdge = mesh.edges[ei]
		var offset: Vector3 = edge_offsets.get(ei, Vector3.ZERO)
		_extrude_single_edge(mesh, edge, new_vert_pairs, offset)

	mesh.rebuild_edges()

	# Re-locate new boundary edges by matching the na/nb pairs.
	var result: Array[int] = []
	for pair in new_vert_pairs:
		var na: int = pair[0]
		var nb: int = pair[1]
		for new_ei: int in mesh.edges.size():
			var e: GoBuildEdge = mesh.edges[new_ei]
			if e.connects(na, nb) and e.is_boundary():
				result.append(new_ei)
				break
	return result


## Extrude a single boundary edge, appending a new face and the na/nb pair.
##
## Algorithm:
##   1. Orient [code]va[/code]→[code]vb[/code] the way the adjacent face walks
##      the shared edge.  The edge's own direction comes from whichever face
##      registered it first, so it is not reliable on its own.
##   2. Duplicate each endpoint: [code]na[/code] at [code]va[/code]'s position,
##      [code]nb[/code] at [code]vb[/code]'s position.
##   3. Add a new quad face [code][vb, va, na, nb][/code] — the shared edge is
##      walked backwards relative to the adjacent face.
##   4. Append [code][na, nb][/code] to [param new_vert_pairs] for post-
##      rebuild index lookup.
##   5. Offset [code]na[/code] and [code]nb[/code] by [param offset] if non-zero.
static func _extrude_single_edge(
		mesh: GoBuildMesh,
		edge: GoBuildEdge,
		new_vert_pairs: Array,
		offset: Vector3 = Vector3.ZERO,
) -> void:
	# ── 1. Match the adjacent face's traversal direction ───────────────────
	var va: int = edge.vertex_a
	var vb: int = edge.vertex_b
	if not edge.face_indices.is_empty():
		var adjacent: GoBuildFace = mesh.faces[edge.face_indices[0]]
		if not _face_walks(adjacent, va, vb):
			var swap: int = va
			va = vb
			vb = swap

	# ── 2. Duplicate the two endpoints ─────────────────────────────────────
	var na: int = mesh.append_vertex_from(va, mesh.vertices[va] + offset)
	var nb: int = mesh.append_vertex_from(vb, mesh.vertices[vb] + offset)

	# ── 3. Add the new quad face ────────────────────────────────────────────
	# The adjacent face walks va→vb, so the new face walks vb→va.  Faces that
	# share an edge in opposite directions agree on which side is outward, so
	# the extruded quad inherits the source face's normal orientation.
	var face := GoBuildFace.new()
	face.vertex_indices = [vb, va, na, nb]
	# Simple planar UV: bottom-left → bottom-right → top-right → top-left.
	face.uvs = [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)]
	# Inherit material from the adjacent face so the new face blends in.
	if not edge.face_indices.is_empty():
		face.material_index = mesh.faces[edge.face_indices[0]].material_index
	mesh.faces.append(face)

	# ── 4. Record the new-vert pair for post-rebuild lookup ─────────────────
	new_vert_pairs.append([na, nb])


## Returns [code]true[/code] if [param face] walks its vertex loop straight from
## [param va] to [param vb].
static func _face_walks(face: GoBuildFace, va: int, vb: int) -> bool:
	var vc: int = face.vertex_indices.size()
	for i: int in vc:
		if face.vertex_indices[i] == va and face.vertex_indices[(i + 1) % vc] == vb:
			return true
	return false
