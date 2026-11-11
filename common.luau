--!strict
-- pomodoro, shared module: the timer's state machine and its formatting.
-- Pure functions of (state, now); `now` is os.time() seconds. No Tern calls.

local common = {}

-- Durations in seconds. Edit these to change the timer.
common.DURATION = {
	work = 25 * 60,
	short_break = 5 * 60,
	long_break = 15 * 60,
}
-- A long break follows every Nth finished work session.
common.LONG_BREAK_EVERY = 4

-- Default sounds the host half plays when a phase ends: a finished work
-- session, and a finished break. The user's choice (kv `settings`, set with the
-- "Set ... sound" commands) wins; set a default to common.NONE for silence.
common.SOUND = {
	work_done = "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
	break_done = "/usr/share/sounds/freedesktop/stereo/complete.oga",
}
-- Players are tried in order; the first that starts and exits cleanly wins.
common.PLAYERS = { "pw-play", "paplay" }
-- Stored instead of a path (kv `settings`) to turn a sound off.
common.NONE = "none"

export type Phase = "idle" | "work" | "short_break" | "long_break"

-- `end_epoch` is set while a phase runs, `paused_remaining` while it is paused,
-- and neither while idle. `completed` counts work sessions that ran to the end.
export type State = {
	phase: Phase,
	end_epoch: number?,
	paused_remaining: number?,
	completed: number,
}

export type Op = "start" | "pause" | "toggle" | "reset" | "skip"

-- A window's command for the host half (an entry of kv `requests`).
export type Request = {
	op: Op,
	id: string,
	at: number, -- os.time() when issued
}

function common.new(): State
	return { phase = "idle", end_epoch = nil, paused_remaining = nil, completed = 0 }
end

local function begin(state: State, phase: Phase, now: number): State
	return {
		phase = phase,
		end_epoch = now + common.DURATION[phase],
		paused_remaining = nil,
		completed = state.completed,
	}
end

function common.running(state: State): boolean
	return state.phase ~= "idle" and state.end_epoch ~= nil
end

function common.paused(state: State): boolean
	return state.phase ~= "idle" and state.paused_remaining ~= nil
end

-- Whole seconds left in the phase; 0 when idle.
function common.remaining(state: State, now: number): number
	if state.paused_remaining ~= nil then
		return state.paused_remaining
	end
	if state.end_epoch ~= nil then
		return math.max(0, state.end_epoch - now)
	end
	return 0
end

-- Whether a running phase's end has passed.
function common.expired(state: State, now: number): boolean
	return common.running(state) and common.remaining(state, now) == 0
end

-- The state after the current phase ends or is skipped: work to a break, a
-- break to work. A phase that ran to the end counts; a skipped one does not.
function common.advance(state: State, now: number, skipped: boolean): State
	local completed = state.completed
	if state.phase == "work" then
		if not skipped then
			completed += 1
		end
		local long = not skipped and completed % common.LONG_BREAK_EVERY == 0
		return begin({ phase = "idle", completed = completed }, if long then "long_break" else "short_break", now)
	end
	return begin({ phase = "idle", completed = completed }, "work", now)
end

-- Pauses a running phase, resumes a paused one; idle stays idle.
function common.toggle_pause(state: State, now: number): State
	if common.paused(state) then
		return {
			phase = state.phase,
			end_epoch = now + (state.paused_remaining :: number),
			paused_remaining = nil,
			completed = state.completed,
		}
	end
	if common.running(state) then
		return {
			phase = state.phase,
			end_epoch = nil,
			paused_remaining = common.remaining(state, now),
			completed = state.completed,
		}
	end
	return state
end

local PHASE_NAME = { work = "work", short_break = "break", long_break = "long break" }

function common.phase_name(phase: Phase): string
	return PHASE_NAME[phase] or ""
end

-- Applies a request op. Returns the new state and a short past-tense note
-- ("started", "paused"), or nil when the op changes nothing.
function common.apply(state: State, op: Op, now: number): (State, string?)
	if op == "toggle" then
		op = if state.phase == "idle" then "start" else "pause"
	end
	local idle = state.phase == "idle"
	if op == "start" and idle then
		return begin(state, "work", now), "started"
	elseif op == "pause" and not idle then
		return common.toggle_pause(state, now), if common.paused(state) then "resumed" else "paused"
	elseif op == "reset" and not (idle and state.completed == 0) then
		return common.new(), "reset"
	elseif op == "skip" and not idle then
		local next = common.advance(state, now, true)
		return next, "skipped to " .. common.phase_name(next.phase)
	end
	return state, nil
end

-- 83 -> "01:23". Minutes are not capped at 59.
function common.format(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

-- Validates a state read from kv; anything malformed counts as idle.
function common.parse(value: any): State
	if type(value) ~= "table" then
		return common.new()
	end
	local phase = value.phase
	if phase ~= "work" and phase ~= "short_break" and phase ~= "long_break" then
		return common.new()
	end
	local completed = if type(value.completed) == "number" then value.completed else 0
	local end_epoch = if type(value.end_epoch) == "number" then value.end_epoch else nil
	local paused = if type(value.paused_remaining) == "number" then value.paused_remaining else nil
	if end_epoch == nil and paused == nil then
		return { phase = "idle", end_epoch = nil, paused_remaining = nil, completed = completed }
	end
	return { phase = phase, end_epoch = end_epoch, paused_remaining = paused, completed = completed }
end

return common
