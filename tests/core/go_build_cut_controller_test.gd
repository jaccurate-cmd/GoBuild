## GdUnit4 tests for [GoBuildCutController].
##
## Covers the parts of the interactive cut tool that do not need a live editor
## camera: the state machine, which edges are eligible for the second cut point,
## the Ctrl quarter-step snap, and the tuple handed to the commit callback.
##
## The screen-space picking itself needs a real [Camera3D] in an editor viewport
## and is left to manual verification; everything it feeds is covered here.
@tool
extends GdUnitTestSuite

# Self-preloads — dependency order, per the self-preload rule.
const _MESH_SCRIPT          := preload("res://addons/go_build/mesh/go_build_mesh.gd")
const _FACE_SCRIPT          := preload("res://addons/go_build/mesh/go_build_face.gd")
const _MESH_INSTANCE_SCRIPT := preload("res://addons/go_build/core/go_build_mesh_instance.gd")
const _CUT_CTRL_SCRIPT      := preload("res://addons/go_build/core/go_build_cut_controller.gd")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Two quads sharing the interior edge v1↔v2, matching the cut operation tests.
func _make_mesh() -> GoBuildMesh:
	var mesh := GoBuildMesh.new()
	mesh.vertices = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 1.0),
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


func _make_node() -> GoBuildMeshInstance:
	var node: GoBuildMeshInstance = auto_free(GoBuildMeshInstance.new())
	add_child(node)
	node.go_build_mesh = _make_mesh()
	return node


func _armed(commit_fn: Callable = Callable()) -> GoBuildCutController:
	var controller := GoBuildCutController.new()
	controller.start(_make_node(), commit_fn)
	return controller


func _key(keycode: Key, pressed: bool = true) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	return event


func _click(
		pressed: bool = true,
		button: MouseButton = MOUSE_BUTTON_LEFT,
) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	return event


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func test_controller_starts_idle() -> void:
	var controller := GoBuildCutController.new()
	assert_bool(controller.is_active()).is_false()
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.IDLE)


func test_start_arms_the_tool_on_the_node() -> void:
	var node := _make_node()
	var controller := GoBuildCutController.new()
	controller.start(node, Callable())
	assert_bool(controller.is_active()).is_true()
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.ARMED)
	assert_object(controller.get_node_target()).is_equal(node)


func test_cancel_returns_to_idle_and_releases_the_node() -> void:
	var controller := _armed()
	controller.cancel()
	assert_bool(controller.is_active()).is_false()
	assert_object(controller.get_node_target()).is_null()


func test_idle_controller_ignores_input() -> void:
	var controller := GoBuildCutController.new()
	assert_int(controller.handle_input(null, _click())).is_equal(0)
	assert_int(controller.handle_input(null, _key(KEY_ESCAPE))).is_equal(0)


# ---------------------------------------------------------------------------
# Escape steps back one stage at a time
# ---------------------------------------------------------------------------

func test_escape_while_armed_leaves_the_tool() -> void:
	var controller := _armed()
	assert_int(controller.handle_input(null, _key(KEY_ESCAPE))).is_equal(1)
	assert_bool(controller.is_active()).is_false()


func test_escape_while_placed_drops_the_anchor_but_stays_armed() -> void:
	var controller := _armed()
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": 0, "face": 0, "t": 0.5}
	assert_int(controller.handle_input(null, _key(KEY_ESCAPE))).is_equal(1)
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.ARMED)
	assert_bool(controller._anchor.is_empty()).is_true()


func test_reset_anchor_returns_to_armed_without_leaving_the_tool() -> void:
	var controller := _armed()
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": 0, "face": 0, "t": 0.5}
	controller.reset_anchor()
	assert_bool(controller.is_active()).is_true()
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.ARMED)
	assert_bool(controller._anchor.is_empty()).is_true()


func test_reset_anchor_does_not_arm_an_idle_tool() -> void:
	var controller := GoBuildCutController.new()
	controller.reset_anchor()
	assert_bool(controller.is_active()).is_false()


func test_key_release_is_not_consumed() -> void:
	var controller := _armed()
	assert_int(controller.handle_input(null, _key(KEY_ESCAPE, false))).is_equal(0)
	assert_bool(controller.is_active()).is_true()


# ---------------------------------------------------------------------------
# Event routing — what the tool claims and what it lets through
# ---------------------------------------------------------------------------

func test_left_click_is_always_consumed() -> void:
	# Consumed even when nothing is under the cursor, so a stray click can never
	# fall through and change the selection.
	var controller := _armed()
	assert_int(controller.handle_input(null, _click(true))).is_equal(1)
	assert_int(controller.handle_input(null, _click(false))).is_equal(1)


func test_right_and_middle_clicks_pass_through_for_camera_navigation() -> void:
	var controller := _armed()
	assert_int(controller.handle_input(null, _click(true, MOUSE_BUTTON_RIGHT))).is_equal(0)
	assert_int(controller.handle_input(null, _click(true, MOUSE_BUTTON_MIDDLE))).is_equal(0)


func test_mouse_motion_is_not_consumed() -> void:
	var controller := _armed()
	assert_int(controller.handle_input(null, InputEventMouseMotion.new())).is_equal(0)


func test_click_with_nothing_pickable_leaves_the_state_alone() -> void:
	# No camera means _pick finds nothing; the tool must stay armed rather than
	# anchoring on garbage.
	var controller := _armed()
	controller.handle_input(null, _click(true))
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.ARMED)


# ---------------------------------------------------------------------------
# Candidate edges for the second cut point
# ---------------------------------------------------------------------------

func test_candidate_edges_cover_both_faces_around_an_interior_edge() -> void:
	var mesh := _make_mesh()
	var interior: int = mesh.find_edge(1, 2)
	var candidates: Array[Dictionary] = GoBuildCutController.candidate_edges(mesh, interior)
	# Two quads, 7 distinct edges total, minus the seed edge itself.
	assert_int(candidates.size()).is_equal(6)


func test_candidate_edges_exclude_the_seed_edge() -> void:
	var mesh := _make_mesh()
	var seed: int = mesh.find_edge(0, 1)
	for candidate in GoBuildCutController.candidate_edges(mesh, seed):
		assert_int(int(candidate["edge"])).is_not_equal(seed)


func test_each_candidate_names_a_face_that_owns_both_edges() -> void:
	var mesh := _make_mesh()
	var seed: int = mesh.find_edge(1, 2)
	for candidate in GoBuildCutController.candidate_edges(mesh, seed):
		var fi: int = int(candidate["face"])
		var face_edges: Array[int] = mesh.edges_of_face(fi)
		assert_bool(face_edges.has(seed)).is_true()
		assert_bool(face_edges.has(int(candidate["edge"]))).is_true()


func test_candidate_edges_of_a_boundary_edge_stay_on_its_one_face() -> void:
	var mesh := _make_mesh()
	var boundary: int = mesh.find_edge(3, 0)
	var candidates: Array[Dictionary] = GoBuildCutController.candidate_edges(mesh, boundary)
	assert_int(candidates.size()).is_equal(3)
	for candidate in candidates:
		assert_int(int(candidate["face"])).is_equal(0)


func test_candidate_edges_of_an_invalid_index_is_empty() -> void:
	var mesh := _make_mesh()
	assert_array(GoBuildCutController.candidate_edges(mesh, -1)).is_empty()
	assert_array(GoBuildCutController.candidate_edges(mesh, 999)).is_empty()
	assert_array(GoBuildCutController.candidate_edges(null, 0)).is_empty()


# ---------------------------------------------------------------------------
# Ctrl quarter-step snap
# ---------------------------------------------------------------------------

func test_snap_t_is_a_passthrough_without_the_modifier() -> void:
	assert_float(GoBuildCutController.snap_t(0.37, false)).is_equal_approx(0.37, 0.0001)


func test_snap_t_quantises_to_quarter_steps() -> void:
	assert_float(GoBuildCutController.snap_t(0.37, true)).is_equal_approx(0.25, 0.0001)
	assert_float(GoBuildCutController.snap_t(0.60, true)).is_equal_approx(0.5, 0.0001)
	assert_float(GoBuildCutController.snap_t(0.80, true)).is_equal_approx(0.75, 0.0001)


func test_snap_t_leaves_endpoints_exact() -> void:
	# Vertex snapping already landed the point on a corner; the modifier must
	# not nudge it back off.
	assert_float(GoBuildCutController.snap_t(0.0, true)).is_equal_approx(0.0, 0.0001)
	assert_float(GoBuildCutController.snap_t(1.0, true)).is_equal_approx(1.0, 0.0001)


# ---------------------------------------------------------------------------
# Commit
# ---------------------------------------------------------------------------

func test_commit_passes_the_face_and_both_cut_points_through() -> void:
	var received: Array = []
	var controller := _armed(func(
			face_index: int,
			edge_a: int,
			t_a: float,
			edge_b: int,
			t_b: float,
	) -> void:
		received.assign([face_index, edge_a, t_a, edge_b, t_b])
	)
	var mesh: GoBuildMesh = controller.get_node_target().go_build_mesh
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": mesh.find_edge(0, 1), "face": 0, "t": 0.25}
	controller._hover = {"edge": mesh.find_edge(2, 3), "face": 0, "t": 0.75}

	controller._commit()
	assert_array(received).is_equal(
			[0, mesh.find_edge(0, 1), 0.25, mesh.find_edge(2, 3), 0.75])


func test_commit_rearms_for_the_next_cut() -> void:
	var controller := _armed(func(_f: int, _a: int, _ta: float, _b: int, _tb: float) -> void:
		pass
	)
	var mesh: GoBuildMesh = controller.get_node_target().go_build_mesh
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": mesh.find_edge(0, 1), "face": 0, "t": 0.5}
	controller._hover = {"edge": mesh.find_edge(2, 3), "face": 0, "t": 0.5}

	controller._commit()
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.ARMED)
	assert_bool(controller._anchor.is_empty()).is_true()


func test_commit_is_refused_when_the_cut_would_be_rejected() -> void:
	# Both points land on the same corner — CutOperation would reject it, so the
	# tool must keep the anchor instead of firing a no-op action.
	var fired: Array[bool] = [false]
	var controller := _armed(func(_f: int, _a: int, _ta: float, _b: int, _tb: float) -> void:
		fired[0] = true
	)
	var mesh: GoBuildMesh = controller.get_node_target().go_build_mesh
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": mesh.find_edge(0, 1), "face": 0, "t": 1.0}
	controller._hover = {"edge": mesh.find_edge(1, 2), "face": 0, "t": 0.0}

	controller._commit()
	assert_bool(fired[0]).is_false()
	assert_int(controller.get_state()).is_equal(GoBuildCutController.CutState.PLACED)


# ---------------------------------------------------------------------------
# Pending validity and overlay data
# ---------------------------------------------------------------------------

func test_pending_is_never_valid_before_the_anchor_is_down() -> void:
	var controller := _armed()
	assert_bool(controller.is_pending_valid()).is_false()


func test_pending_is_valid_for_a_cut_the_operation_accepts() -> void:
	var controller := _armed()
	var mesh: GoBuildMesh = controller.get_node_target().go_build_mesh
	controller._state = GoBuildCutController.CutState.PLACED
	controller._anchor = {"edge": mesh.find_edge(0, 1), "face": 0, "t": 0.5}
	controller._hover = {"edge": mesh.find_edge(2, 3), "face": 0, "t": 0.5}
	assert_bool(controller.is_pending_valid()).is_true()


func test_overlay_data_is_empty_while_idle_or_without_a_camera() -> void:
	# No event has arrived, so no camera has been cached to project with.
	var idle := GoBuildCutController.new()
	assert_bool(idle.overlay_data().is_empty()).is_true()
	assert_bool(_armed().overlay_data().is_empty()).is_true()


func test_hint_text_names_the_step_the_tool_is_waiting_on() -> void:
	var controller := _armed()
	var armed_hint: String = controller.hint_text()
	assert_str(armed_hint).is_not_empty()
	controller._state = GoBuildCutController.CutState.PLACED
	assert_str(controller.hint_text()).is_not_equal(armed_hint)
	controller.cancel()
	assert_str(controller.hint_text()).is_empty()
