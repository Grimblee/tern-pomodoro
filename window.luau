--!strict
-- pomodoro, window half: palette commands, the key chord, the status segment
-- and the sound pickers. It writes kv `requests` (commands for the host half)
-- and `settings` (the sound choice), never `state`. Notifications and sounds
-- at a phase end come from the host half only, since this half runs once per
-- window; the pickers play a sound only as a preview.

local common = require("./common")
local sound = require("./sound")

local POLL_MS = 1000
-- The host drops requests older than this, so there is no use keeping them.
local REQUEST_KEEP_S = 10

local ACTION_TOGGLE = "plugin.pomodoro.toggle"

-- Signature of the state the status line last drew.
local drawn = ""
local counter = 0

local function read_state(): common.State
	return common.parse(tern.kv.get("state"))
end

local function signature(state: common.State): string
	return string.format("%s|%s|%s|%d", state.phase, tostring(state.end_epoch), tostring(state.paused_remaining), state.completed)
end

-- Every window polls: the host half is the one that changes `state`, whichever
-- window asked. The status line redraws every second while a phase counts down,
-- and otherwise only when the state changed. The next poll is armed first, so
-- a failed read cannot stop the clock.
local function poll()
	tern.timer(POLL_MS, poll)
	local state = read_state()
	local sig = signature(state)
	if sig ~= drawn or (common.running(state) and not common.paused(state)) then
		drawn = sig
		tern.chrome.refresh()
	end
end

-- The requests in kv, oldest first, that are recent.
local function recent_requests(now: number): { common.Request }
	local stored = tern.kv.get("requests")
	local kept: { common.Request } = {}
	if type(stored) == "table" then
		for _, request in stored do
			if type(request) == "table" and type(request.at) == "number" and now - request.at <= REQUEST_KEEP_S then
				table.insert(kept, request)
			end
		end
	end
	return kept
end

-- The state once the host has run every request already sent: a command
-- issued before the host's next tick sees the one before it.
local function projected_state(now: number): common.State
	local raw = tern.kv.get("state")
	local handled: { [string]: boolean } = {}
	if type(raw) == "table" and type(raw.handled) == "table" then
		for _, id in raw.handled do
			handled[id] = true
		end
	end
	local state = common.parse(raw)
	for _, request in recent_requests(now) do
		if not handled[request.id] then
			state = (common.apply(state, request.op, now))
		end
	end
	return state
end

local function send(op: common.Op, cx: WindowCx)
	local now = os.time()
	local state = projected_state(now)
	local next, note = common.apply(state, op, now)
	if note == nil then
		cx:toast("info", "Pomodoro", if state.phase == "idle" then "Not running" else "Already running")
		return
	end
	counter += 1
	local requests = recent_requests(now)
	table.insert(requests, { op = op, id = string.format("%d-%d-%d", now, math.floor(tern.now()), counter), at = now })
	tern.kv.set("requests", requests)
	cx:toast("success", "Pomodoro " .. note, if next.phase ~= "idle" then common.format(common.remaining(next, now)) else nil)
end

tern.command({
	id = "start",
	title = "Pomodoro: Start",
	icon = "timer",
	run = function(cx: WindowCx)
		send("start", cx)
	end,
})

tern.command({
	id = "pause",
	title = "Pomodoro: Pause / resume",
	icon = "timer",
	run = function(cx: WindowCx)
		send("pause", cx)
	end,
})

tern.command({
	id = "toggle",
	title = "Pomodoro: Start / pause / resume",
	icon = "timer",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+shift+m" else "ctrl+alt+shift+m" },
	run = function(cx: WindowCx)
		send("toggle", cx)
	end,
})

tern.command({
	id = "reset",
	title = "Pomodoro: Reset",
	icon = "timer",
	run = function(cx: WindowCx)
		send("reset", cx)
	end,
})

tern.command({
	id = "skip",
	title = "Pomodoro: Skip to next phase",
	icon = "timer",
	run = function(cx: WindowCx)
		send("skip", cx)
	end,
})

-- Sound choice. The window half is the only writer of kv `settings`.

local EXTENSIONS: { [string]: boolean } = { oga = true, ogg = true, wav = true, flac = true, mp3 = true, opus = true }
local MAX_DEPTH = 4

type Found = { path: string, theme: string, name: string, dir: string, home: boolean }

local function sound_roots(): { string }
	local home = tern.getenv("HOME") or ""
	local data_home = tern.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
	local candidates = { data_home }
	for dir in string.gmatch(tern.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share", "[^:]+") do
		table.insert(candidates, dir)
	end
	local roots: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, base in candidates do
		local root = base .. "/sounds"
		if not seen[root] and tern.fs.exists(root) then
			seen[root] = true
			table.insert(roots, root)
		end
	end
	return roots
end

-- Every sound file under `dir`; `parts` is the path below the root.
local function scan(root: string, dir: string, parts: { string }, found: { Found }, home: string)
	local ok, entries = pcall(tern.fs.list, dir)
	if not ok then
		return
	end
	for _, entry in entries do
		local path = dir .. "/" .. entry
		local name, ext = string.match(entry, "^(.+)%.(%w+)$")
		if name ~= nil and EXTENSIONS[string.lower(ext :: string)] then
			table.insert(found, {
				path = path,
				theme = parts[1] or "sounds",
				name = name,
				dir = table.concat(parts, "/", 2),
				home = home ~= "" and string.sub(root, 1, #home) == home,
			})
		elseif #parts < MAX_DEPTH and pcall(tern.fs.list, path) then
			local below = table.clone(parts)
			table.insert(below, entry)
			scan(root, path, below, found, home)
		end
	end
end

-- Sound files in the freedesktop data dirs (system and user), by theme and name.
local function find_sounds(): { Found }
	local found: { Found } = {}
	local home = tern.getenv("HOME") or ""
	for _, root in sound_roots() do
		scan(root, root, {}, found, home)
	end
	table.sort(found, function(a: Found, b: Found)
		if a.theme ~= b.theme then
			return a.theme < b.theme
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.path < b.path
	end)
	return found
end

local function choose_sound(slot: sound.Slot, what: string, cx: WindowCx)
	local effective = sound.resolve(slot)
	local items: { PickItem } = {
		{ label = "None (no sound)", group = "Off", sound = common.NONE, current = effective == nil },
	}
	for _, file in find_sounds() do
		local detail = if file.dir ~= "" then file.dir else nil
		if file.home then
			detail = "~ " .. (detail or "")
		end
		table.insert(items, {
			label = file.theme .. "/" .. file.name,
			detail = detail,
			group = file.theme,
			sound = file.path,
			current = file.path == effective,
		})
	end
	cx:pick({ placeholder = what, icon = "timer", action = "set sound", items = items }):next(function(item, _err, cx)
		if item == nil or cx == nil then
			return
		end
		local stored = tern.kv.get("settings")
		local settings: { [string]: any } = if type(stored) == "table" then table.clone(stored) else {}
		settings[slot] = item.sound
		tern.kv.set("settings", settings)
		if item.sound == common.NONE then
			cx:toast("success", what, "No sound")
		else
			-- The picker has no highlight callback, so preview the choice once.
			sound.play(item.sound)
			cx:toast("success", what, item.label)
		end
	end)
end

tern.command({
	id = "set_work_sound",
	title = "Pomodoro: Set work-end sound",
	icon = "timer",
	run = function(cx: WindowCx)
		choose_sound("work_sound", "Work-end sound", cx)
	end,
})

tern.command({
	id = "set_break_sound",
	title = "Pomodoro: Set break-end sound",
	icon = "timer",
	run = function(cx: WindowCx)
		choose_sound("break_sound", "Break-end sound", cx)
	end,
})

-- The answer depends on the clock, which is not part of the formatter's
-- input, so `poll` calls `tern.chrome.refresh()` to drop the cache.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local state = read_state()
	if state.phase == "idle" then
		return nil
	end
	local left = common.format(common.remaining(state, os.time()))
	local text = if state.phase == "work" then "🍅 " .. left else common.phase_name(state.phase) .. " " .. left
	local tone = if state.phase == "work" then "accent" else "success"
	if common.paused(state) then
		text = "⏸ " .. text
		tone = "muted"
	end
	return { { text = text, tone = tone, command = ACTION_TOGGLE } }
end)

poll()
