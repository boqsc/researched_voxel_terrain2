@tool
extends Node3D

# VoxelChunk: Individual chunk representation (just holds mesh + collision)
# Does NOT create RenderingDevice or do GPU work
# Receives mesh data from VoxelWorld and displays it

var chunk_position: Vector3i
var mesh_instance: MeshInstance3D
var state: ChunkState = ChunkState.UNLOADED

enum ChunkState {
	UNLOADED,
	QUEUED,
	GENERATING,
	READY
}

# Constants for mesh generation (must match VoxelWorld)
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

	# Position chunk in world (chunk_position * chunk_size * voxel_size)
	# This will be set when mesh data is applied
	name = "Chunk_%d_%d_%d" % [chunk_position.x, chunk_position.y, chunk_position.z]

func apply_mesh_data(mesh_data: Dictionary, enable_collision: bool = true):
	"""Apply mesh data received from VoxelWorld (supports both raw and pre-decoded data)"""
	if mesh_data.vertex_count == 0:
		push_error("Chunk ", chunk_position, " received empty mesh data")
		return

	var decode_start = Time.get_ticks_msec()

	var vertices: PackedVector3Array
	var normals: PackedVector3Array
	var uvs: PackedVector2Array
	var indices: PackedInt32Array

	# Check if data is pre-decoded (from ChunkDecoder) or raw GPU data
	if mesh_data.has("vertices"):
		# Pre-decoded data - just use it directly!
		vertices = mesh_data.vertices
		normals = mesh_data.normals
		uvs = mesh_data.uvs
		indices = mesh_data.indices
		print("   🎨 Chunk ", chunk_position, " using pre-decoded data (incremental decode)")
	else:
		# Raw GPU data - decode it now (old path, fast single-frame decode)
		var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT

		vertices = PackedVector3Array()
		normals = PackedVector3Array()
		uvs = PackedVector2Array()

		vertices.resize(mesh_data.vertex_count)
		normals.resize(mesh_data.vertex_count)
		uvs.resize(mesh_data.vertex_count)

		# Decode vertex data
		for i in range(mesh_data.vertex_count):
			var offset = i * bytes_per_vertex

			# Position (3 floats)
			var x = mesh_data.vertex_data.decode_float(offset)
			var y = mesh_data.vertex_data.decode_float(offset + BYTES_PER_FLOAT)
			var z = mesh_data.vertex_data.decode_float(offset + 2 * BYTES_PER_FLOAT)
			vertices[i] = Vector3(x, y, z)

			# Normal (3 floats)
			var nx = mesh_data.vertex_data.decode_float(offset + 3 * BYTES_PER_FLOAT)
			var ny = mesh_data.vertex_data.decode_float(offset + 4 * BYTES_PER_FLOAT)
			var nz = mesh_data.vertex_data.decode_float(offset + 5 * BYTES_PER_FLOAT)
			normals[i] = Vector3(nx, ny, nz)

			# UV (2 floats)
			var ux = mesh_data.vertex_data.decode_float(offset + 6 * BYTES_PER_FLOAT)
			var uy = mesh_data.vertex_data.decode_float(offset + 7 * BYTES_PER_FLOAT)
			uvs[i] = Vector2(ux, uy)

		# Create index array
		indices = PackedInt32Array()
		indices.resize(mesh_data.index_count)

		for i in range(mesh_data.index_count):
			indices[i] = mesh_data.index_data.decode_u32(i * 4)

		print("   🎨 Chunk ", chunk_position, " decoded in single frame (old path)")

	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create material once and reuse it for all chunks
	if not _cached_material:
		_cached_material = StandardMaterial3D.new()
		_cached_material.albedo_color = Color(0.6, 0.5, 0.4) # Simple earth/terrain color
		_cached_material.cull_mode = BaseMaterial3D.CULL_BACK

	mesh.surface_set_material(0, _cached_material)

	# Apply to mesh instance
	mesh_instance.mesh = mesh

	# Create collision (optional - disabled by default for smooth gameplay)
	var collision_time = 0
	if enable_collision:
		var collision_start = Time.get_ticks_msec()
		_create_simplified_collision(vertices, indices)
		collision_time = Time.get_ticks_msec() - collision_start

	var decode_time = Time.get_ticks_msec() - decode_start

	state = ChunkState.READY

	if enable_collision:
		print("   🎨 Chunk ", chunk_position, " mesh applied in ", decode_time, "ms (collision: ", collision_time, "ms)")
	else:
		print("   🎨 Chunk ", chunk_position, " mesh applied in ", decode_time, "ms (no collision)")

func _create_simplified_collision(vertices: PackedVector3Array, indices: PackedInt32Array):
	"""Create collision using simplified mesh (every Nth triangle) for better performance"""
	# Configuration: Use every Nth triangle (higher = faster but less accurate)
	# N=1: All triangles (slow, most accurate)
	# N=4: Every 4th triangle (4x faster, good enough for voxel terrain)
	# N=8: Every 8th triangle (8x faster, still reasonable)
	const TRIANGLE_SKIP = 4

	# Build simplified collision arrays (every Nth triangle)
	var collision_indices = PackedInt32Array()
	var triangle_count = indices.size() / 3

	# Map from old vertex indices to new collision vertex indices
	var vertex_map = {}  # old_index -> new_index
	var collision_vertices = PackedVector3Array()
	var next_vertex_index = 0

	# Process every Nth triangle
	for tri_idx in range(0, triangle_count, TRIANGLE_SKIP):
		var base_idx = tri_idx * 3

		# Get the 3 vertex indices for this triangle
		for i in range(3):
			var old_idx = indices[base_idx + i]

			# Add vertex if not already in collision mesh
			if not vertex_map.has(old_idx):
				collision_vertices.append(vertices[old_idx])
				vertex_map[old_idx] = next_vertex_index
				next_vertex_index += 1

			# Add mapped index to collision indices
			collision_indices.append(vertex_map[old_idx])

	# Create collision shape manually
	var shape = ConcavePolygonShape3D.new()

	# Convert to face array format (flat array of Vector3s, 3 per triangle)
	var faces = PackedVector3Array()
	for i in range(0, collision_indices.size(), 3):
		faces.append(collision_vertices[collision_indices[i]])
		faces.append(collision_vertices[collision_indices[i + 1]])
		faces.append(collision_vertices[collision_indices[i + 2]])

	shape.set_faces(faces)

	# Create static body and collision shape
	var static_body = StaticBody3D.new()
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = shape

	static_body.add_child(collision_shape)
	mesh_instance.add_child(static_body)

	var reduction = 100.0 * (1.0 - float(collision_indices.size()) / float(indices.size()))
	print("   🛡️ Collision: ", collision_vertices.size(), " vertices (", int(reduction), "% reduction)")

func cleanup():
	"""Cleanup chunk resources"""
	if mesh_instance:
		# Clean up collision bodies
		for child in mesh_instance.get_children():
			if child is StaticBody3D:
				child.queue_free()
		mesh_instance.queue_free()

	queue_free()
