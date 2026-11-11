--!strict
-- pomodoro, shared module: which sound a phase end plays, and how to play a
-- file. Used by the host half (phase end) and the window half (preview).

local common = require("./common")

local sound = {}

export type Slot = "work_sound" | "break_sound"

-- A player that hangs (no audio server) is killed after this long.
local PLAYER_TIMEOUT_MS = 60000

-- Each slot of kv `settings` holds a file path, or common.NONE for silence.
local DEFAULT: { [Slot]: string } = {
	work_sound = common.SOUND.work_done,
	break_sound = common.SOUND.break_done,
}

-- The sound `slot` plays now: the saved choice when it is silence or a file
-- that exists, else the default from common.luau. nil means no sound.
function sound.resolve(slot: Slot): string?
	local settings = tern.kv.get("settings")
	local saved: any = if type(settings) == "table" then settings[slot] else nil
	if saved == common.NONE then
		return nil
	end
	if type(saved) == "string" and tern.fs.exists(saved) then
		return saved
	end
	local default = DEFAULT[slot]
	return if default ~= common.NONE then default else nil
end

-- Plays `path` with the first player in `common.PLAYERS` that starts and exits
-- cleanly. The process runs in the background; callers never wait on it.
function sound.play(path: string, index: number?)
	local at = index or 1
	local player = common.PLAYERS[at]
	if player == nil then
		tern.log.warn("pomodoro: no sound player worked for " .. path)
		return
	end
	local function fallback(why: string)
		tern.log.warn(string.format("pomodoro: %s failed (%s)", player, why))
		sound.play(path, at + 1)
	end
	-- Starting a process raises when the player is not installed.
	local ok, err = pcall(function()
		tern.process.run({ player, path }, { timeout_ms = PLAYER_TIMEOUT_MS }, function(result)
			-- A timeout means the sound was playing: it is not played again.
			if result.status ~= 0 and not result.timed_out then
				fallback("exit " .. result.status)
			end
		end)
	end)
	if not ok then
		fallback(tostring(err))
	end
end

return sound
