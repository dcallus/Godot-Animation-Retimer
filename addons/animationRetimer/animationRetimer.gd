@tool
extends EditorPlugin

var retime_button: Button
var check_timer: Timer
var monitor_timer: Timer
var current_animation: Animation
var last_step: float = 0.0
var skip_next_change: bool = false


func _enter_tree() -> void:
	retime_button = Button.new()
	retime_button.icon = get_editor_interface().get_base_control().get_theme_icon("Time", "EditorIcons")
	retime_button.tooltip_text = "Enable Retime on FPS change"
	retime_button.toggle_mode = true
	retime_button.flat = true
	retime_button.toggled.connect(_on_retime_toggled)

	check_timer = Timer.new()
	check_timer.wait_time = 0.5
	check_timer.timeout.connect(_try_inject_button)
	add_child(check_timer)
	check_timer.start()

	monitor_timer = Timer.new()
	monitor_timer.wait_time = 0.1
	monitor_timer.timeout.connect(_monitor_fps_change)
	add_child(monitor_timer)


func _exit_tree() -> void:
	if check_timer:
		check_timer.stop()
		check_timer.queue_free()

	if monitor_timer:
		monitor_timer.stop()
		monitor_timer.queue_free()

	if retime_button and retime_button.get_parent():
		retime_button.get_parent().remove_child(retime_button)
	if retime_button:
		retime_button.queue_free()


func _try_inject_button() -> void:
	if retime_button.get_parent():
		return

	var editor = get_editor_interface().get_base_control()
	var anim_editor = _find_node_by_class(editor, "AnimationPlayerEditor")

	if anim_editor:
		_inject_button_into_editor(anim_editor)
		check_timer.stop()


func _inject_button_into_editor(anim_editor: Control) -> void:
	var track_editor = _find_node_by_class(anim_editor, "AnimationTrackEditor")
	if not track_editor:
		push_warning("Retimer: Could not find AnimationTrackEditor")
		return

	var toolbar: HFlowContainer = null
	for child in track_editor.get_children():
		if child is HFlowContainer:
			toolbar = child
			break

	if not toolbar:
		push_warning("Retimer: Could not find bottom toolbar")
		return

	var insert_idx = _find_insert_before_fps(toolbar)
	toolbar.add_child(retime_button)
	toolbar.move_child(retime_button, insert_idx)
	print("Retimer: Button injected")


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str:
		return node
	for child in node.get_children():
		var result = _find_node_by_class(child, class_name_str)
		if result:
			return result
	return null


func _find_insert_before_fps(toolbar: HFlowContainer) -> int:
	for i in range(toolbar.get_child_count()):
		var child = toolbar.get_child(i)
		if child is Label and i + 1 < toolbar.get_child_count():
			if toolbar.get_child(i + 1).get_class() == "EditorSpinSlider":
				return i
	return toolbar.get_child_count()


func _on_retime_toggled(enabled: bool) -> void:
	if enabled:
		var anim = _get_current_animation()
		if anim:
			current_animation = anim
			last_step = anim.step
			monitor_timer.start()
			print("Retimer: Enabled (%.1f FPS)" % (1.0 / last_step if last_step > 0 else 0))
		else:
			retime_button.button_pressed = false
			push_warning("Retimer: No animation selected")
	else:
		monitor_timer.stop()
		current_animation = null
		last_step = 0.0
		print("Retimer: Disabled")


func _monitor_fps_change() -> void:
	if not retime_button.button_pressed:
		return

	if skip_next_change:
		skip_next_change = false
		if current_animation:
			last_step = current_animation.step
		return

	var anim = _get_current_animation()

	if anim != current_animation:
		if anim:
			current_animation = anim
			last_step = anim.step
			print("Retimer: Now watching animation at %.1f FPS" % (1.0 / last_step if last_step > 0 else 0))
		else:
			current_animation = null
			last_step = 0.0
		return

	if not current_animation:
		return

	var new_step = current_animation.step
	if new_step > 0 and last_step > 0 and not is_equal_approx(new_step, last_step):
		print("Retimer: FPS changed %.1f -> %.1f" % [1.0 / last_step, 1.0 / new_step])
		_retime_keyframes(current_animation, last_step, new_step)
		last_step = new_step
		skip_next_change = true


func _get_current_animation() -> Animation:
	var anim_player = _get_current_animation_player()
	if not anim_player:
		return null

	var anim_name = anim_player.current_animation
	if anim_name.is_empty():
		anim_name = anim_player.assigned_animation
	if anim_name.is_empty():
		return null

	return anim_player.get_animation(anim_name)


func _get_current_animation_player() -> AnimationPlayer:
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	for node in selected:
		if node is AnimationPlayer:
			return node

	var edited_root = get_editor_interface().get_edited_scene_root()
	if edited_root:
		return _find_animation_player(edited_root)
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result = _find_animation_player(child)
		if result:
			return result
	return null


func _retime_keyframes(animation: Animation, old_step: float, new_step: float) -> void:
	var old_length = animation.length
	var frame_count = round(old_length / old_step)
	var new_length = frame_count * new_step
	animation.length = new_length

	var track_count = animation.get_track_count()
	var retimed_count = 0

	for track_idx in range(track_count):
		var keys = []
		var key_count = animation.track_get_key_count(track_idx)

		for key_idx in range(key_count):
			var old_time = animation.track_get_key_time(track_idx, key_idx)
			var frame_number = round(old_time / old_step)
			var new_time = frame_number * new_step

			keys.append({
				"time": new_time,
				"value": animation.track_get_key_value(track_idx, key_idx),
				"transition": animation.track_get_key_transition(track_idx, key_idx)
			})

			if not is_equal_approx(old_time, new_time):
				retimed_count += 1

		for i in range(key_count - 1, -1, -1):
			animation.track_remove_key(track_idx, i)

		for key_data in keys:
			animation.track_insert_key(track_idx, key_data["time"], key_data["value"], key_data["transition"])

	animation.emit_changed()
	print("Retimer: Retimed %d keyframes, %.0f frames (%.3fs -> %.3fs)" % [retimed_count, frame_count, old_length, new_length])
