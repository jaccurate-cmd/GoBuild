## Cut operation tests — GdUnit4
##
## Tests for [CutOperation.apply] and [CutOperation.can_apply] covering the
## resulting topology, winding, UV carry-over, watertightness across a shared
## edge, and every rejection rule.
##
## Test mesh conventions:
##   _make_quad()      — one quad in the XZ plane, all 4 edges boundary.
##   _make_two_quads() — two quads sharing an interior edge, used to prove the
##     neighbour gets the cut vertex too (no T-junction).
extends GdUnitTestSuite

# Self-preloads — needed because the test suite is compiled before the
# mesh/ scripts in Godot's alphabetical scan order.
const _FACE_SCRIPT := preload("res://addons/go_build/mesh/go_build_face.gd")
const _EDGE_SCRIPT := preload("res://addons/go_build/mesh/go_build_edge.gd")
const _MESH_SCRIPT := preload("res://addons/go_build/mesh/go_build_mesh.gd")
const _CUT_SCRIPT  := preload("res://addons/go_build/mesh/operations/cut_operation.gd")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Single quad in the XZ plane.
## Vertices: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1).
## Edges after rebuild_edges(): 0=(0,1) 1=(1,2) 2=(2,3) 3=(3,0), all boundary.
func _make_quad() -> GoBuildMesh:
	var mesh := GoBuildMesh.new()
	mesh.vertices = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
	]
	var face := GoBuildFace.new()
	face.vertex_indices = [0, 1, 2, 3]
	face.uvs = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	mesh.faces.append(face)
	mesh.rebuild_edges()
	return mesh


## Two quads sharing the interior edge v1↔v2.
func _make_two_quads() -> GoBuildMesh:
	var mesh := GoBuildMesh.new()
	mesh.vertices = [
		Vector3(0.0, 0.0, 0.0),  # 0
		Vector3(1.0, 0.0, 0.0),  # 1
		Vector3(1.0, 0.0, 1.0),  # 2
		Vector3(0.0, 0.0, 1.0),  # 3
		Vector3(2.0, 0.0, 0.0),  # 4
		Vector3(2.0, 0.0, 1.0),  # 5
	]
	var f0 := GoBuildFace.new()
	f0.vertex_indices = [0, 1, 2, 3]
	f0.uvs = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var f1 := GoBuildFace.new()
	f1.vertex_indices = [1, 4, 5, 2]
	f1.uvs = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	mesh.faces.append(f0)
	mesh.faces.append(f1)
	mesh.rebuild_edges()
	return mesh


## Index of the edge connecting [param va] and [param vb].
func _edge(mesh: GoBuildMesh, va: int, vb: int) -> int:
	return mesh.find_edge(va, vb)


## Number of edges with exactly one adjacent face.
func _boundary_count(mesh: GoBuildMesh) -> int:
	var count := 0
	for edge in mesh.edges:
		if (edge as GoBuildEdge).is_boundary():
			count += 1
	return count


# ---------------------------------------------------------------------------
# Topology — cutting a single quad
# ---------------------------------------------------------------------------

func test_cut_between_opposite_edges_makes_two_quads() -> void:
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 2, 3), 0.5)
	assert_int(new_edge).is_not_equal(-1)
	assert_int(mesh.faces.size()).is_equal(2)
	assert_int(mesh.vertices.size()).is_equal(6)
	for face in mesh.faces:
		assert_int((face as GoBuildFace).vertex_indices.size()).is_equal(4)


func test_cut_between_adjacent_edges_makes_a_triangle_and_a_pentagon() -> void:
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 1, 2), 0.5)
	assert_int(new_edge).is_not_equal(-1)
	var sizes: Array[int] = []
	for face in mesh.faces:
		sizes.append((face as GoBuildFace).vertex_indices.size())
	sizes.sort()
	assert_array(sizes).is_equal([3, 5])


func test_corner_to_corner_cut_adds_no_vertices() -> void:
	# Both points snap onto existing corners, so the cut is a pure face split.
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.0, _edge(mesh, 1, 2), 1.0)
	assert_int(new_edge).is_not_equal(-1)
	assert_int(mesh.vertices.size()).is_equal(4)
	assert_int(mesh.faces.size()).is_equal(2)
	for face in mesh.faces:
		assert_int((face as GoBuildFace).vertex_indices.size()).is_equal(3)


func test_returned_edge_connects_the_two_cut_points() -> void:
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 2, 3), 0.5)
	var edge: GoBuildEdge = mesh.edges[new_edge]
	var a: Vector3 = mesh.vertices[edge.vertex_a]
	var b: Vector3 = mesh.vertices[edge.vertex_b]
	assert_float(minf(a.z, b.z)).is_equal_approx(0.0, 0.001)
	assert_float(maxf(a.z, b.z)).is_equal_approx(1.0, 0.001)
	assert_float(a.x).is_equal_approx(0.5, 0.001)
	assert_float(b.x).is_equal_approx(0.5, 0.001)


func test_returned_edge_is_interior() -> void:
	# The cut edge sits between the two halves, so both claim it.
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 2, 3), 0.5)
	assert_bool((mesh.edges[new_edge] as GoBuildEdge).is_boundary()).is_false()


# ---------------------------------------------------------------------------
# Winding
# ---------------------------------------------------------------------------

func test_both_halves_keep_the_source_face_normal() -> void:
	for pair: Array in [[0.5, 0.5], [0.25, 0.75], [0.0, 0.5]]:
		var mesh := _make_quad()
		var source: Vector3 = mesh.compute_face_normal(mesh.faces[0])
		var new_edge: int = CutOperation.apply(
				mesh, 0, _edge(mesh, 0, 1), float(pair[0]),
				_edge(mesh, 2, 3), float(pair[1]))
		assert_int(new_edge).is_not_equal(-1)
		for face in mesh.faces:
			var n: Vector3 = mesh.compute_face_normal(face as GoBuildFace)
			assert_float(n.dot(source)).is_greater(0.99)


# ---------------------------------------------------------------------------
# UVs and per-face data
# ---------------------------------------------------------------------------

func test_both_halves_keep_uvs_parallel_to_their_loop() -> void:
	var mesh := _make_quad()
	CutOperation.apply(mesh, 0, _edge(mesh, 0, 1), 0.25, _edge(mesh, 1, 2), 0.75)
	for face in mesh.faces:
		var f: GoBuildFace = face
		assert_int(f.uvs.size()).is_equal(f.vertex_indices.size())


func test_cut_vertex_uv_is_interpolated_along_the_edge() -> void:
	# Edge v0→v1 runs from UV (0,0) to (1,0); a cut at t=0.25 must land on
	# (0.25, 0) in both faces that end up using the new vertex.
	var mesh := _make_quad()
	var new_edge: int = CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.25, _edge(mesh, 2, 3), 0.5)
	var cut_vertex: int = -1
	var edge: GoBuildEdge = mesh.edges[new_edge]
	for vi: int in [edge.vertex_a, edge.vertex_b]:
		if is_equal_approx(mesh.vertices[vi].z, 0.0):
			cut_vertex = vi
	assert_int(cut_vertex).is_not_equal(-1)
	for face in mesh.faces:
		var f: GoBuildFace = face
		var slot: int = f.vertex_indices.find(cut_vertex)
		if slot == -1:
			continue
		assert_float(f.uvs[slot].x).is_equal_approx(0.25, 0.001)
		assert_float(f.uvs[slot].y).is_equal_approx(0.0, 0.001)


func test_both_halves_inherit_material_and_smooth_group() -> void:
	var mesh := _make_quad()
	mesh.faces[0].material_index = 3
	mesh.faces[0].smooth_group = 7
	CutOperation.apply(mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 2, 3), 0.5)
	for face in mesh.faces:
		assert_int((face as GoBuildFace).material_index).is_equal(3)
		assert_int((face as GoBuildFace).smooth_group).is_equal(7)


# ---------------------------------------------------------------------------
# Watertightness across a shared edge
# ---------------------------------------------------------------------------

func test_neighbour_face_gains_the_cut_vertex() -> void:
	# Cutting from the shared interior edge must thread the new vertex through
	# the untouched neighbour too, or the surface cracks at a T-junction.
	var mesh := _make_two_quads()
	var interior: int = _edge(mesh, 1, 2)
	var new_edge: int = CutOperation.apply(mesh, 0, interior, 0.5, _edge(mesh, 3, 0), 0.5)
	assert_int(new_edge).is_not_equal(-1)

	var mid: int = -1
	for vi: int in mesh.vertices.size():
		if mesh.vertices[vi].is_equal_approx(Vector3(1.0, 0.0, 0.5)):
			mid = vi
	assert_int(mid).is_not_equal(-1)

	var neighbours: Array[int] = mesh.faces_of_vertex(mid)
	assert_int(neighbours.size()).is_equal(3)


func test_cut_across_a_shared_edge_creates_no_new_boundary() -> void:
	var mesh := _make_two_quads()
	var before: int = _boundary_count(mesh)
	CutOperation.apply(mesh, 0, _edge(mesh, 1, 2), 0.5, _edge(mesh, 3, 0), 0.5)
	# The perimeter gains exactly the two segments the cut points split it into.
	assert_int(_boundary_count(mesh)).is_equal(before + 2)


# ---------------------------------------------------------------------------
# Rejection rules
# ---------------------------------------------------------------------------

func test_same_edge_twice_is_rejected() -> void:
	var mesh := _make_quad()
	var ei: int = _edge(mesh, 0, 1)
	assert_int(CutOperation.apply(mesh, 0, ei, 0.25, ei, 0.75)).is_equal(-1)
	assert_int(mesh.faces.size()).is_equal(1)
	assert_int(mesh.vertices.size()).is_equal(4)


func test_both_points_on_the_same_corner_is_rejected() -> void:
	# Edge (0,1) at t=1 and edge (1,2) at t=0 are both vertex 1.
	var mesh := _make_quad()
	assert_int(CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 1.0, _edge(mesh, 1, 2), 0.0)).is_equal(-1)
	assert_int(mesh.faces.size()).is_equal(1)


func test_two_adjacent_corners_are_rejected() -> void:
	# Vertices 0 and 3 already share an edge, so one side would be a two-vertex face.
	var mesh := _make_quad()
	assert_int(CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.0, _edge(mesh, 3, 0), 0.0)).is_equal(-1)
	assert_int(mesh.faces.size()).is_equal(1)


func test_mid_edge_point_next_to_its_own_endpoint_is_rejected() -> void:
	# A cut from the middle of edge (0,1) to vertex 1 would be a zero-width sliver.
	var mesh := _make_quad()
	assert_int(CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 1, 2), 0.0)).is_equal(-1)
	assert_int(mesh.vertices.size()).is_equal(4)


func test_edge_that_does_not_border_the_face_is_rejected() -> void:
	var mesh := _make_two_quads()
	# Edge (4,5) belongs to the right quad only; face 0 is the left quad.
	assert_int(CutOperation.apply(
			mesh, 0, _edge(mesh, 0, 1), 0.5, _edge(mesh, 4, 5), 0.5)).is_equal(-1)
	assert_int(mesh.faces.size()).is_equal(2)


func test_out_of_range_indices_are_rejected() -> void:
	var mesh := _make_quad()
	assert_int(CutOperation.apply(mesh, 99, 0, 0.5, 2, 0.5)).is_equal(-1)
	assert_int(CutOperation.apply(mesh, 0, 99, 0.5, 2, 0.5)).is_equal(-1)
	assert_int(CutOperation.apply(mesh, 0, 0, 0.5, 99, 0.5)).is_equal(-1)
	assert_int(CutOperation.apply(mesh, 0, -1, 0.5, 2, 0.5)).is_equal(-1)
	assert_int(mesh.faces.size()).is_equal(1)


func test_null_mesh_is_rejected() -> void:
	assert_int(CutOperation.apply(null, 0, 0, 0.5, 2, 0.5)).is_equal(-1)


# ---------------------------------------------------------------------------
# can_apply mirrors apply
# ---------------------------------------------------------------------------

func test_can_apply_agrees_with_apply() -> void:
	var cases: Array = [
		[0, 1, 0.5, 2, 3, 0.5, true],
		[0, 1, 0.0, 1, 2, 1.0, true],
		[0, 1, 1.0, 1, 2, 0.0, false],
		[0, 1, 0.0, 3, 0, 0.0, false],
		[0, 1, 0.5, 1, 2, 0.0, false],
	]
	for case in cases:
		var probe := _make_quad()
		var ea: int = _edge(probe, int(case[0]), int(case[1]))
		var eb: int = _edge(probe, int(case[3]), int(case[4]))
		var t_a: float = float(case[2])
		var t_b: float = float(case[5])
		var predicted: bool = CutOperation.can_apply(probe, 0, ea, t_a, eb, t_b)
		assert_bool(predicted).is_equal(bool(case[6]))
		# can_apply must be side-effect free.
		assert_int(probe.faces.size()).is_equal(1)
		assert_int(probe.vertices.size()).is_equal(4)
		var actual: bool = CutOperation.apply(probe, 0, ea, t_a, eb, t_b) != -1
		assert_bool(actual).is_equal(predicted)
