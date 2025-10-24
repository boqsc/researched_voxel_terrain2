extends CharacterBody3D

# GPUCharacterBody3D: CharacterBody3D with GPU collision support
# Uses GPU-based raycasts for movement and collision detection
# Faster than CPU collision for large voxel worlds

@export var use_gpu_collision: bool = true  # Toggle GPU vs CPU collision
@export var collision_radius: float = 0.5  # Character capsule radius
@export var collision_height: float = 2.0  # Character capsule height

# Movement
@export var move_speed: float = 5.0
@export var jump_velocity: float = 4.5

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var gpu_collision: Node  # GPUCollisionWorld singleton

func _ready():
	# Get GPU collision singleton
	if has_node("/root/GPUCollisionWorld"):
		gpu_collision = get_node("/root/GPUCollisionWorld")
		print("✅ GPUCharacterBody3D connected to GPU collision")
	else:
		push_warning("GPUCollisionWorld not found - using CPU collision")
		use_gpu_collision = false

func _physics_process(delta):
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	# Get input direction
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)

	# Move with GPU collision if enabled
	if use_gpu_collision and gpu_collision:
		_gpu_move_and_slide(delta)
	else:
		# Fall back to standard CPU collision
		move_and_slide()

func _gpu_move_and_slide(delta: float):
	"""Custom move_and_slide using GPU collision queries"""
	var motion = velocity * delta

	# Ground check (sphere cast downward)
	var ground_check = gpu_collision.sphere_cast(
		global_position,
		Vector3.DOWN,
		collision_radius,
		collision_height * 0.5 + 0.1
	)

	if ground_check.hit:
		# On ground - snap to surface
		if velocity.y <= 0:
			global_position.y = ground_check.position.y + collision_height * 0.5
			velocity.y = 0

	# Forward collision check
	if motion.length() > 0.01:
		var forward_check = gpu_collision.sphere_cast(
			global_position,
			motion.normalized(),
			collision_radius,
			motion.length() + collision_radius
		)

		if forward_check.hit:
			# Hit wall - slide along it
			var slide_direction = motion.slide(forward_check.normal)
			motion = slide_direction

	# Apply motion
	global_position += motion

	# Update velocity based on actual movement
	if delta > 0:
		velocity = motion / delta

func is_on_floor() -> bool:
	"""GPU-based floor detection"""
	if use_gpu_collision and gpu_collision:
		return gpu_collision.overlap_sphere(
			global_position,
			collision_radius
		)
	else:
		# Fall back to standard method
		return super.is_on_floor()

func get_floor_normal() -> Vector3:
	"""Get floor normal using GPU raycast"""
	if use_gpu_collision and gpu_collision:
		var result = gpu_collision.raycast(
			global_position,
			Vector3.DOWN,
			collision_height * 0.5 + 1.0
		)
		if result.hit:
			return result.normal
	return Vector3.UP
