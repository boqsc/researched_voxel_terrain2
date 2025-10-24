extends RigidBody3D

# GPURigidBody3D: RigidBody3D with GPU collision support
# Uses GPU raycasts to inform physics simulation
# Hybrid approach: GPU queries + CPU physics integration

@export var use_gpu_collision: bool = true
@export var collision_radius: float = 0.5
@export var bounce_factor: float = 0.3
@export var friction_factor: float = 0.8

var gpu_collision: Node
var prev_position: Vector3

func _ready():
	# Get GPU collision singleton
	if has_node("/root/GPUCollisionWorld"):
		gpu_collision = get_node("/root/GPUCollisionWorld")
		print("✅ GPURigidBody3D connected to GPU collision")
	else:
		push_warning("GPUCollisionWorld not found - using CPU collision")
		use_gpu_collision = false

	prev_position = global_position

func _physics_process(delta):
	if not use_gpu_collision or not gpu_collision:
		return

	# Get movement vector
	var movement = global_position - prev_position
	prev_position = global_position

	if movement.length() < 0.001:
		return

	# GPU sphere cast in movement direction
	var collision_check = gpu_collision.sphere_cast(
		global_position,
		movement.normalized(),
		collision_radius,
		movement.length() + collision_radius
	)

	if collision_check.hit:
		# Calculate collision response
		var normal = collision_check.normal
		var velocity = linear_velocity

		# Bounce off surface
		var reflect_velocity = velocity.bounce(normal) * bounce_factor

		# Apply friction
		var tangent_velocity = velocity - velocity.project(normal)
		tangent_velocity *= friction_factor

		# Set new velocity
		linear_velocity = reflect_velocity + tangent_velocity

		# Position correction (move back from collision)
		var penetration = (global_position - collision_check.position).length()
		if penetration < collision_radius:
			global_position = collision_check.position + normal * collision_radius

func apply_gpu_impulse(impulse: Vector3, position_offset: Vector3 = Vector3.ZERO):
	"""Apply impulse with GPU collision preview"""
	if use_gpu_collision and gpu_collision:
		# Check if impulse would cause collision
		var check_result = gpu_collision.raycast(
			global_position,
			impulse.normalized(),
			impulse.length()
		)

		if check_result.hit:
			# Adjust impulse to slide along surface
			impulse = impulse.slide(check_result.normal)

	# Apply impulse using standard physics
	apply_impulse(impulse, position_offset)

func is_on_ground() -> bool:
	"""Check if rigid body is resting on ground using GPU"""
	if use_gpu_collision and gpu_collision:
		var ground_check = gpu_collision.raycast(
			global_position,
			Vector3.DOWN,
			collision_radius + 0.1
		)
		return ground_check.hit
	return false
