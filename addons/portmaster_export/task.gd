@tool
extends RefCounted
## Shared base for the plugin's long-running jobs (building a port, installing
## it on an SD card): the log, warning and error counts, the cancel flag, and
## HTTP downloads.

var log_callback: Callable
## Set from another thread to stop the job.
var cancel_requested := false
var warnings := 0
var errors := 0

const USER_AGENT := "User-Agent: godot-portmaster-export"


## Fetches `url` over HTTP(S), following redirects (GitHub release downloads
## redirect to its file host). Streams the body to `dest` when it's given,
## otherwise returns it in "body". Gives up after `idle_timeout_ms` without
## progress, so a slow but working download isn't cut off, and after
## `total_timeout_ms` overall when that's above 0 (for small requests that
## mustn't hold anything up). Blocking; call it off the main thread.
## Returns {ok, body}.
static func http_get(url: String, idle_timeout_ms: int, should_cancel: Callable = Callable(),
		dest: String = "", total_timeout_ms: int = 0) -> Dictionary:
	var fail := {"ok": false, "body": PackedByteArray()}
	var deadline := Time.get_ticks_msec() + idle_timeout_ms
	if total_timeout_ms > 0:
		deadline = mini(deadline, Time.get_ticks_msec() + total_timeout_ms)
	var give_up_at := Time.get_ticks_msec() + total_timeout_ms if total_timeout_ms > 0 else -1
	for _hop in 6:
		var m := RegEx.create_from_string("^(https?)://([^/?#]+)(.*)$").search(url)
		if m == null:
			return fail
		var tls := m.get_string(1) == "https"
		var path := m.get_string(3)
		if path.is_empty():
			path = "/"
		var http := HTTPClient.new()
		if http.connect_to_host(m.get_string(2), 443 if tls else 80, TLSOptions.client() if tls else null) != OK:
			return fail
		while http.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
			http.poll()
			if Time.get_ticks_msec() > deadline or _cancelled(should_cancel):
				return fail
			OS.delay_msec(20)
		if http.get_status() != HTTPClient.STATUS_CONNECTED:
			return fail
		if http.request(HTTPClient.METHOD_GET, path, [USER_AGENT]) != OK:
			return fail
		while http.get_status() == HTTPClient.STATUS_REQUESTING:
			http.poll()
			if Time.get_ticks_msec() > deadline or _cancelled(should_cancel):
				return fail
			OS.delay_msec(20)
		if not http.has_response():
			return fail
		var code := http.get_response_code()
		if code in [301, 302, 303, 307, 308]:
			var headers := http.get_response_headers_as_dictionary()
			url = str(headers.get("Location", headers.get("location", "")))
			if url.begins_with("/"):
				url = m.get_string(1) + "://" + m.get_string(2) + url
			if url.is_empty():
				return fail
			continue
		if code != 200:
			return fail
		var f: FileAccess = null
		if not dest.is_empty():
			f = FileAccess.open(dest, FileAccess.WRITE)
			if f == null:
				return fail
		var body := PackedByteArray()
		while http.get_status() == HTTPClient.STATUS_BODY:
			http.poll()
			var chunk := http.read_response_body_chunk()
			if chunk.is_empty():
				if Time.get_ticks_msec() > deadline or _cancelled(should_cancel):
					if f:
						f.close()
					return fail
				OS.delay_msec(10)
				continue
			deadline = Time.get_ticks_msec() + idle_timeout_ms
			if give_up_at >= 0:
				deadline = mini(deadline, give_up_at)
			if f:
				f.store_buffer(chunk)
			else:
				body.append_array(chunk)
		if f:
			f.close()
		return {"ok": true, "body": body}
	return fail


static func _cancelled(should_cancel: Callable) -> bool:
	return should_cancel.is_valid() and bool(should_cancel.call())


func _say(msg: String) -> void:
	if log_callback.is_valid():
		log_callback.call(msg)
	else:
		print(msg)


func _warn(msg: String) -> void:
	warnings += 1
	_say("  WARNING: " + msg)


func _fail(msg: String) -> bool:
	errors += 1
	_say("ERROR: " + msg)
	return false
