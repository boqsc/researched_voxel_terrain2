extends CharacterBody3D

@export var movement_speed: float = 5.0
@export var jump_velocity: float = 8.0
@export var mouse_sensitivity: float = 0.002
@export var interaction_range: float = 10.0
@export var dig_radius: int = 2
@export var place_radius: int = 1

@onready var camera: Camera3D = $Camera3D
var voxel_terrain: Node3D

func _ready():
	# Find the voxel terrain in the scene
	voxel_terrain = get_tree().get_first_node_in_group("voxel_terrain")
	if not voxel_terrain:
		push_warning("No voxel terrain found in scene. Make sure VoxelTerrain node is in 'voxel_terrain' group.")

	# Position player safely above terrain to prevent spawning inside
	# Give terrain a moment to generate, then move player up
	await get_tree().create_timer(0.1).timeout
	global_position.y = 200.0  # Safe height above terrain

	# Capture mouse for first-person controls
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	print("✅ Player initialized, terrain: ", voxel_terrain != null)

func _input(event):
	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# Rotate player body left/right
		rotate_y(-event.relative.x * mouse_sensitivity)
		# Rotate camera up/down
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		# Clamp camera rotation
		camera.rotation.x = clamp(camera.rotation.x, -PI/2, PI/2)
	
	# Toggle mouse capture
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Terrain interaction
	if event.is_action_pressed("interact_primary"):
		interact_with_terrain(true)  # Dig/remove terrain
	elif event.is_action_pressed("interact_secondary"):
		interact_with_terrain(false)  # Place/add terrain

func _physics_process(delta):
	# Handle gravity
	if not is_on_floor():
		velocity += get_gravity() * delta
	
	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity
	
	# Handle movement
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction:
		velocity.x = direction.x * movement_speed
		velocity.z = direction.z * movement_speed
	else:
		velocity.x = move_toward(velocity.x, 0, movement_speed)
		velocity.z = move_toward(velocity.z, 0, movement_speed)
	
	move_and_slide()

func interact_with_terrain(is_digging: bool):
	if not voxel_terrain or not voxel_terrain.has_method("raycast_terrain"):
		print("❌ No voxel terrain available for interaction")
		return
	
	# Cast ray from camera to find terrain intersection
	var from = camera.global_position
	var to = from + camera.global_transform.basis.z * -interaction_range
	
	var result = voxel_terrain.raycast_terrain(from, to)
	if result.is_empty():
		print("💨 No terrain hit by ray")
		return
	
	var hit_position = result.position
	var hit_normal = result.normal
	
	# Determine modification position
	var modification_pos: Vector3
	if is_digging:
		# Dig slightly into the surface
		modification_pos = hit_position - hit_normal * 0.5
	else:
		# Place slightly above the surface
		modification_pos = hit_position + hit_normal * 0.5
	
	# Perform terrain modification
	if voxel_terrain.has_method("modify_terrain_at_position"):
		var radius = dig_radius if is_digging else place_radius
		var density_change = -5.0 if is_digging else 5.0
		var modification_type = 2 if is_digging else 1  # subtract or add
		
		var success = voxel_terrain.modify_terrain_at_position(
			modification_pos,
			radius,
			density_change,
			modification_type
		)
		
		if success:
			var action = "🗿 Dug" if is_digging else "🧱 Placed"
			print(action, " terrain at ", modification_pos, " with radius ", radius)
		else:
			print("❌ Failed to modify terrain")
	else:
		print("❌ VoxelTerrain doesn't support modify_terrain_at_position method")

# Debug function to show performance stats
func _on_stats_timer():
	if voxel_terrain and voxel_terrain.has_method("get_performance_stats"):
		var stats = voxel_terrain.get_performance_stats()
		print("📊 Terrain Stats: ", stats)

func _ready_add_stats_timer():
	# Add optional stats timer for debugging
	var timer = Timer.new()
	timer.wait_time = 5.0
	timer.timeout.connect(_on_stats_timer)
	timer.autostart = true
	add_child(timer)
