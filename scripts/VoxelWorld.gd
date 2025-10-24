@tool
extends Node

# VoxelWorld: Centralized GPU resource management and chunk coordination
# This singleton manages ONE shared RenderingDevice for all chunks
# Prevents GPU contention when generating multiple chunks

# Shared GPU resources
var rd: RenderingDevice
var generator_shader: RID
var mesher_shader: RID

# Chunk management
var chunks: Dictionary = {}  # Vector3i -> ChunkData
var generation_queue: Array = []  # Array of Vector3i positions to generate (GPU work)
var collision_queue: Array = []  # Array of {chunk_pos, mesh_data} for deferred collision (CPU work)

# Chunk decoding settings (CPU work for vertex unpacking)
var use_smooth_chunk_loading: bool = true  # Spread vertex decoding over frames (smooth) or instant (stutter)
@export_range(1, 100, 1) var chunk_decode_time_budget_percent: int = 10  # % of frame time budget for decoding (10% ≈ 1.6ms at 60fps)
@export var generate_collision: bool = false  # Generate collision mesh (WARNING: ~200ms per chunk, causes stutters)
@export_range(0, 10, 1) var collision_radius: int = 1  # Only generate collision within N chunks of player (0=disable, 1=nearby only)

# Player tracking (for distance-based collision)
var player_chunk_position: Vector3i = Vector3i(0, 0, 0)

# Incremental decoder (handles slow CPU decode work)
var chunk_decoder: Node = null

# Chunk parameters (shared by all chunks)
@export_range(8, 256, 8) var chunk_size: int = 80
@export_range(0.1, 10.0, 0.1) var voxel_size: float = 1.0
@export_range(0.001, 1.0, 0.001) var noise_scale: float = 0.1
@export_range(-20.0, 20.0, 0.1) var height_scale: float = 8.0
@export_range(0.005, 0.1, 0.005) var visibility_ratio: float = 0.01

# Constants for mesh generation
const BYTES_PER_FLOAT = 4
const FLOATS_PER_VERTEX = 8  # position(3) + normal(3) + uv(2)
const VERTICES_PER_CUBE = 24  # 6 faces * 4 vertices
const INDICES_PER_CUBE = 36   # 6 faces * 6 indices

# Signals
signal chunk_ready(chunk_pos: Vector3i, mesh_data: Dictionary, enable_collision: bool)
signal collision_ready(chunk_pos: Vector3i, mesh_data: Dictionary)

func _ready():
	print("🌍 VoxelWorld singleton initializing...")

	# Create ONE shared local RenderingDevice for all chunks
	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Failed to create shared RenderingDevice - compute shaders not supported")
		return
	print("✅ Shared RenderingDevice created successfully")

	# Load shaders once (shared by all chunks)
	if not load_shaders():
		push_error("Failed to load compute shaders")
		return
	print("✅ Shaders loaded successfully")

	# Create ChunkDecoder for incremental decoding with time budget
	var ChunkDecoderScript = load("res://scripts/ChunkDecoder.gd")
	chunk_decoder = ChunkDecoderScript.new()
	add_child(chunk_decoder)
	chunk_decoder.time_budget_percent = chunk_decode_time_budget_percent
	chunk_decoder.chunk_decoded.connect(_on_chunk_decoded)
	print("✅ ChunkDecoder initialized with ", chunk_decode_time_budget_percent, "% time budget")

	print("🎉 VoxelWorld ready - all chunks will share ONE RenderingDevice")

func _process(_delta):
	# Process generation queue (one chunk per frame)
	if generation_queue.size() > 0:
		var chunk_pos = generation_queue.pop_front()
		_generate_chunk_async(chunk_pos)

		# Status update
		if generation_queue.size() > 0 and generation_queue.size() % 10 == 0:
			print("📊 ", generation_queue.size(), " chunks remaining in generation queue")

	# Process collision queue (one collision per frame to avoid stutter)
	# This spreads the 389ms collision generation across frames
	if collision_queue.size() > 0 and generate_collision:
		var collision_job = collision_queue.pop_front()
		_generate_collision_for_chunk(collision_job.chunk_pos, collision_job.mesh_data)

func load_shaders() -> bool:
	# Load voxel generator shader
	var generator_file = load("res://shaders/voxel_generator.glsl")
	if not generator_file:
		push_error("Failed to load voxel_generator.glsl - check file path")
		return false

	var generator_spirv = generator_file.get_spirv()
	if not generator_spirv:
		push_error("Failed to get SPIRV from generator shader - check shader compilation")
		return false

	generator_shader = rd.shader_create_from_spirv(generator_spirv)
	if not generator_shader.is_valid():
		push_error("Failed to create generator shader on GPU")
		return false

	print("   Generator shader created successfully")

	# Load mesher shader
	var mesher_file = load("res://shaders/voxel_mesher.glsl")
	if not mesher_file:
		push_error("Failed to load voxel_mesher.glsl - check file path")
		return false

	var mesher_spirv = mesher_file.get_spirv()
	if not mesher_spirv:
		push_error("Failed to get SPIRV from mesher shader - check shader compilation")
		return false

	mesher_shader = rd.shader_create_from_spirv(mesher_spirv)
	if not mesher_shader.is_valid():
		push_error("Failed to create mesher shader on GPU")
		return false

	print("   Mesher shader created successfully")

	return true

func request_chunk(chunk_pos: Vector3i):
	"""Request generation of a chunk at given position"""
	# Check if chunk already exists or is queued
	if chunks.has(chunk_pos):
		return  # Already generated

	if chunk_pos in generation_queue:
		return  # Already queued

	# Add to generation queue
	generation_queue.append(chunk_pos)
	print("📋 Chunk ", chunk_pos, " added to generation queue (queue size: ", generation_queue.size(), ")")

func unload_chunk(chunk_pos: Vector3i):
	"""Unload a chunk and free its resources"""
	if not chunks.has(chunk_pos):
		return

	# Remove from chunks dictionary
	chunks.erase(chunk_pos)
	print("🗑️ Chunk ", chunk_pos, " unloaded")

func _generate_chunk_async(chunk_pos: Vector3i):
	"""Generate a single chunk asynchronously (called from _process)"""
	var start_time = Time.get_ticks_msec()

	print("🏗️ Generating chunk at ", chunk_pos)

	# Step 1: Generate voxel data
	var voxel_gen_start = Time.get_ticks_msec()
	var voxel_data_buffer = _generate_voxel_data(chunk_pos)
	if not voxel_data_buffer.is_valid():
		push_error("Failed to generate voxel data for chunk ", chunk_pos)
		return
	var voxel_gen_time = Time.get_ticks_msec() - voxel_gen_start

	# Step 2: Generate mesh from voxel data
	var mesh_gen_start = Time.get_ticks_msec()
	var mesh_data = _generate_mesh(voxel_data_buffer)
	if mesh_data.is_empty() or mesh_data.vertex_count == 0:
		# Empty chunk (no solid voxels) - this is normal for air chunks above ground
		# Just cleanup and skip without error
		if voxel_data_buffer.is_valid():
			rd.free_rid(voxel_data_buffer)
		# Mark as generated so we don't try again
		chunks[chunk_pos] = {
			"position": chunk_pos,
			"generated_at": Time.get_ticks_msec(),
			"empty": true
		}
		return
	var mesh_gen_time = Time.get_ticks_msec() - mesh_gen_start

	# Cleanup voxel buffer
	if voxel_data_buffer.is_valid():
		rd.free_rid(voxel_data_buffer)

	var total_time = Time.get_ticks_msec() - start_time
	print("✅ Chunk ", chunk_pos, " generated in ", total_time, "ms (Voxel=", voxel_gen_time, "ms, Mesh=", mesh_gen_time, "ms)")

	# Mark chunk as generated (GPU work complete)
	chunks[chunk_pos] = {
		"position": chunk_pos,
		"generated_at": Time.get_ticks_msec(),
		"gpu_complete": true,
		"decode_complete": false
	}

	# Pass to ChunkDecoder for incremental decode (slow CPU work)
	chunk_decoder.add_decode_job(chunk_pos, mesh_data, generate_collision)

func _generate_voxel_data(chunk_pos: Vector3i) -> RID:
	"""Generate voxel data for a chunk using GPU compute shader"""
	# Create buffers
	var voxel_count = chunk_size * chunk_size * chunk_size
	var voxel_buffer = rd.storage_buffer_create(voxel_count * 4) # 4 bytes per float

	if not voxel_buffer.is_valid():
		push_error("Failed to create voxel buffer")
		return RID()

	# Parameters buffer
	var params_data = PackedByteArray()
	params_data.resize(32) # vec3 + float + float + uint + padding

	# World position of this chunk (chunk_pos * chunk_size * voxel_size)
	var world_pos = Vector3(chunk_pos) * chunk_size * voxel_size
	params_data.encode_float(0, world_pos.x)
	params_data.encode_float(4, world_pos.y)
	params_data.encode_float(8, world_pos.z)
	params_data.encode_float(12, noise_scale)
	params_data.encode_float(16, height_scale)
	params_data.encode_u32(20, chunk_size)
	# 24-31 are padding bytes

	var params_buffer = rd.storage_buffer_create(params_data.size(), params_data)
	if not params_buffer.is_valid():
		push_error("Failed to create params buffer")
		if voxel_buffer.is_valid():
			rd.free_rid(voxel_buffer)
		return RID()

	# Create uniforms
	var voxel_uniform = RDUniform.new()
	voxel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	voxel_uniform.binding = 0
	voxel_uniform.add_id(voxel_buffer)

	var params_uniform = RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(params_buffer)

	var uniform_set = rd.uniform_set_create([voxel_uniform, params_uniform], generator_shader, 0)
	if not uniform_set.is_valid():
		push_error("Failed to create uniform set")
		if voxel_buffer.is_valid():
			rd.free_rid(voxel_buffer)
		if params_buffer.is_valid():
			rd.free_rid(params_buffer)
		return RID()

	# Create compute pipeline
	var pipeline = rd.compute_pipeline_create(generator_shader)
	if not pipeline.is_valid():
		push_error("Failed to create compute pipeline")
		if voxel_buffer.is_valid():
			rd.free_rid(voxel_buffer)
		if params_buffer.is_valid():
			rd.free_rid(params_buffer)
		return RID()

	# Execute compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	# Dispatch work groups
	var groups = ceili(float(chunk_size) / 8.0)
	rd.compute_list_dispatch(compute_list, groups, groups, groups)

	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# Cleanup
	if params_buffer.is_valid():
		rd.free_rid(params_buffer)
	if pipeline.is_valid():
		rd.free_rid(pipeline)

	return voxel_buffer

func _generate_mesh(voxel_data_buffer: RID) -> Dictionary:
	"""Generate mesh data from voxel data using GPU compute shader"""
	# Use visibility ratio to allocate buffers efficiently
	var vis_ratio = visibility_ratio if visibility_ratio else 0.01

	# Smaller chunks have higher surface-to-volume ratio, adjust visibility_ratio
	if chunk_size < 100:
		vis_ratio = 0.05 if chunk_size < 50 else 0.03

	var voxel_count = chunk_size * chunk_size * chunk_size
	var max_visible_voxels = int(voxel_count * vis_ratio)

	var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT
	var max_vertices = max_visible_voxels * VERTICES_PER_CUBE
	var max_indices = max_visible_voxels * INDICES_PER_CUBE

	var vertex_buffer = rd.storage_buffer_create(max_vertices * bytes_per_vertex)
	if not vertex_buffer.is_valid():
		push_error("Failed to create vertex buffer")
		return {}

	var index_buffer = rd.storage_buffer_create(max_indices * 4)
	if not index_buffer.is_valid():
		push_error("Failed to create index buffer")
		if vertex_buffer.is_valid():
			rd.free_rid(vertex_buffer)
		return {}

	# Counter buffer
	var counter_data = PackedByteArray()
	counter_data.resize(8) # 2 uints
	counter_data.encode_u32(0, 0) # vertex_count
	counter_data.encode_u32(4, 0) # index_count
	var counter_buffer = rd.storage_buffer_create(counter_data.size(), counter_data)
	if not counter_buffer.is_valid():
		push_error("Failed to create counter buffer")
		if vertex_buffer.is_valid():
			rd.free_rid(vertex_buffer)
		if index_buffer.is_valid():
			rd.free_rid(index_buffer)
		return {}

	# Parameters buffer
	var mesh_params_data = PackedByteArray()
	mesh_params_data.resize(8) # uint + float
	mesh_params_data.encode_u32(0, chunk_size)
	mesh_params_data.encode_float(4, voxel_size)
	var mesh_params_buffer = rd.storage_buffer_create(mesh_params_data.size(), mesh_params_data)
	if not mesh_params_buffer.is_valid():
		push_error("Failed to create mesh params buffer")
		if vertex_buffer.is_valid():
			rd.free_rid(vertex_buffer)
		if index_buffer.is_valid():
			rd.free_rid(index_buffer)
		if counter_buffer.is_valid():
			rd.free_rid(counter_buffer)
		return {}

	# Create uniforms
	var uniforms = []

	var voxel_uniform = RDUniform.new()
	voxel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	voxel_uniform.binding = 0
	voxel_uniform.add_id(voxel_data_buffer)
	uniforms.append(voxel_uniform)

	var vertex_uniform = RDUniform.new()
	vertex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_uniform.binding = 1
	vertex_uniform.add_id(vertex_buffer)
	uniforms.append(vertex_uniform)

	var index_uniform = RDUniform.new()
	index_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	index_uniform.binding = 2
	index_uniform.add_id(index_buffer)
	uniforms.append(index_uniform)

	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 3
	counter_uniform.add_id(counter_buffer)
	uniforms.append(counter_uniform)

	var params_uniform = RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 4
	params_uniform.add_id(mesh_params_buffer)
	uniforms.append(params_uniform)

	var uniform_set = rd.uniform_set_create(uniforms, mesher_shader, 0)
	if not uniform_set.is_valid():
		push_error("Failed to create uniform set for meshing")
		if vertex_buffer.is_valid(): rd.free_rid(vertex_buffer)
		if index_buffer.is_valid(): rd.free_rid(index_buffer)
		if counter_buffer.is_valid(): rd.free_rid(counter_buffer)
		if mesh_params_buffer.is_valid(): rd.free_rid(mesh_params_buffer)
		return {}

	# Create compute pipeline
	var pipeline = rd.compute_pipeline_create(mesher_shader)
	if not pipeline.is_valid():
		push_error("Failed to create meshing pipeline")
		if vertex_buffer.is_valid(): rd.free_rid(vertex_buffer)
		if index_buffer.is_valid(): rd.free_rid(index_buffer)
		if counter_buffer.is_valid(): rd.free_rid(counter_buffer)
		if mesh_params_buffer.is_valid(): rd.free_rid(mesh_params_buffer)
		return {}

	# Execute compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	# Dispatch work groups
	var groups = ceili(float(chunk_size) / 8.0)
	rd.compute_list_dispatch(compute_list, groups, groups, groups)

	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# Read back results
	var counter_result = rd.buffer_get_data(counter_buffer)
	var vertex_count = counter_result.decode_u32(0)
	var index_count = counter_result.decode_u32(4)

	# Safety: Clamp to buffer limits
	if vertex_count > max_vertices:
		print("⚠️ WARNING: GPU reported ", vertex_count, " vertices, clamping to ", max_vertices)
		vertex_count = max_vertices
	if index_count > max_indices:
		print("⚠️ WARNING: GPU reported ", index_count, " indices, clamping to ", max_indices)
		index_count = max_indices

	var vertex_data = rd.buffer_get_data(vertex_buffer)
	var index_data = rd.buffer_get_data(index_buffer)

	# Cleanup
	if vertex_buffer.is_valid(): rd.free_rid(vertex_buffer)
	if index_buffer.is_valid(): rd.free_rid(index_buffer)
	if counter_buffer.is_valid(): rd.free_rid(counter_buffer)
	if mesh_params_buffer.is_valid(): rd.free_rid(mesh_params_buffer)
	if pipeline.is_valid(): rd.free_rid(pipeline)

	return {
		"vertex_count": vertex_count,
		"index_count": index_count,
		"vertex_data": vertex_data,
		"index_data": index_data
	}

func _exit_tree():
	# Cleanup shared RenderingDevice resources
	if rd:
		if generator_shader.is_valid():
			rd.free_rid(generator_shader)
		if mesher_shader.is_valid():
			rd.free_rid(mesher_shader)
		rd.free()
		rd = null
	print("🌍 VoxelWorld singleton cleaned up")
func _on_chunk_decoded(chunk_pos: Vector3i, decoded_data: Dictionary):
	"""Called by ChunkDecoder when chunk decode is complete"""
	print("📦 Chunk ", chunk_pos, " decode complete, spawning...")

	# Mark chunk as fully complete
	if chunks.has(chunk_pos):
		chunks[chunk_pos]["decode_complete"] = true

	# Spawn visual chunk immediately WITHOUT collision (to avoid stutter)
	emit_signal("chunk_ready", chunk_pos, decoded_data, false)

	# Queue collision generation if enabled AND chunk is within collision_radius of player
	if decoded_data.enable_collision and generate_collision:
		var distance = _chunk_distance(chunk_pos, player_chunk_position)
		if collision_radius == 0:
			# Collision disabled globally
			print("   ⏭️ Collision skipped for chunk ", chunk_pos, " (collision_radius=0)")
		elif distance <= collision_radius:
			collision_queue.append({
				"chunk_pos": chunk_pos,
				"mesh_data": decoded_data
			})
			print("   ⏳ Collision queued for chunk ", chunk_pos, " (distance=", int(distance), ", ", collision_queue.size(), " in queue)")
		else:
			print("   ⏭️ Collision skipped for chunk ", chunk_pos, " (distance=", int(distance), " > collision_radius=", collision_radius, ")")

func _chunk_distance(a: Vector3i, b: Vector3i) -> float:
	"""Calculate distance between two chunk positions"""
	var diff = a - b
	return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)

func _generate_collision_for_chunk(chunk_pos: Vector3i, mesh_data: Dictionary):
	"""Generate collision for a chunk (called one per frame from _process)"""
	var collision_start = Time.get_ticks_msec()

	# Emit signal to add collision to existing chunk
	emit_signal("collision_ready", chunk_pos, mesh_data)

	var collision_time = Time.get_ticks_msec() - collision_start
	print("   🔷 Collision generated for chunk ", chunk_pos, " in ", collision_time, "ms (", collision_queue.size(), " remaining)")
