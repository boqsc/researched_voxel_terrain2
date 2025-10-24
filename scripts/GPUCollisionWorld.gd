extends Node

# GPUCollisionWorld: GPU-based collision detection system
# Allows CharacterBody3D and RigidBody3D to query collision on GPU
# Bridges GPU compute results to CPU physics system

signal collision_results_ready

# GPU resources
var rd: RenderingDevice
var collision_shader: RID
var voxel_collision_buffer: RID  # Stores all voxel density data

# Collision query/result buffers
var query_buffer: RID
var result_buffer: RID
var params_buffer: RID

# Collision data
var voxel_data: PackedFloat32Array  # Flat array of all voxel densities
var world_size: Vector3i = Vector3i(10, 10, 10)  # Chunks
var chunk_size: int = 80
var voxel_size: float = 1.0

# Query tracking
var pending_queries: Array = []  # Array of {type, origin, direction, distance, radius, callback}
var query_results: Array = []

func _ready():
	print("🎯 GPUCollisionWorld initializing...")

	# Use shared RenderingDevice from VoxelWorld
	if VoxelWorld and VoxelWorld.rd:
		rd = VoxelWorld.rd
	else:
		rd = RenderingServer.create_local_rendering_device()

	if not rd:
		push_error("Failed to create RenderingDevice for GPU collision")
		return

	# Load collision shader
	if not _load_collision_shader():
		push_error("Failed to load GPU collision shader")
		return

	print("✅ GPUCollisionWorld ready")

func _load_collision_shader() -> bool:
	var shader_file = load("res://shaders/gpu_collision.glsl")
	if not shader_file:
		push_error("Failed to load gpu_collision.glsl")
		return false

	var spirv = shader_file.get_spirv()
	if not spirv:
		push_error("Failed to compile GPU collision shader")
		return false

	collision_shader = rd.shader_create_from_spirv(spirv)
	if not collision_shader.is_valid():
		push_error("Failed to create GPU collision shader")
		return false

	print("   ✅ GPU collision shader loaded")
	return true

func update_voxel_data(chunk_pos: Vector3i, density_data: PackedFloat32Array):
	"""Update voxel collision data for a chunk"""
	# TODO: Implement incremental updates
	# For now, we'd rebuild the entire buffer when chunks change
	pass

func raycast(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Dictionary:
	"""Perform GPU raycast - returns {hit: bool, position: Vector3, normal: Vector3, distance: float}"""
	var queries = PackedFloat32Array()
	queries.resize(9)
	queries[0] = 0.0  # QUERY_RAYCAST
	queries[1] = origin.x
	queries[2] = origin.y
	queries[3] = origin.z
	queries[4] = direction.x
	queries[5] = direction.y
	queries[6] = direction.z
	queries[7] = max_distance
	queries[8] = 0.0  # radius (unused for raycast)

	var result = _execute_queries(queries, 1)
	if result.size() > 0:
		return result[0]
	return {"hit": false, "distance": max_distance}

func sphere_cast(origin: Vector3, direction: Vector3, radius: float, max_distance: float = 100.0) -> Dictionary:
	"""Perform GPU sphere cast - returns {hit: bool, position: Vector3, normal: Vector3, distance: float}"""
	var queries = PackedFloat32Array()
	queries.resize(9)
	queries[0] = 1.0  # QUERY_SPHERE_CAST
	queries[1] = origin.x
	queries[2] = origin.y
	queries[3] = origin.z
	queries[4] = direction.x
	queries[5] = direction.y
	queries[6] = direction.z
	queries[7] = max_distance
	queries[8] = radius

	var result = _execute_queries(queries, 1)
	if result.size() > 0:
		return result[0]
	return {"hit": false, "distance": max_distance}

func overlap_sphere(position: Vector3, radius: float) -> bool:
	"""Check if sphere overlaps any voxels (for ground detection, etc.)"""
	# Perform downward raycast with radius
	var result = sphere_cast(position, Vector3.DOWN, radius, radius * 2.0)
	return result.hit

func _execute_queries(query_data: PackedFloat32Array, query_count: int) -> Array:
	"""Execute collision queries on GPU and return results"""
	if not rd or not collision_shader.is_valid():
		return []

	# Create query buffer
	var query_bytes = query_data.to_byte_array()
	var query_buf = rd.storage_buffer_create(query_bytes.size(), query_bytes)

	# Create result buffer (8 floats per result)
	var result_size = query_count * 8 * 4  # 8 floats * 4 bytes
	var result_buf = rd.storage_buffer_create(result_size)

	# Create params buffer
	var params_data = PackedByteArray()
	params_data.resize(24)  # 6 uints
	params_data.encode_u32(0, query_count)
	params_data.encode_u32(4, world_size.x)
	params_data.encode_u32(8, world_size.y)
	params_data.encode_u32(12, world_size.z)
	params_data.encode_u32(16, chunk_size)
	params_data.encode_float(20, voxel_size)

	var params_buf = rd.storage_buffer_create(params_data.size(), params_data)

	# Create dummy voxel buffer (empty for now)
	# TODO: Populate with actual voxel data from chunks
	var voxel_count = world_size.x * world_size.y * world_size.z * chunk_size * chunk_size * chunk_size
	var voxel_buf = rd.storage_buffer_create(voxel_count * 4)  # 4 bytes per float

	# Create uniform set
	var uniforms = []

	# Binding 0: Voxel collision data
	uniforms.append({
		"binding": 0,
		"uniform_type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		"ids": [voxel_buf]
	})

	# Binding 1: Query buffer
	uniforms.append({
		"binding": 1,
		"uniform_type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		"ids": [query_buf]
	})

	# Binding 2: Result buffer
	uniforms.append({
		"binding": 2,
		"uniform_type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		"ids": [result_buf]
	})

	# Binding 3: Params buffer
	uniforms.append({
		"binding": 3,
		"uniform_type": RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,
		"ids": [params_buf]
	})

	var uniform_set = rd.uniform_set_create(uniforms, collision_shader, 0)

	# Create pipeline
	var pipeline = rd.compute_pipeline_create(collision_shader)

	# Dispatch compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	var groups_x = int(ceil(float(query_count) / 8.0))
	rd.compute_list_dispatch(compute_list, groups_x, 1, 1)
	rd.compute_list_end()

	# Submit and wait
	rd.submit()
	rd.sync()

	# Read results
	var result_bytes = rd.buffer_get_data(result_buf)

	# Cleanup
	rd.free_rid(query_buf)
	rd.free_rid(result_buf)
	rd.free_rid(params_buf)
	rd.free_rid(voxel_buf)
	rd.free_rid(uniform_set)
	rd.free_rid(pipeline)

	# Parse results
	var results = []
	for i in range(query_count):
		var offset = i * 8 * 4  # 8 floats * 4 bytes
		var hit = result_bytes.decode_float(offset) > 0.5
		var position = Vector3(
			result_bytes.decode_float(offset + 4),
			result_bytes.decode_float(offset + 8),
			result_bytes.decode_float(offset + 12)
		)
		var normal = Vector3(
			result_bytes.decode_float(offset + 16),
			result_bytes.decode_float(offset + 20),
			result_bytes.decode_float(offset + 24)
		)
		var distance = result_bytes.decode_float(offset + 28)

		results.append({
			"hit": hit,
			"position": position,
			"normal": normal,
			"distance": distance
		})

	return results

func _exit_tree():
	if rd:
		if collision_shader.is_valid():
			rd.free_rid(collision_shader)
	print("🎯 GPUCollisionWorld cleaned up")
