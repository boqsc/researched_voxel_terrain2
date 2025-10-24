extends Node

# ChunkDecoder: Handles incremental mesh decoding with time budget
# This keeps the complex decode logic isolated from VoxelWorld/VoxelChunk
# Allows 60 FPS gameplay while chunks decode slowly in the background

signal chunk_decoded(chunk_pos: Vector3i, decoded_data: Dictionary)

# Constants (must match VoxelChunk)
const BYTES_PER_FLOAT = 4
const FLOATS_PER_VERTEX = 8  # position(3) + normal(3) + uv(2)

# Decode queue and active job
var decode_queue: Array = []  # Array of {chunk_pos, mesh_data, enable_collision}
var active_job: Dictionary = {}  # Currently decoding chunk

# Time budget configuration
var time_budget_percent: float = 10.0  # % of frame time (10% = 1.6ms at 60fps)

func _ready():
	print("🔧 ChunkDecoder initialized")

func add_decode_job(chunk_pos: Vector3i, mesh_data: Dictionary, enable_collision: bool):
	"""Queue a chunk for incremental decoding"""
	decode_queue.append({
		"chunk_pos": chunk_pos,
		"mesh_data": mesh_data,
		"enable_collision": enable_collision
	})
	print("📋 Chunk ", chunk_pos, " added to decode queue (", decode_queue.size(), " in queue)")

func _process(_delta):
	# Calculate time budget for this frame (in milliseconds)
	var frame_budget_ms = 16.67 * (time_budget_percent / 100.0)
	var frame_start = Time.get_ticks_msec()

	# Start new job if none active
	if active_job.is_empty() and decode_queue.size() > 0:
		_start_new_job()

	# Decode within time budget
	if not active_job.is_empty():
		_decode_incremental(frame_budget_ms, frame_start)

func _start_new_job():
	"""Start decoding a new chunk from queue"""
	var job = decode_queue.pop_front()

	var mesh_data = job.mesh_data
	var vertex_count = mesh_data.vertex_count
	var index_count = mesh_data.index_count

	active_job = {
		"chunk_pos": job.chunk_pos,
		"mesh_data": mesh_data,
		"enable_collision": job.enable_collision,
		"vertex_count": vertex_count,
		"index_count": index_count,

		# Decode progress
		"current_vertex": 0,
		"current_index": 0,

		# Output arrays
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),

		"start_time": Time.get_ticks_msec()
	}

	# Pre-allocate arrays
	active_job.vertices.resize(vertex_count)
	active_job.normals.resize(vertex_count)
	active_job.uvs.resize(vertex_count)
	active_job.indices.resize(index_count)

	print("🔨 Started decoding chunk ", job.chunk_pos, " (", vertex_count, " vertices)")

func _decode_incremental(budget_ms: float, frame_start: int):
	"""Decode vertices within time budget for this frame"""
	var mesh_data = active_job.mesh_data
	var bytes_per_vertex = FLOATS_PER_VERTEX * BYTES_PER_FLOAT

	# Decode vertices until budget exhausted
	while active_job.current_vertex < active_job.vertex_count:
		var i = active_job.current_vertex
		var offset = i * bytes_per_vertex

		# Decode one vertex
		var x = mesh_data.vertex_data.decode_float(offset)
		var y = mesh_data.vertex_data.decode_float(offset + BYTES_PER_FLOAT)
		var z = mesh_data.vertex_data.decode_float(offset + 2 * BYTES_PER_FLOAT)
		active_job.vertices[i] = Vector3(x, y, z)

		var nx = mesh_data.vertex_data.decode_float(offset + 3 * BYTES_PER_FLOAT)
		var ny = mesh_data.vertex_data.decode_float(offset + 4 * BYTES_PER_FLOAT)
		var nz = mesh_data.vertex_data.decode_float(offset + 5 * BYTES_PER_FLOAT)
		active_job.normals[i] = Vector3(nx, ny, nz)

		var ux = mesh_data.vertex_data.decode_float(offset + 6 * BYTES_PER_FLOAT)
		var uy = mesh_data.vertex_data.decode_float(offset + 7 * BYTES_PER_FLOAT)
		active_job.uvs[i] = Vector2(ux, uy)

		active_job.current_vertex += 1

		# Check budget every 100 vertices to avoid overhead
		if (active_job.current_vertex % 100) == 0:
			var elapsed = Time.get_ticks_msec() - frame_start
			if elapsed >= budget_ms:
				# Budget exhausted - continue next frame
				var progress = (active_job.current_vertex / float(active_job.vertex_count)) * 100.0
				if (active_job.current_vertex % 1000) == 0:  # Print every 1000 vertices
					print("   ⏳ Decoding ", active_job.chunk_pos, ": ", int(progress), "% (", active_job.current_vertex, "/", active_job.vertex_count, ")")
				return

	# Vertices done, now decode indices (fast, usually fits in budget)
	while active_job.current_index < active_job.index_count:
		var i = active_job.current_index
		active_job.indices[i] = mesh_data.index_data.decode_u32(i * 4)
		active_job.current_index += 1

		# Check budget every 1000 indices
		if (active_job.current_index % 1000) == 0:
			var elapsed = Time.get_ticks_msec() - frame_start
			if elapsed >= budget_ms:
				return  # Continue next frame

	# Decoding complete!
	_finish_job()

func _finish_job():
	"""Job complete - emit decoded data"""
	var total_time = Time.get_ticks_msec() - active_job.start_time
	print("✅ Decoded chunk ", active_job.chunk_pos, " in ", total_time, "ms (", active_job.vertex_count, " vertices)")

	# Package decoded data
	var decoded_data = {
		"vertices": active_job.vertices,
		"normals": active_job.normals,
		"uvs": active_job.uvs,
		"indices": active_job.indices,
		"vertex_count": active_job.vertex_count,
		"index_count": active_job.index_count,
		"enable_collision": active_job.enable_collision
	}

	# Emit signal
	emit_signal("chunk_decoded", active_job.chunk_pos, decoded_data)

	# Clear active job
	active_job = {}

func get_queue_size() -> int:
	"""Get number of chunks waiting to decode"""
	var active = 0 if active_job.is_empty() else 1
	return decode_queue.size() + active

func get_progress() -> Dictionary:
	"""Get current decode progress for UI/debug"""
	if active_job.is_empty():
		return {"decoding": false}

	var progress = (active_job.current_vertex / float(active_job.vertex_count)) * 100.0
	return {
		"decoding": true,
		"chunk_pos": active_job.chunk_pos,
		"progress_percent": progress,
		"vertices_done": active_job.current_vertex,
		"vertices_total": active_job.vertex_count
	}
