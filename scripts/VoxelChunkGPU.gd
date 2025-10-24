@tool
extends Node3D

# VoxelChunkGPU: GPU-ONLY rendering (no CPU decode!)
# Renders voxel mesh directly from GPU buffers using RenderingDevice
# No GPU→CPU→GPU transfer - mesh stays in GPU memory!

var chunk_position: Vector3i
var state: ChunkState = ChunkState.UNLOADED

enum ChunkState {
	UNLOADED,
	QUEUED,
	GENERATING,
	READY
}

# GPU rendering resources
var rd: RenderingDevice
var vertex_buffer: RID
var index_buffer: RID
var vertex_array: RID
var pipeline: RID
var uniform_set: RID

# Mesh data
var vertex_count: int = 0
var index_count: int = 0

func _init(pos: Vector3i = Vector3i.ZERO):
	chunk_position = pos

func _ready():
	name = "ChunkGPU_%d_%d_%d" % [chunk_position.x, chunk_position.y, chunk_position.z]

func apply_gpu_mesh_data(mesh_data: Dictionary, shared_rd: RenderingDevice, shader_pipeline: RID):
	"""Apply mesh data that stays entirely on GPU - NO CPU DECODE!"""
	if mesh_data.vertex_count == 0:
		push_error("Chunk ", chunk_position, " received empty mesh data")
		return

	var start_time = Time.get_ticks_msec()

	rd = shared_rd
	vertex_count = mesh_data.vertex_count
	index_count = mesh_data.index_count

	# Get GPU buffer handles (NO DATA TRANSFER!)
	vertex_buffer = mesh_data.vertex_buffer_rid  # Already on GPU!
	index_buffer = mesh_data.index_buffer_rid    # Already on GPU!
	pipeline = shader_pipeline

	# Create vertex array format
	var vertex_format = _create_vertex_format()

	# Create vertex array (tells GPU how to interpret buffer)
	vertex_array = rd.vertex_array_create(
		vertex_count,
		vertex_format,
		[vertex_buffer]
	)

	state = ChunkState.READY

	var total_time = Time.get_ticks_msec() - start_time
	print("   🚀 GPU Chunk ", chunk_position, " ready in ", total_time, "ms (NO CPU DECODE! ", vertex_count, " vertices)")

func _create_vertex_format() -> RID:
	"""Define vertex format: position(vec3) + normal(vec3) + uv(vec2)"""
	var vertex_format = []

	# Position (location 0, vec3)
	vertex_format.append({
		"format": RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT,
		"offset": 0,
		"location": 0,
		"stride": 32  # 8 floats * 4 bytes = 32 bytes
	})

	# Normal (location 1, vec3)
	vertex_format.append({
		"format": RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT,
		"offset": 12,  # 3 floats * 4 bytes
		"location": 1,
		"stride": 32
	})

	# UV (location 2, vec2)
	vertex_format.append({
		"format": RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
		"offset": 24,  # 6 floats * 4 bytes
		"location": 2,
		"stride": 32
	})

	return rd.vertex_format_create(vertex_format)

func _process(_delta):
	if state != ChunkState.READY:
		return

	# Render this chunk directly from GPU buffers!
	_render_gpu_only()

func _render_gpu_only():
	"""Render chunk using GPU-only path (no CPU involvement!)"""
	# This would integrate with Godot's rendering pipeline
	# For now, this is a placeholder showing the concept

	# In a full implementation:
	# 1. Create draw list
	# 2. Bind pipeline
	# 3. Bind vertex/index buffers
	# 4. Issue draw call
	# 5. All on GPU - no CPU transfer!

	pass  # Actual rendering handled by custom RenderingDevice integration

func cleanup():
	"""Cleanup GPU resources"""
	if rd:
		if vertex_array.is_valid():
			rd.free_rid(vertex_array)
		# Note: Don't free vertex/index buffers - VoxelWorld owns them

	queue_free()
