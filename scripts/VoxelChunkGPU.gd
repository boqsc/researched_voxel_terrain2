@tool
extends Node3D

# VoxelChunkGPU: Fast GPU-to-mesh path (no incremental decode!)
# Renders voxel chunks instantly by skipping time-budgeted decode
# Trades stutter for instant appearance - good for high-performance scenarios

var chunk_position: Vector3i
var mesh_instance: MeshInstance3D
var state: ChunkState = ChunkState.UNLOADED

enum ChunkState {
	UNLOADED,
	QUEUED,
	GENERATING,
	READY
}

# Constants for mesh generation
const BYTES_PER_FLOAT = 4
const FLOATS_PER_VERTEX = 8  # position(3) + normal(3) + uv(2)

# Cached material (shared by all chunks)
static var _cached_material: StandardMaterial3D = null

func _init(pos: Vector3i = Vector3i.ZERO):
	chunk_position = pos

func _ready():
	# Create mesh instance
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)
	name = "ChunkGPU_%d_%d_%d" % [chunk_position.x, chunk_position.y, chunk_position.z]

func apply_gpu_mesh_data(mesh_data: Dictionary, shared_rd: RenderingDevice, _shader_pipeline = null):
	"""Apply GPU mesh data - FAST PATH (no incremental decode!)"""
	if mesh_data.vertex_count == 0:
		push_error("Chunk ", chunk_position, " received empty mesh data")
		return

	var start_time = Time.get_ticks_msec()

	var vertex_count = mesh_data.vertex_count
	var index_count = mesh_data.index_count

	# Get GPU buffer RIDs
	var vertex_buffer_rid = mesh_data.vertex_buffer_rid
	var index_buffer_rid = mesh_data.index_buffer_rid

	# FAST PATH: Copy GPU buffer to CPU in one shot (no decode loop!)
	var vertex_data = shared_rd.buffer_get_data(vertex_buffer_rid)
	var index_data = shared_rd.buffer_get_data(index_buffer_rid)

	# Now decode ALL vertices at once (no time budget, just do it!)
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()

	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	uvs.resize(vertex_count)
	indices.resize(index_count)

	var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT

	# Decode all vertices in one go (no time budgeting)
	for i in range(vertex_count):
		var offset = i * bytes_per_vertex

		# Position
		var x = vertex_data.decode_float(offset)
		var y = vertex_data.decode_float(offset + BYTES_PER_FLOAT)
		var z = vertex_data.decode_float(offset + 2 * BYTES_PER_FLOAT)
		vertices[i] = Vector3(x, y, z)

		# Normal
		var nx = vertex_data.decode_float(offset + 3 * BYTES_PER_FLOAT)
		var ny = vertex_data.decode_float(offset + 4 * BYTES_PER_FLOAT)
		var nz = vertex_data.decode_float(offset + 5 * BYTES_PER_FLOAT)
		normals[i] = Vector3(nx, ny, nz)

		# UV
		var ux = vertex_data.decode_float(offset + 6 * BYTES_PER_FLOAT)
		var uy = vertex_data.decode_float(offset + 7 * BYTES_PER_FLOAT)
		uvs[i] = Vector2(ux, uy)

	# Decode indices
	for i in range(index_count):
		indices[i] = index_data.decode_u32(i * 4)

	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create material once and reuse
	if not _cached_material:
		_cached_material = StandardMaterial3D.new()
		_cached_material.albedo_color = Color(0.8, 0.6, 0.4) # Brighter for GPU mode
		_cached_material.cull_mode = BaseMaterial3D.CULL_BACK

	mesh.surface_set_material(0, _cached_material)
	mesh_instance.mesh = mesh

	state = ChunkState.READY

	var total_time = Time.get_ticks_msec() - start_time
	print("   🚀 GPU Chunk ", chunk_position, " rendered in ", total_time, "ms (fast path, no time budget)")

func cleanup():
	"""Cleanup chunk resources"""
	if mesh_instance:
		mesh_instance.queue_free()
	queue_free()
