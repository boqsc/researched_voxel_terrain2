@tool
extends Node3D

# Basic constants for mesh generation
const BYTES_PER_FLOAT = 4
const FLOATS_PER_VERTEX = 8  # position(3) + normal(3) + uv(2)
const VERTICES_PER_CUBE = 24  # 6 faces * 4 vertices
const INDICES_PER_CUBE = 36   # 6 faces * 6 indices

@export_range(8, 256, 8) var chunk_size: int = 100:
	set(value):
		if chunk_size == value:
			return
		chunk_size = value
		_on_editor_param_changed()

@export_range(0.1, 10.0, 0.1) var voxel_size: float = 1.0:
	set(value):
		if voxel_size == value:
			return
		voxel_size = value
		_on_editor_param_changed()

@export_range(0.001, 1.0, 0.001) var noise_scale: float = 0.1:
	set(value):
		if noise_scale == value:
			return
		noise_scale = value
		_on_editor_param_changed()

@export_range(-20.0, 20.0, 0.1) var height_scale: float = 8.0:
	set(value):
		if height_scale == value:
			return
		height_scale = value
		_on_editor_param_changed()

@export_range(0.005, 0.1, 0.005) var visibility_ratio: float = 0.01:
	set(value):
		if visibility_ratio == value:
			return
		visibility_ratio = value
		_on_editor_param_changed()

var rd: RenderingDevice
var generator_shader: RID
var mesher_shader: RID
var mesh_instance: MeshInstance3D
var _update_timer: SceneTreeTimer
var _cached_material: StandardMaterial3D

func _ready():
	if Engine.is_editor_hint():
		print("🧰 Running in editor mode (tool script)")
	else:
		print("▶️ Running in game mode")

	# Create rendering device (only once)
	if not rd:
		rd = RenderingServer.create_local_rendering_device()
		if not rd:
			push_error("Failed to create RenderingDevice - compute shaders not supported")
			return
		print("RenderingDevice created successfully")

	# Load shaders if not already loaded
	if not generator_shader.is_valid() or not mesher_shader.is_valid():
		if not load_shaders():
			push_error("Failed to load compute shaders")
			return
		print("Shaders loaded successfully")

	# Create mesh instance if missing
	if not mesh_instance:
		mesh_instance = MeshInstance3D.new()
		add_child(mesh_instance)

	# Generate initial terrain
	print("🌍 Generating initial terrain with chunk_size:", chunk_size)
	generate_terrain()


func _on_editor_param_changed():
	if not Engine.is_editor_hint():
		return
		
	if not is_inside_tree():
			# This is likely during initial editor loading/setup, ignore the update.
			# A subsequent call will happen when it's fully ready.
			return
	
	# Debounce rapid editor updates (e.g. dragging sliders)
	if _update_timer and _update_timer.timeout.is_connected(_do_editor_update):
		_update_timer.timeout.disconnect(_do_editor_update)
	_update_timer = get_tree().create_timer(0.0, false) #Disabled 0.0 means No debounce, disabled.
	_update_timer.timeout.connect(_do_editor_update)


func _do_editor_update():
	if not Engine.is_editor_hint():
		return
	if rd and is_inside_tree():
		print("🔄 Editor parameter changed — regenerating terrain...")
		generate_terrain()


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
	
	print("Generator shader created successfully")
	
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
	
	print("Mesher shader created successfully")
	
	return true

func generate_terrain():
	var start_time = Time.get_ticks_msec()

	print("🏗️ Starting terrain generation...")
	print("   📊 Parameters: chunk_size=", chunk_size, ", noise_scale=", noise_scale, ", height_scale=", height_scale)

	# Step 1: Generate voxel data
	var voxel_gen_start = Time.get_ticks_msec()
	var voxel_data_buffer = generate_voxel_data()
	if not voxel_data_buffer.is_valid():
		push_error("Failed to generate voxel data")
		return
	var voxel_gen_time = Time.get_ticks_msec() - voxel_gen_start

	print("✅ Voxel data generated in ", voxel_gen_time, "ms")

	# Step 2: Generate mesh from voxel data
	var mesh_gen_start = Time.get_ticks_msec()
	var mesh_data = generate_mesh(voxel_data_buffer)
	if mesh_data.is_empty() or mesh_data.vertex_count == 0:
		push_error("Failed to generate mesh or no vertices generated")
		# Cleanup the voxel buffer since mesh generation failed
		if voxel_data_buffer.is_valid():
			rd.free_rid(voxel_data_buffer)
		return
	var mesh_gen_time = Time.get_ticks_msec() - mesh_gen_start

	print("✅ Mesh data generated in ", mesh_gen_time, "ms")

	# Step 3: Create Godot mesh
	var godot_mesh_start = Time.get_ticks_msec()
	create_godot_mesh(mesh_data)
	var godot_mesh_time = Time.get_ticks_msec() - godot_mesh_start

	var total_time = Time.get_ticks_msec() - start_time
	print("🎉 Terrain generation completed in ", total_time, "ms")
	print("   ⏱️ Breakdown: Voxel=", voxel_gen_time, "ms, Mesh=", mesh_gen_time, "ms, Godot=", godot_mesh_time, "ms")

	# Cleanup
	if voxel_data_buffer.is_valid():
		rd.free_rid(voxel_data_buffer)

func generate_voxel_data() -> RID:
	# Create buffers
	var voxel_count = chunk_size * chunk_size * chunk_size
	var voxel_buffer = rd.storage_buffer_create(voxel_count * 4) # 4 bytes per float
	
	if not voxel_buffer.is_valid():
		push_error("Failed to create voxel buffer")
		return RID()
	
	# Parameters buffer
	var params_data = PackedByteArray()
	params_data.resize(32) # vec3 + float + float + uint + padding
	
	# Encode parameters (ensure proper alignment)
	var chunk_pos = Vector3.ZERO
	params_data.encode_float(0, chunk_pos.x)
	params_data.encode_float(4, chunk_pos.y)
	params_data.encode_float(8, chunk_pos.z)
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
		# Note: uniform_set is auto-freed when buffers are freed
		return RID()
	
	# Execute compute shader
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Dispatch work groups (fix integer division warning)
	var groups = ceili(float(chunk_size) / 8.0)  # Use ceiling division for proper rounding
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Cleanup - params buffer first (this auto-frees uniform_set)
	if params_buffer.is_valid():
		rd.free_rid(params_buffer)
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	# Note: uniform_set is automatically freed when params_buffer is freed
	
	return voxel_buffer

func generate_mesh(voxel_data_buffer: RID) -> Dictionary:
	# Use visibility ratio to allocate buffers efficiently
	# Only allocate for estimated visible voxels (surface voxels), not all voxels
	# Ensure visibility_ratio is set (defaults to 1% if not)
	var vis_ratio = visibility_ratio if visibility_ratio else 0.01

	# Smaller chunks have higher surface-to-volume ratio, adjust visibility_ratio
	if chunk_size < 100:
		vis_ratio = 0.05 if chunk_size < 50 else 0.03
		print("   📐 Auto-adjusted visibility_ratio to ", vis_ratio * 100.0, "% for small chunk_size")

	var voxel_count = chunk_size * chunk_size * chunk_size
	var max_visible_voxels = int(voxel_count * vis_ratio)

	var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT
	var max_vertices = max_visible_voxels * VERTICES_PER_CUBE
	var max_indices = max_visible_voxels * INDICES_PER_CUBE

	# Calculate memory usage
	var vertex_buffer_mb = (max_vertices * bytes_per_vertex) / (1024.0 * 1024.0)
	var index_buffer_mb = (max_indices * 4) / (1024.0 * 1024.0)
	var total_mb = vertex_buffer_mb + index_buffer_mb

	print("📦 Allocating buffers for up to ", max_visible_voxels,
		" visible voxels (", vis_ratio * 100.0, "% of total)")
	print("   → Max vertices: ", max_vertices, ", Max indices: ", max_indices)
	print("   💾 Memory: ", "%.2f" % total_mb, " MB (vertex: ", "%.2f" % vertex_buffer_mb, " MB, index: ", "%.2f" % index_buffer_mb, " MB)")
	
	var vertex_buffer = rd.storage_buffer_create(max_vertices * bytes_per_vertex)
	if not vertex_buffer.is_valid():
		push_error("Failed to create vertex buffer")
		return {}
	
	var index_buffer = rd.storage_buffer_create(max_indices * 4)   # 1 uint per index
	if not index_buffer.is_valid():
		push_error("Failed to create index buffer")
		if vertex_buffer.is_valid():
			rd.free_rid(vertex_buffer)
		return {}
	
	# Counter buffer
	var counter_data = PackedByteArray()
	counter_data.resize(8) # 2 uints
	counter_data.encode_u32(0, 0) # vertex_count (actual vertex count, not float count)
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
	
	# Dispatch work groups (fix integer division warning)
	var groups = ceili(float(chunk_size) / 8.0)  # Use ceiling division for proper rounding
	rd.compute_list_dispatch(compute_list, groups, groups, groups)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	# Read back results
	var counter_result = rd.buffer_get_data(counter_buffer)
	var vertex_count = counter_result.decode_u32(0) # This is the *actual* vertex count
	var index_count = counter_result.decode_u32(4)

	print("📈 GPU wrote ", vertex_count, " vertices, ", index_count, " indices")

	# Safety: Clamp to buffer limits to prevent reading beyond allocated memory
	if vertex_count > max_vertices:
		print("⚠️ WARNING: GPU reported ", vertex_count, " vertices, but buffer only holds ", max_vertices)
		print("   Clamping to buffer size to prevent crash/freeze")
		vertex_count = max_vertices
	if index_count > max_indices:
		print("⚠️ WARNING: GPU reported ", index_count, " indices, but buffer only holds ", max_indices)
		print("   Clamping to buffer size to prevent crash/freeze")
		index_count = max_indices

	var vertex_data = rd.buffer_get_data(vertex_buffer)
	var index_data = rd.buffer_get_data(index_buffer)
	
	# Cleanup - free buffers first (this auto-frees uniform_set)
	if vertex_buffer.is_valid(): rd.free_rid(vertex_buffer)
	if index_buffer.is_valid(): rd.free_rid(index_buffer)
	if counter_buffer.is_valid(): rd.free_rid(counter_buffer)
	if mesh_params_buffer.is_valid(): rd.free_rid(mesh_params_buffer)
	if pipeline.is_valid(): rd.free_rid(pipeline)
	
	return {
		"vertex_count": vertex_count,
		"index_count": index_count,
		"vertex_data": vertex_data, # This now contains (pos, normal, uv) interleaved
		"index_data": index_data
	}

func create_godot_mesh(mesh_data: Dictionary):
	if mesh_data.vertex_count == 0:
		print("❌ No vertices generated - terrain might be empty")
		print("💡 Try adjusting these parameters:")
		print("   - noise_scale: ", noise_scale, " (try 0.05 to 0.2)")
		print("   - height_scale: ", height_scale, " (try 5.0 to 15.0)")
		print("   - chunk_size: ", chunk_size, " (try 16 or 32)")
		return
	
	var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT

	# Create vertex array
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()

	vertices.resize(mesh_data.vertex_count)
	normals.resize(mesh_data.vertex_count)
	uvs.resize(mesh_data.vertex_count)
	
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
	var indices = PackedInt32Array()
	indices.resize(mesh_data.index_count)
	
	for i in range(mesh_data.index_count):
		indices[i] = mesh_data.index_data.decode_u32(i * 4)
	
	# Create mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals # Assign normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs     # Assign UVs
	arrays[Mesh.ARRAY_INDEX] = indices
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create material once and reuse it
	if not _cached_material:
		_cached_material = StandardMaterial3D.new()
		_cached_material.albedo_color = Color(0.6, 0.5, 0.4) # Simple earth/terrain color
		_cached_material.cull_mode = BaseMaterial3D.CULL_BACK # Proper backface culling (triangle winding is now correct)
		# Note: No texture - avoids stuttering from NoiseTexture2D generation

	mesh.surface_set_material(0, _cached_material)

	# Apply to mesh instance
	mesh_instance.mesh = mesh

	# Clean up old collision bodies first
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			child.queue_free()

	# Re-enable collision for single-chunk testing
	# Note: For multi-chunk, this will need optimization (heightmap collision, etc.)
	var collision_start = Time.get_ticks_msec()
	mesh_instance.create_trimesh_collision()
	var collision_time = Time.get_ticks_msec() - collision_start

	print("✅ Generated terrain with ", mesh_data.vertex_count, " vertices and ", mesh_data.index_count, " indices")
	print("   🎯 Collision created in ", collision_time, "ms")
	print("🎯 Terrain should now be visible with collision!")

func _exit_tree():
	# Cleanup RenderingDevice resources
	if rd:
		if generator_shader.is_valid():
			rd.free_rid(generator_shader)
		if mesher_shader.is_valid():
			rd.free_rid(mesher_shader)
		# Free the local rendering device to prevent memory leak
		rd.free()
		rd = null
