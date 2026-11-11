--!strict
-- pomodoro, host half: the authoritative timer and the only writer of kv
-- `state`. The window half writes kv `requests` (commands) and `settings`
-- (sound choice) and never `state`.
--
-- A 1 s timer runs for as long as the plugin is loaded: it runs new requests,
-- advances the phase when its wall-clock end has passed, sends the desktop
-- notification and plays the sound. State holds an `end_epoch`, not a
-- countdown, so a reload or a daemon restart resumes where the clock says.
--
-- kv `state` is the timer's fields plus `handled`: the ids of the requests
-- the host has seen. It is written in the same set as the phase they changed,
-- so a request runs exactly once even if a save fails or a reload comes between.

local common = require("./common")
local sound = require("./sound")

local TICK_MS = 1000
-- A request older than this is stale (left over from a daemon that was down)
-- and is dropped instead of run.
local REQUEST_MAX_AGE_S = 10
-- A notify-send that hangs is killed after this long.
local NOTIFY_TIMEOUT_MS = 10000

local function load_state(): (common.State, { string })
	local raw = tern.kv.get("state")
	local handled: { string } = {}
	if type(raw) == "table" and type(raw.handled) == "table" then
		for _, id in raw.handled do
			if type(id) == "string" then
				table.insert(handled, id)
			end
		end
	end
	return common.parse(raw), handled
end

local function save_state(state: common.State, handled: { string })
	tern.kv.set("state", {
		phase = state.phase,
		end_epoch = state.end_epoch,
		paused_remaining = state.paused_remaining,
		completed = state.completed,
		handled = handled,
	})
	tern.log.info(
		string.format("pomodoro: %s, %d done, %ds left", state.phase, state.completed, common.remaining(state, os.time()))
	)
end

local function notify(summary: string, body: string)
	-- Starting a process raises when notify-send is not installed.
	local ok, err = pcall(function()
		local argv = { "notify-send", "--app-name=Tern Pomodoro", "--icon=appointment-soon", summary, body }
		tern.process.run(argv, { timeout_ms = NOTIFY_TIMEOUT_MS }, function(result)
			if result.status ~= 0 then
				tern.log.warn("pomodoro: notify-send exited " .. result.status .. ": " .. result.stderr)
			end
		end)
	end)
	if not ok then
		tern.log.warn("pomodoro: notify-send unavailable: " .. tostring(err))
	end
end

local function play_for(slot: sound.Slot)
	local path = sound.resolve(slot)
	if path ~= nil then
		sound.play(path)
	end
end

-- `finished` ended; `next` is the phase that started in its place.
local function announce(finished: common.Phase, next: common.Phase)
	local body = string.format("%s, %s", common.phase_name(next), common.format(common.DURATION[next]))
	if finished == "work" then
		notify("Pomodoro done", "Time for a " .. body)
		play_for("work_sound")
	else
		notify("Break over", "Back to " .. body)
		play_for("break_sound")
	end
end

-- Runs, in order, the requests not yet handled. Returns the new state and the
-- ids now in kv `requests` (the windows drop old ones, so this stays short).
local function run_requests(state: common.State, handled: { string }, now: number): (common.State, { string })
	local requests = tern.kv.get("requests")
	local seen: { string } = {}
	if type(requests) ~= "table" then
		return state, seen
	end
	local done: { [string]: boolean } = {}
	for _, id in handled do
		done[id] = true
	end
	for _, request in requests do
		if type(request) == "table" and type(request.id) == "string" then
			table.insert(seen, request.id)
			local fresh = type(request.at) == "number" and now - request.at <= REQUEST_MAX_AGE_S
			if fresh and not done[request.id] then
				state = (common.apply(state, request.op, now))
			end
		end
	end
	return state, seen
end

local function tick()
	local now = os.time()
	local state, handled = load_state()
	local before, before_handled = state, table.concat(handled, ",")
	-- The expiry comes first, so a request in the same tick acts on the new
	-- phase and cannot swallow the announcement.
	local finished: common.Phase? = nil
	local started: common.Phase? = nil
	if common.expired(state, now) then
		finished = state.phase
		state = common.advance(state, now, false)
		started = state.phase
	end
	state, handled = run_requests(state, handled, now)
	if state ~= before or table.concat(handled, ",") ~= before_handled then
		save_state(state, handled)
	end
	-- After the save: a failing announcement must not repeat every tick.
	if finished ~= nil and started ~= nil then
		announce(finished, started)
	end
end

local function loop()
	xpcall(tick, function(err: any)
		tern.log.error("pomodoro: tick failed: " .. tostring(err))
	end)
	tern.timer(TICK_MS, loop)
end

loop()
