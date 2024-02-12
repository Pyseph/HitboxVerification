--!strict
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local ServerModules = ServerStorage.Modules

local ClientCast = require(ServerModules.Combat.ClientCast)

local Module = {}
Module.HitboxCasters = {}

local CachedCharacters = {}

--- FUTURE EDIT: "Data" in this case means telling the client when to create and stop a hitbox.
--- In my game, I edited ClientCast into creating casters by itself on the client, and have the client itself
--- decide when to start and stop the caster. This way, the server doesn't have to tell the client when to start and stop
--- which saves some minuscule data, but more importantly avoids the delay from the server to the client.

-- determine on whether it's necessary to send data to the client again.
-- Data should only be sent to the client once.

local function GetCasterState(Character: Model, Serial)
	local CharacterCache = CachedCharacters[Character]

	if CharacterCache == nil then
		if Character then
			CachedCharacters[Character] = {}
		end

		return "Default"
	end
	if CharacterCache[Serial] == nil then
		return "Default"
	end

	return "NoReplication"
end

function Module.GetCaster(Character, Serial)
	local Player = Players:GetPlayerFromCharacter(Character)
	local SavedCaster = Module.HitboxCasters[Serial]

	if not SavedCaster then
		local RayParams = RaycastParams.new()
		RayParams.FilterType = Enum.RaycastFilterType.Whitelist
		RayParams.FilterDescendantsInstances = {
			workspace.Characters.Players,
			workspace.Characters.Mobs,
		}

		SavedCaster = ClientCast.new(Serial, RayParams, Player)
		Module.HitboxCasters[Serial] = SavedCaster
	end

	return Player and setmetatable({
		Start = function()
			SavedCaster:Start(GetCasterState(Player.Character, Serial))
		end,
		Stop = function()
			SavedCaster:Stop("NoReplication")
			CachedCharacters[Player.Character][Serial] = true
		end,
	}, {
		__index = SavedCaster,
		__newindex = SavedCaster
	}) or SavedCaster
end

local function OnPlayerAdded(Player)
	Player.CharacterRemoving:Connect(function(Character)
		CachedCharacters[Character] = nil
	end)
end

for _, Player in Players:GetPlayers() do
	OnPlayerAdded(Player)
end
Players.PlayerAdded:Connect(OnPlayerAdded)

return Module