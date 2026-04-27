@tool
extends "res://addons/godot_mcp/tools/base_tools.gd"

## DAP (Debug Adapter Protocol) tools for Godot.
## Connects to Godot editor's DAP server on port 6006 to control debugging.

# DAP 配置
var _dap_host: String = "127.0.0.1"
var _dap_port: int = 6006
var _dap_client: StreamPeerTCP = null
var _dap_connected: bool = false
var _dap_seq: int = 0
var _output_buffer: Array[String] = []

func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "fetch_console",
			"description": "DAP (Debug Adapter Protocol): Fetch console output from a running game. Game must be running (F6 / play_current). Optional 'clear' to flush buffer after reading; optional 'category' to filter stdout/stderr/console.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"clear": {"type": "boolean", "description": "Whether to clear the output buffer after fetching", "default": false},
					"category": {"type": "string", "description": "Filter category: stdout / stderr / console. Empty means all"}
				},
				"required": []
			}
		},
		{
			"name": "clear_console",
			"description": "DAP (Debug Adapter Protocol): Clear the cached console output buffer to reduce context size.",
			"inputSchema": {
				"type": "object",
				"properties": {},
				"required": []
			}
		},
		{
			"name": "set_breakpoints",
			"description": "DAP: Set breakpoints in a GDScript file. Pass empty lines array to clear all breakpoints in that file. Replaces all existing breakpoints.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"file_path": {"type": "string", "description": "GDScript file path, e.g. 'res://main.gd'"},
					"lines": {"type": "array", "items": {"type": "integer"}, "description": "Line numbers to set breakpoints on (1-based). Empty array clears breakpoints."}
				},
				"required": ["file_path", "lines"]
			}
		},
		{
			"name": "get_stack_trace",
			"description": "DAP: Get the call stack trace when the game is paused at a breakpoint. Returns stack frames with file, line, and function name.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"thread_id": {"type": "integer", "description": "Thread ID (default: 1 for main thread)", "default": 1}
				},
				"required": []
			}
		},
		{
			"name": "get_variables",
			"description": "DAP: Get variables for a stack frame (from get_stack_trace). Specify scope as locals/globals/members.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"frame_id": {"type": "integer", "description": "Stack frame ID from get_stack_trace"},
					"scope": {"type": "string", "enum": ["locals", "globals", "members"], "description": "Which scope to inspect (default: locals)", "default": "locals"}
				},
				"required": ["frame_id"]
			}
		},
		{
			"name": "continue_execution",
			"description": "DAP: Continue execution after the game is paused at a breakpoint.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"thread_id": {"type": "integer", "description": "Thread ID to continue (default: 1)", "default": 1}
				},
				"required": []
			}
		},
		{
			"name": "step_over",
			"description": "DAP: Step over the current line. Pauses again at the next line (triggers stopped event).",
			"inputSchema": {
				"type": "object",
				"properties": {
					"thread_id": {"type": "integer", "description": "Thread ID (default: 1)", "default": 1}
				},
				"required": []
			}
		},
		{
			"name": "step_into",
			"description": "DAP: Step into the current function call. Pauses again at the first line of the called function (triggers stopped event).",
			"inputSchema": {
				"type": "object",
				"properties": {
					"thread_id": {"type": "integer", "description": "Thread ID (default: 1)", "default": 1}
				},
				"required": []
			}
		},
		{
			"name": "evaluate_expression",
			"description": "DAP: Evaluate a GDScript expression. Game must be paused at a breakpoint.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"expression": {"type": "string", "description": "GDScript expression to evaluate"},
					"frame_id": {"type": "integer", "description": "Stack frame ID for context (optional)"}
				},
				"required": ["expression"]
			}
		},
		{
			"name": "capture_screenshot",
			"description": "DAP: Capture a screenshot from the running game. Saves to project/.agent/screenshots/ and returns the file path. Game must be paused at a breakpoint.",
			"inputSchema": {
				"type": "object",
				"properties": {},
				"required": []
			}
		}
	]


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"fetch_console":
			return await _execute_fetch_console(args)
		"clear_console":
			return _execute_clear_console(args)
		"set_breakpoints":
			return await _execute_set_breakpoints(args)
		"get_stack_trace":
			return await _execute_get_stack_trace(args)
		"get_variables":
			return await _execute_get_variables(args)
		"continue_execution":
			return await _execute_continue(args)
		"step_over":
			return await _execute_step_over(args)
		"step_into":
			return await _execute_step_into(args)
		"evaluate_expression":
			return await _execute_evaluate(args)
		"capture_screenshot":
			return await _execute_capture_screenshot(args)
		_:
			return {"success": false, "error": "Unknown tool: %s" % tool_name}


# ==================== Console Output ====================

func _execute_fetch_console(args: Dictionary) -> Dictionary:
	var do_clear: bool = args.get("clear", false)
	var category_filter: String = args.get("category", "")

	if _dap_client and _dap_client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_reset_dap_connection()

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	var tree = Engine.get_main_loop() as SceneTree
	var timeout_ms := 1500
	var start := Time.get_ticks_msec()
	var buffer := ""

	while Time.get_ticks_msec() - start < timeout_ms:
		_dap_client.poll()
		var avail = _dap_client.get_available_bytes()
		if avail > 0:
			var chunk = _dap_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		while true:
			var parsed := _dap_consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var msg = parsed[0]
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			if msg.get("type") == "event" and msg.get("event") == "output":
				var body = msg.get("body", {})
				var cat = body.get("category", "stdout")
				if not category_filter.is_empty() and cat != category_filter:
					continue
				var line = body.get("output", "")
				if not line.is_empty():
					_output_buffer.append(line)
		await tree.process_frame

	var lines: Array = []
	for s in _output_buffer:
		lines.append(s)

	if do_clear:
		_output_buffer.clear()

	return {
		"success": true,
		"lines": lines,
		"line_count": lines.size(),
		"cleared": do_clear
	}


func _execute_clear_console(_args: Dictionary) -> Dictionary:
	_output_buffer.clear()
	return {"success": true, "message": "Console output buffer cleared"}


# ==================== Breakpoints ====================

func _execute_set_breakpoints(args: Dictionary) -> Dictionary:
	var file_path: String = args.get("file_path", "")
	if file_path.is_empty():
		return {"success": false, "error": "file_path is required"}

	# Convert res:// path to absolute path for DAP
	if file_path.begins_with("res://"):
		file_path = ProjectSettings.globalize_path(file_path)
		file_path = file_path.replace("\\", "/")
		if file_path.length() > 1 and file_path[1] == ":":
			file_path = file_path[0].to_upper() + file_path.substr(1)

	var lines = args.get("lines", [])

	var breakpoints: Array = []
	for line in lines:
		breakpoints.append({"line": int(line)})

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	var res = await _dap_request("setBreakpoints", {
		"source": {"path": file_path},
		"breakpoints": breakpoints,
		"lines": lines
	})

	if not res.get("success", false):
		return {"success": false, "error": "Failed to set breakpoints", "response": res}

	var body = res.get("response", {}).get("body", {})
	return {"success": true, "breakpoints": body.get("breakpoints", [])}



# ==================== Stack Trace ====================

func _execute_get_stack_trace(args: Dictionary) -> Dictionary:
	var thread_id: int = int(args.get("thread_id", 1))

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	# Wait for stopped event (game hit a breakpoint)
	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused at a breakpoint. Set breakpoints and run the game first."}

	# Now get stack trace
	var res = await _dap_request("stackTrace", {
		"threadId": thread_id,
		"startFrame": 0,
		"levels": 20
	})

	if not res.get("success", false):
		return {"success": false, "error": "Failed to get stack trace", "response": res}

	var body = res.get("response", {}).get("body", {})
	var frames: Array = []
	for frame in body.get("stackFrames", []):
		var f: Dictionary = {}
		f["id"] = frame.get("id", 0)
		f["name"] = frame.get("name", "")
		var source = frame.get("source", {})
		f["file"] = source.get("name", source.get("path", ""))
		f["line"] = frame.get("line", 0)
		f["column"] = frame.get("column", 0)
		frames.append(f)

	return {"success": true, "stack_frames": frames, "total_frames": body.get("totalFrames", frames.size())}


# ==================== Variables ====================

func _execute_get_variables(args: Dictionary) -> Dictionary:
	var frame_id: int = int(args.get("frame_id", 0))
	var scope_name: String = args.get("scope", "locals")

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	# Wait for stopped event
	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused at a breakpoint."}

	# Get scopes for the frame
	var scopes_res = await _dap_request("scopes", {"frameId": frame_id})
	if not scopes_res.get("success", false):
		return {"success": false, "error": "Failed to get scopes. Is the game paused?"}

	var scopes = scopes_res.get("response", {}).get("body", {}).get("scopes", [])
	var target_scope: Dictionary = {}
	for scope in scopes:
		var name = scope.get("name", "").to_lower()
		var hint = scope.get("presentationHint", "").to_lower()
		if scope_name == "locals":
			if name == "locals" or hint == "locals" or name.contains("local") or scope.get("variablesReference", 0) > 0:
				target_scope = scope
				break
		elif name == scope_name:
			target_scope = scope
			break

	if target_scope.is_empty() and scopes.size() > 0:
		target_scope = scopes[0]

	if target_scope.is_empty():
		return {"success": false, "error": "No scope found for frame %d" % frame_id}

	var var_res = await _dap_request("variables", {"variablesReference": target_scope.get("variablesReference", 0)})
	if not var_res.get("success", false):
		return {"success": false, "error": "Failed to get variables"}

	var variables: Array = []
	for v in var_res.get("response", {}).get("body", {}).get("variables", []):
		variables.append({
			"name": v.get("name", ""),
			"value": v.get("value", ""),
			"type": v.get("type", ""),
			"variablesReference": v.get("variablesReference", 0)
		})

	return {"success": true, "scope": target_scope.get("name", ""), "variables": variables}


# ==================== Execution Control ====================

func _execute_continue(args: Dictionary) -> Dictionary:
	var thread_id: int = int(args.get("thread_id", 1))

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	var res = await _dap_request("continue", {"threadId": thread_id})
	if not res.get("success", false):
		return {"success": false, "error": "Failed to continue. Is the game paused?"}

	return {"success": true, "message": "Execution continued"}


func _execute_step_over(args: Dictionary) -> Dictionary:
	var thread_id: int = int(args.get("thread_id", 1))

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	# Wait for stopped event
	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused at a breakpoint."}

	var res = await _dap_request("next", {"threadId": thread_id})
	if not res.get("success", false):
		return {"success": false, "error": "Failed to step over. Is the game paused?"}

	return {"success": true, "message": "Stepped over"}


func _execute_step_into(args: Dictionary) -> Dictionary:
	var thread_id: int = int(args.get("thread_id", 1))

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	# Wait for stopped event
	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused at a breakpoint."}

	var res = await _dap_request("stepIn", {"threadId": thread_id})
	if not res.get("success", false):
		return {"success": false, "error": "Failed to step into. Is the game paused?"}

	return {"success": true, "message": "Stepped into"}


# ==================== Evaluate ====================

func _execute_evaluate(args: Dictionary) -> Dictionary:
	var expression: String = args.get("expression", "")
	if expression.is_empty():
		return {"success": false, "error": "expression is required"}

	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	# Wait for stopped event
	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused. Set breakpoints and run first."}

	var arguments: Dictionary = {"expression": expression}
	if args.has("frame_id"):
		arguments["frameId"] = int(args.get("frame_id"))
		arguments["context"] = "repl"

	var res = await _dap_request("evaluate", arguments)
	if not res.get("success", false):
		return {"success": false, "error": "Evaluation failed", "response": res}

	var body = res.get("response", {}).get("body", {})
	return {"success": true, "result": body.get("result", ""), "type": body.get("type", "")}


# ==================== Screenshot ====================

func _execute_capture_screenshot(_args: Dictionary) -> Dictionary:
	if not _dap_connected:
		var connect_res = await _connect_dap()
		if not connect_res.get("success", false):
			return connect_res

	var stopped = await _dap_wait_for_event("stopped", 10000)
	if not stopped:
		return {"success": false, "error": "Game is not paused. Set breakpoints and run first."}

	var screenshot_dir = ProjectSettings.globalize_path("res://.agent/screenshots/")
	DirAccess.make_dir_recursive_absolute(screenshot_dir)

	var filename = "screenshot_%d.png" % int(Time.get_unix_time_from_system())
	var file_path = screenshot_dir + filename

	var res = await _dap_request("evaluate", {
		"expression": "get_viewport().get_texture().get_image().save_png(\"%s\")" % file_path,
		"context": "repl"
	})

	if not res.get("success", false):
		return {"success": false, "error": "Screenshot capture failed", "response": res}

	var body = res.get("response", {}).get("body", {})
	var save_result = body.get("result", "")
	if save_result != "0":
		return {"success": false, "error": "Screenshot save failed (result: %s)" % save_result}
	return {"success": true, "file_path": file_path}


# ==================== DAP Connection ====================

func _reset_dap_connection() -> void:
	_dap_connected = false
	_dap_client = null


func _connect_dap() -> Dictionary:
	if _dap_client and _dap_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		return {"success": true}

	_dap_client = StreamPeerTCP.new()
	var err = _dap_client.connect_to_host(_dap_host, _dap_port)
	if err != OK:
		return {"success": false, "error": "Cannot connect to DAP port %d. Is Godot editor running?" % _dap_port}

	var tree = Engine.get_main_loop() as SceneTree
	if not tree:
		return {"success": false, "error": "Cannot get SceneTree"}

	var timeout_ms := 2000
	var start_time := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_time < timeout_ms:
		_dap_client.poll()
		if _dap_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_dap_connected = true
			break
		await tree.process_frame

	if not _dap_connected:
		return {"success": false, "error": "DAP connection timeout"}

	var init_res = await _dap_request("initialize", {})
	if not init_res.get("success", false):
		_reset_dap_connection()
		return init_res

	var project_path = ProjectSettings.globalize_path("res://")
	project_path = project_path.replace("\\", "/")
	if project_path.length() > 1 and project_path[1] == ":":
		project_path = project_path[0].to_upper() + project_path.substr(1)
	_send_dap_packet({"type": "request", "command": "launch", "arguments": {"project": project_path, "request": "launch", "type": "godot"}, "seq": _next_dap_seq()})
	_send_dap_packet({"type": "request", "command": "configurationDone", "arguments": {}, "seq": _next_dap_seq()})

	# Wait for launch response
	var start = Time.get_ticks_msec()
	var _timeout_ms = 8000
	var buffer := ""
	var launch_success = false

	while Time.get_ticks_msec() - start < _timeout_ms:
		_dap_client.poll()
		var avail = _dap_client.get_available_bytes()
		if avail > 0:
			var chunk = _dap_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		while true:
			var parsed := _dap_consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var msg = parsed[0]
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			if msg.get("type") == "response" and msg.get("command") == "launch":
				launch_success = msg.get("success", false)
				if not launch_success:
					_reset_dap_connection()
					var err_msg = msg.get("body", {}).get("error", {}).get("format", "DAP launch failed")
					return {"success": false, "error": err_msg}
				break
		if launch_success:
			break
		await tree.process_frame

	if not launch_success:
		_reset_dap_connection()
		return {"success": false, "error": "DAP launch response timeout"}

	return {"success": true}


# ==================== DAP Low-Level ====================

func _next_dap_seq() -> int:
	_dap_seq += 1
	return _dap_seq


func _send_dap_packet(payload: Dictionary) -> void:
	var body = JSON.stringify(payload).to_utf8_buffer()
	var packet = ("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer()
	packet.append_array(body)
	_dap_client.put_data(packet)


func _dap_request(command: String, arguments: Dictionary) -> Dictionary:
	var seq = _next_dap_seq()
	_send_dap_packet({"type": "request", "command": command, "arguments": arguments, "seq": seq})
	return await _dap_wait_response(5000)


func _dap_wait_response(timeout_ms: int) -> Dictionary:
	var tree = Engine.get_main_loop() as SceneTree
	var start = Time.get_ticks_msec()
	var buffer := ""

	while Time.get_ticks_msec() - start < timeout_ms:
		_dap_client.poll()
		var avail = _dap_client.get_available_bytes()
		if avail > 0:
			var chunk = _dap_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		while true:
			var parsed := _dap_consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var msg = parsed[0]
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			if msg.get("type") == "response":
				var success = msg.get("success", false)
				return {"success": success, "response": msg}
		await tree.process_frame

	return {"success": false, "error": "DAP response timeout"}


func _dap_wait_for_event(event_name: String, timeout_ms: int) -> Dictionary:
	var tree = Engine.get_main_loop() as SceneTree
	var start = Time.get_ticks_msec()
	var buffer := ""

	while Time.get_ticks_msec() - start < timeout_ms:
		_dap_client.poll()
		var avail = _dap_client.get_available_bytes()
		if avail > 0:
			var chunk = _dap_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		while true:
			var parsed := _dap_consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var msg = parsed[0]
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			if msg.get("type") == "event" and msg.get("event") == event_name:
				return {"success": true, "event": msg}
		await tree.process_frame

	return {"success": false, "error": "DAP event '%s' timeout" % event_name}


func _dap_consume_one_message(buffer: String) -> Array:
	var sep := buffer.find("\r\n\r\n")
	if sep == -1:
		return [null, buffer]

	var header := buffer.substr(0, sep)
	var len_idx := header.find("Content-Length: ")
	if len_idx == -1:
		return [null, buffer]

	var length := _dap_parse_content_length(header, len_idx, header.length())
	if length < 0:
		return [null, buffer]

	var body_start := sep + 4
	if body_start + length > buffer.length():
		return [null, buffer]

	var body := buffer.substr(body_start, length)
	var remaining := buffer.substr(body_start + length)

	var json = JSON.new()
	if json.parse(body) == OK:
		return [json.get_data(), remaining]
	return [null, remaining]


func _dap_parse_content_length(header_text: String, len_idx: int, header_end: int) -> int:
	const PREFIX_LEN := 16
	var line_end = header_text.find("\r\n", len_idx)
	if line_end == -1 or line_end > header_end:
		line_end = header_end
	var value_str = header_text.substr(len_idx + PREFIX_LEN, line_end - (len_idx + PREFIX_LEN)).strip_edges()
	if not value_str.is_valid_int():
		return -1
	return int(value_str)
