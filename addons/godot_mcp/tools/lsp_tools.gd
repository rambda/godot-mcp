@tool
extends "res://addons/godot_mcp/tools/base_tools.gd"

# LSP 配置
var _lsp_host: String = "127.0.0.1"
var _lsp_port: int = 6005
var _lsp_client: StreamPeerTCP = null
var _lsp_connected: bool = false
var _request_id: int = 0

func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_diagnostics",
			"description": "LSP (Language Server Protocol): Check GDScript for syntax errors and diagnostics. Scans the entire project (excluding .godot/ and .git/) when no file_path is given; checks a single file when file_path is provided.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"file_path": {"type": "string", "description": "Path to a GDScript file. Leave empty to scan the whole project."}
				},
				"required": []
			}
		}
	]

func execute(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"get_diagnostics":
			return await _execute_get_diagnostics(args)
		_:
			return {"success": false, "error": "Unknown tool: %s" % tool_name}

func _execute_get_diagnostics(args: Dictionary) -> Dictionary:
	var file_path = args.get("file_path", "")

	# 连接断开时重置状态，下次会重连
	if _lsp_client and _lsp_client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_reset_connection()

	if not _lsp_connected:
		var connect_res = await _connect_lsp()
		if not connect_res.get("success", false):
			return connect_res

	if file_path.is_empty():
		return await _get_project_diagnostics()
	var abs_path = ProjectSettings.globalize_path(file_path) if file_path.begins_with("res://") else file_path
	return await _get_diagnostics(abs_path)


func _reset_connection() -> void:
	_lsp_connected = false
	_lsp_client = null

func _connect_lsp() -> Dictionary:
	if _lsp_client and _lsp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		return {"success": true}

	_lsp_client = StreamPeerTCP.new()
	var err = _lsp_client.connect_to_host(_lsp_host, _lsp_port)
	if err != OK: return {"success": false, "error": "无法连接 LSP 端口 6005"}

	var tree = Engine.get_main_loop() as SceneTree
	if not tree: return {"success": false, "error": "无法获取 Engine SceneTree"}

	var timeout = 2.0
	var start_time = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_time < timeout * 1000:
		_lsp_client.poll()
		if _lsp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_lsp_connected = true
			break
		await tree.process_frame

	if not _lsp_connected:
		return {"success": false, "error": "连接 LSP 超时"}

	return await _lsp_initialize()


func _send_lsp_packet(payload: Dictionary) -> void:
	"""发送 LSP JSON-RPC 包（请求或通知）"""
	var body = JSON.stringify(payload).to_utf8_buffer()
	var packet = ("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer()
	packet.append_array(body)
	_lsp_client.put_data(packet)


func _lsp_initialize() -> Dictionary:
	var root = ProjectSettings.globalize_path("res://").replace("\\", "/")
	if root.ends_with("/"): root = root.left(-1)

	var req = {
		"jsonrpc": "2.0",
		"id": _get_next_id(),
		"method": "initialize",
		"params": {
			"processId": OS.get_process_id(),
			"rootUri": "file:///" + root,
			"capabilities": {"textDocument": {"publishDiagnostics": {}}}
		}
	}
	var res = await _send_request(req)
	if not res.get("success", false):
		return res
	# LSP 规范：收到 initialize 响应后必须发送 initialized 通知
	_send_lsp_packet({"jsonrpc": "2.0", "method": "initialized", "params": {}})
	return res

func _send_request(request: Dictionary) -> Dictionary:
	_send_lsp_packet(request)

	var tree = Engine.get_main_loop() as SceneTree
	var timeout_ms := 3000
	var start_time := Time.get_ticks_msec()
	var buffer := ""

	while Time.get_ticks_msec() - start_time < timeout_ms:
		_lsp_client.poll()
		var avail = _lsp_client.get_available_bytes()
		if avail > 0:
			var chunk = _lsp_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		var parsed := _consume_one_message(buffer)
		if parsed[0] != null:
			return {"success": true, "response": parsed[0]}
		buffer = parsed[1]

		await tree.process_frame

	return {"success": false, "error": "LSP 响应超时"}

func _collect_gd_files(base_path: String) -> Array[String]:
	"""递归收集 res:// 下所有 .gd 文件路径，排除 .godot/、.git/"""
	var result: Array[String] = []
	var dir = DirAccess.open(base_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = base_path.path_join(name)
		if dir.current_is_dir():
			if name != ".godot" and name != ".git":
				result.append_array(_collect_gd_files(full))
		elif name.ends_with(".gd"):
			result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result


func _get_project_diagnostics() -> Dictionary:
	"""批量扫描项目所有 .gd 文件，只返回有问题的文件"""
	var res_root = ProjectSettings.globalize_path("res://").replace("\\", "/")
	if res_root.ends_with("/"):
		res_root = res_root.left(-1)
	var gd_files = _collect_gd_files("res://")
	if gd_files.is_empty():
		return {
			"success": true,
			"total_files": 0,
			"files_with_issues": 0,
			"total_errors": 0,
			"total_warnings": 0,
			"files": []
		}

	# 连续发送所有 didOpen
	for p in gd_files:
		var abs_path = ProjectSettings.globalize_path(p).replace("\\", "/")
		var uri = "file:///" + abs_path
		var content = ""
		var f = FileAccess.open(p, FileAccess.READ)
		if f:
			content = f.get_as_text()
			f.close()
		var notif = {
			"jsonrpc": "2.0",
			"method": "textDocument/didOpen",
			"params": {
				"textDocument": {
					"uri": uri,
					"languageId": "gdscript",
					"version": 1,
					"text": content
				}
			}
		}
		_send_lsp_packet(notif)

	# 收集所有 publishDiagnostics，等待全部或超时 5s
	var tree = Engine.get_main_loop() as SceneTree
	var uri_to_path: Dictionary = {}
	for p in gd_files:
		var abs_path = ProjectSettings.globalize_path(p).replace("\\", "/")
		uri_to_path["file:///" + abs_path] = p
	var received: Dictionary = {}  # uri -> diagnostics[]
	var timeout_ms := 5000
	var start := Time.get_ticks_msec()
	var buffer := ""

	while Time.get_ticks_msec() - start < timeout_ms:
		_lsp_client.poll()
		var avail = _lsp_client.get_available_bytes()
		if avail > 0:
			var chunk = _lsp_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		while true:
			var parsed := _consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var data = parsed[0]
			if typeof(data) == TYPE_DICTIONARY and data.get("method") == "textDocument/publishDiagnostics":
				var params = data.get("params", {})
				var uri = params.get("uri", "")
				if uri_to_path.has(uri):
					received[uri] = params.get("diagnostics", [])

		if received.size() >= gd_files.size():
			break
		await tree.process_frame

	# 只返回有问题的文件
	var files_with_issues: Array = []
	var total_err := 0
	var total_warn := 0
	for uri in received:
		var diags = received[uri]
		var err_count := 0
		var warn_count := 0
		for d in diags:
			var sv = d.get("severity", 0)
			if sv == 1: err_count += 1
			elif sv == 2: warn_count += 1
		if err_count > 0 or warn_count > 0:
			total_err += err_count
			total_warn += warn_count
			files_with_issues.append({
				"file_path": uri_to_path.get(uri, uri),
				"error_count": err_count,
				"warning_count": warn_count,
				"diagnostics": diags
			})

	return {
		"success": true,
		"total_files": gd_files.size(),
		"files_with_issues": files_with_issues.size(),
		"total_errors": total_err,
		"total_warnings": total_warn,
		"files": files_with_issues
	}


func _get_diagnostics(path: String) -> Dictionary:
	var tree = Engine.get_main_loop() as SceneTree
	var uri = "file:///" + path.replace("\\", "/")

	var notif = {
		"jsonrpc": "2.0",
		"method": "textDocument/didOpen",
		"params": {
			"textDocument": {
				"uri": uri,
				"languageId": "gdscript",
				"version": 1,
				"text": FileAccess.get_file_as_string(path)
			}
		}
	}
	_send_lsp_packet(notif)

	var timeout_ms := 2000
	# 收到不相关消息后的宽限期——LSP 在 localhost 上通常几十 ms 内返回 diagnostics，
	# 如果先收到了其他消息说明服务端已在处理，不需要等满整个 timeout
	var grace_ms := 300
	var start := Time.get_ticks_msec()
	var buffer := ""
	var found_diags := []
	var found := false
	var grace_deadline := 0

	while Time.get_ticks_msec() - start < timeout_ms:
		if grace_deadline > 0 and Time.get_ticks_msec() > grace_deadline:
			break

		_lsp_client.poll()
		var avail = _lsp_client.get_available_bytes()
		if avail > 0:
			var chunk = _lsp_client.get_data(avail)
			if chunk[0] == OK:
				buffer += chunk[1].get_string_from_utf8()

		# 逐条消费 buffer 中的完整消息
		while true:
			var parsed := _consume_one_message(buffer)
			if parsed[0] == null:
				break
			buffer = parsed[1]
			var data = parsed[0]
			if typeof(data) == TYPE_DICTIONARY and data.get("method") == "textDocument/publishDiagnostics":
				var params = data.get("params", {})
				if params.get("uri") == uri:
					found_diags = params.get("diagnostics", [])
					found = true
					break
			# 收到了非目标消息 → 启动宽限计时
			if grace_deadline == 0:
				grace_deadline = Time.get_ticks_msec() + grace_ms

		if found:
			break
		await tree.process_frame

	var err_count := 0
	var warn_count := 0
	for d in found_diags:
		var severity = d.get("severity", 0)
		if severity == 1: err_count += 1
		elif severity == 2: warn_count += 1

	return {
		"success": true,
		"file_path": path,
		"error_count": err_count,
		"warning_count": warn_count,
		"diagnostics": found_diags
	}


func _consume_one_message(buffer: String) -> Array:
	"""从 buffer 前端解析并消费一条完整的 LSP 消息。返回 [data_or_null, remaining_buffer]"""
	var sep := buffer.find("\r\n\r\n")
	if sep == -1:
		return [null, buffer]

	var header := buffer.substr(0, sep)
	var len_idx := header.find("Content-Length: ")
	if len_idx == -1:
		return [null, buffer]

	var length := _parse_content_length(header, len_idx, header.length())
	if length < 0:
		return [null, buffer]

	var body_start := sep + 4
	if body_start + length > buffer.length():
		return [null, buffer]

	var body := buffer.substr(body_start, length)
	var remaining := buffer.substr(body_start + length)

	var json := JSON.new()
	if json.parse(body) == OK:
		return [json.get_data(), remaining]
	return [null, remaining]

func _parse_content_length(header_text: String, len_idx: int, header_end: int) -> int:
	"""从 header 中解析 Content-Length，仅取该行数值，避免多行 header 干扰"""
	const PREFIX_LEN := 16  # "Content-Length: ".length()
	var line_end = header_text.find("\r\n", len_idx)
	if line_end == -1 or line_end > header_end:
		line_end = header_end
	var value_str = header_text.substr(len_idx + PREFIX_LEN, line_end - (len_idx + PREFIX_LEN)).strip_edges()
	if not value_str.is_valid_int(): return -1
	return int(value_str)


func _get_next_id() -> int:
	_request_id += 1
	return _request_id
