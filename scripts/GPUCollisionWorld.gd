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
var chunk_voxel_data: Dictionary = {}  # Vector3i -> PackedFloat32Array (chunk_pos -> density data)
var world_size: Vector3i = Vector3i(10, 10, 10)  # Max chunks (expandable)
var chunk_size: int = 80
var voxel_size: float = 1.0
var needs_buffer_rebuild: bool = false

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

	# Get chunk parameters from VoxelWorld
	if VoxelWorld:
		chunk_size = VoxelWorld.chunk_size
		voxel_size = VoxelWorld.voxel_size

	# Create initial empty collision buffer
	_rebuild_collision_buffer()

	print("✅ GPUCollisionWorld ready (chunk_size=", chunk_size, ", voxel_size=", voxel_size, ")")

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
	if density_data.size() == 0:
		print("⚠️ GPUCollisionWorld: Received empty density data for chunk ", chunk_pos)
		return

	var expected_size = chunk_size * chunk_size * chunk_size
	if density_data.size() != expected_size:
		push_error("GPUCollisionWorld: Density data size mismatch. Expected ", expected_size, " got ", density_data.size())
		return

	# Store chunk data
	chunk_voxel_data[chunk_pos] = density_data

	# Expand world bounds if needed
	_expand_world_bounds(chunk_pos)

	# Mark for buffer rebuild
	needs_buffer_rebuild = true

	print("🎯 GPUCollisionWorld: Chunk ", chunk_pos, " collision data updated (", chunk_voxel_data.size(), " chunks total)")

func remove_chunk_data(chunk_pos: Vector3i):
	"""Remove voxel collision data for a chunk"""
	if chunk_voxel_data.has(chunk_pos):
		chunk_voxel_data.erase(chunk_pos)
		needs_buffer_rebuild = true
		print("🎯 GPUCollisionWorld: Chunk ", chunk_pos, " collision data removed")

func _expand_world_bounds(chunk_pos: Vector3i):
	"""Expand world size to accommodate new chunks"""
	var min_size = Vector3i(
		max(abs(chunk_pos.x) + 1, world_size.x),
		max(abs(chunk_pos.y) + 1, world_size.y),
		max(abs(chunk_pos.z) + 1, world_size.z)
	)

	if min_size != world_size:
		world_size = min_size
		print("   🌍 Expanded collision world size to ", world_size)

func _process(_delta):
	"""Rebuild collision buffer if chunks changed"""
	if needs_buffer_rebuild:
		_rebuild_collision_buffer()
		needs_buffer_rebuild = false

func _rebuild_collision_buffer():
	"""Rebuild entire GPU collision buffer from chunk data"""
	if not rd:
		return

	# Free old buffer
	if voxel_collision_buffer.is_valid():
		rd.free_rid(voxel_collision_buffer)

	# Calculate total size
	var total_voxels = world_size.x * world_size.y * world_size.z * chunk_size * chunk_size * chunk_size
	var buffer_size = total_voxels * 4  # 4 bytes per float

	# Create new buffer filled with -1.0 (empty)
	var buffer_data = PackedFloat32Array()
	buffer_data.resize(total_voxels)
	buffer_data.fill(-1.0)  # -1.0 = empty voxel

	# Fill in chunk data
	for chunk_pos in chunk_voxel_data.keys():
		var density_data = chunk_voxel_data[chunk_pos]
		_copy_chunk_to_buffer(chunk_pos, density_data, buffer_data)

	# Upload to GPU
	var buffer_bytes = buffer_data.to_byte_array()
	voxel_collision_buffer = rd.storage_buffer_create(buffer_bytes.size(), buffer_bytes)

	if not voxel_collision_buffer.is_valid():
		push_error("Failed to create voxel collision buffer")
		return

	print("   🎯 Rebuilt collision buffer: ", chunk_voxel_data.size(), " chunks, ", total_voxels, " voxels (", buffer_size / 1024 / 1024, " MB)")

func _copy_chunk_to_buffer(chunk_pos: Vector3i, density_data: PackedFloat32Array, buffer: PackedFloat32Array):
	"""Copy chunk voxel data into world buffer at correct position"""
	# Convert chunk position to offset chunk coordinates (handle negative coords)
	var offset_chunk = chunk_pos + Vector3i(world_size.x / 2, world_size.y / 2, world_size.z / 2)

	# Bounds check
	if (offset_chunk.x < 0 or offset_chunk.x >= world_size.x or
	    offset_chunk.y < 0 or offset_chunk.y >= world_size.y or
	    offset_chunk.z < 0 or offset_chunk.z >= world_size.z):
		print("⚠️ Chunk ", chunk_pos, " outside collision world bounds")
		return

	# Calculate chunk offset in buffer
	var voxels_per_chunk = chunk_size * chunk_size * chunk_size
	var world_stride_x = voxels_per_chunk
	var world_stride_y = voxels_per_chunk * world_size.x
	var world_stride_z = voxels_per_chunk * world_size.x * world_size.y

	var chunk_offset = offset_chunk.x * world_stride_x + offset_chunk.y * world_stride_y + offset_chunk.z * world_stride_z

	# Copy voxel data
	for i in range(density_data.size()):
		var buffer_index = chunk_offset + i
		if buffer_index < buffer.size():
			buffer[buffer_index] = density_data[i]

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

	# Use actual voxel collision buffer
	if not voxel_collision_buffer.is_valid():
		push_error("Voxel collision buffer not initialized!")
		return []

	# Create uniform set (must use RDUniform objects in Godot 4, not dictionaries)
	var uniforms = []

	# Binding 0: Voxel collision data (use actual buffer!)
	var uniform0 = RDUniform.new()
	uniform0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform0.binding = 0
	uniform0.add_id(voxel_collision_buffer)
	uniforms.append(uniform0)

	# Binding 1: Query buffer
	var uniform1 = RDUniform.new()
	uniform1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform1.binding = 1
	uniform1.add_id(query_buf)
	uniforms.append(uniform1)

	# Binding 2: Result buffer
	var uniform2 = RDUniform.new()
	uniform2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform2.binding = 2
	uniform2.add_id(result_buf)
	uniforms.append(uniform2)

	# Binding 3: Params buffer
	var uniform3 = RDUniform.new()
	uniform3.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform3.binding = 3
	uniform3.add_id(params_buf)
	uniforms.append(uniform3)

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

	# Cleanup (don't free voxel_collision_buffer - it's persistent!)
	# Note: In Godot 4, only free the buffers we explicitly created
	# Uniform sets and pipelines are auto-managed and shouldn't be freed
	rd.free_rid(query_buf)
	rd.free_rid(result_buf)
	rd.free_rid(params_buf)

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
