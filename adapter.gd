extends RefCounted
## This package implements the standard ranking contract only.
func check_request(request: Dictionary) -> Dictionary:
	if request.get("mode") != "standard":
		return {"ok": false, "code": "unsupported_mode", "message": "只支持 standard 普通局"}
	return {"ok": true}

func make_config(request: Dictionary) -> Dictionary:
	return request.duplicate(true)

func map_result(raw_result: Dictionary, _request: Dictionary) -> Dictionary:
	return raw_result.duplicate(true)
