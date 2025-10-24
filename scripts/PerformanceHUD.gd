extends Control

# PerformanceHUD: Shows real-time performance stats for GPU collision testing

@onready var fps_label: Label
@onready var collision_label: Label
@onready var chunk_label: Label
@onready var mode_label: Label

var frame_times: Array = []
var collision_times: Array = []
var max_samples: int = 60

func _ready():
	# Create HUD UI
	_create_ui()
	print("📊 Performance HUD initialized")

func _create_ui():
	# Container
	var panel = PanelContainer.new()
	panel.position = Vector2(10, 10)
	panel.size = Vector2(300, 200)
	add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Title
	var title = Label.new()
	title.text = "=== GPU COLLISION PERFORMANCE ==="
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	# FPS
	fps_label = Label.new()
	fps_label.text = "FPS: --"
	vbox.add_child(fps_label)

	# Mode
	mode_label = Label.new()
	mode_label.text = "Mode: --"
	vbox.add_child(mode_label)

	# Collision
	collision_label = Label.new()
	collision_label.text = "Collision: --"
	vbox.add_child(collision_label)

	# Chunks
	chunk_label = Label.new()
	chunk_label.text = "Chunks: --"
	vbox.add_child(chunk_label)

	# Instructions
	var spacer = Label.new()
	spacer.text = ""
	vbox.add_child(spacer)

	var instructions = Label.new()
	instructions.text = "WASD/Arrows: Move\nSpace: Jump\nESC: Quit\n\nToggle GPU collision in\nplayer inspector"
	instructions.add_theme_font_size_override("font_size", 12)
	vbox.add_child(instructions)

func _process(delta):
	# Track frame time
	frame_times.append(delta)
	if frame_times.size() > max_samples:
		frame_times.pop_front()

	# Calculate average FPS
	var avg_delta = 0.0
	for dt in frame_times:
		avg_delta += dt
	avg_delta /= frame_times.size()
	var fps = 1.0 / avg_delta if avg_delta > 0 else 0

	# Update FPS label
	fps_label.text = "FPS: %d (%.1f ms/frame)" % [int(fps), avg_delta * 1000.0]

	# Color code FPS
	if fps >= 55:
		fps_label.add_theme_color_override("font_color", Color.GREEN)
	elif fps >= 30:
		fps_label.add_theme_color_override("font_color", Color.YELLOW)
	else:
		fps_label.add_theme_color_override("font_color", Color.RED)

	# Get GPU collision stats
	if has_node("/root/GPUCollisionWorld"):
		var gpu_collision = get_node("/root/GPUCollisionWorld")
		var chunk_count = gpu_collision.chunk_voxel_data.size()
		var world_size = gpu_collision.world_size

		chunk_label.text = "Chunks: %d (World: %dx%dx%d)" % [
			chunk_count,
			world_size.x,
			world_size.y,
			world_size.z
		]
	else:
		chunk_label.text = "Chunks: GPUCollisionWorld not found!"
		chunk_label.add_theme_color_override("font_color", Color.RED)

	# Check player mode
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("is_on_floor"):
		var using_gpu = player.get("use_gpu_collision")
		if using_gpu != null:
			if using_gpu:
				mode_label.text = "Mode: GPU Collision ✓"
				mode_label.add_theme_color_override("font_color", Color.CYAN)
			else:
				mode_label.text = "Mode: CPU Collision"
				mode_label.add_theme_color_override("font_color", Color.ORANGE)
		else:
			mode_label.text = "Mode: Standard CharacterBody3D"
	else:
		mode_label.text = "Mode: No player found"

	# Collision query stats (placeholder - would need instrumentation)
	collision_label.text = "Collision: GPU queries active"

func _input(event):
	if event.is_action_pressed("ui_cancel"):
		print("ESC pressed - quitting")
		get_tree().quit()
