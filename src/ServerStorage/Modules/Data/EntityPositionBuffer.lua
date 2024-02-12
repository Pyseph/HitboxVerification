local Module = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CircularBuffer = require(ReplicatedStorage.Modules.DataStructures.CircularBuffer)

local BufferLifetime = 0.5
--- FUTURE EDIT: I set the update rate to 62 instead of 60 because sometimes Roblox's frame rate can
--- vary a bit, going below and above 60 FPS. Obviously at this point I should've just not used
--- any update rates in the first place and instead used the time passed since the last update, but
--- this is old code and I was still experimenting with lower update rates and whether there were any
--- performance impacts at updating each frame.
local UpdateRate = 62
local UpdateTime = 1 / UpdateRate

local PlayerBuffer = CircularBuffer.new(UpdateRate * BufferLifetime)

local CachedPlayerLimbs = {}
local function OnCharacterAdded(Character, Cache)
	local LimbsData = {
		NormalLimbs = {},
		HumanoidRootPart = nil,
	}

	Character.DescendantAdded:Connect(function(Object)
		if Object:IsA("BasePart") then
			LimbsData.NormalLimbs[Object] = Object.Name
		end
	end)
	Character.DescendantRemoving:Connect(function(Object)
		if LimbsData.NormalLimbs[Object] then
			LimbsData.NormalLimbs[Object] = nil
		end
	end)

	for _, Object in Character:GetDescendants() do
		if Object:IsA("BasePart") then
			LimbsData.NormalLimbs[Object] = Object.Name
		end
	end

	Character.Destroying:Connect(function()
		Cache[Character] = nil
	end)
	Cache[Character] = LimbsData
end
for _, PlayerCharacter in workspace.Characters.Players:GetChildren() do
	task.spawn(OnCharacterAdded, PlayerCharacter, CachedPlayerLimbs)
end
workspace.Characters.Players.ChildAdded:Connect(function(PlayerCharacter)
	OnCharacterAdded(PlayerCharacter, CachedPlayerLimbs)
end)

local function GetLimbData(_, Cache)
	local Data = {}
	for Limb, LimbName in Cache.NormalLimbs do
		Data[LimbName] = { Limb.CFrame, Limb.AssemblyLinearVelocity }
	end

	return Data
end

local LastUpdated = 0
RunService.Heartbeat:Connect(function()
	local Now = os.clock()
	if Now - LastUpdated > UpdateTime then
		LastUpdated = Now
	end
	debug.profilebegin("CFrame CircularBuffer main loop")

	local LimbData = {}
	local ToAppend = {
		Time = Now,
		LimbData = LimbData,
	}

	debug.profilebegin("Get player CFrames")
	for _, Character in workspace.Characters.Players:GetChildren() do
		LimbData[Character] = GetLimbData(Character, CachedPlayerLimbs[Character])
	end
	debug.profileend()

	PlayerBuffer:push(ToAppend)
	debug.profileend()
end)

function Module.GetLimbPositions(Character, Time)
	if Time > 1 then
		error("Too long time has passed; data no longer cached")
	end

	local Now = os.clock()
	local Index = Time * UpdateRate
	local LeftIndex = math.max(math.floor(Index), 1)
	local RightIndex = LeftIndex + 1

	local Alpha = (Index - LeftIndex)
	Alpha = Alpha ~= Alpha and 1 or Alpha

	local LeftBufferData = PlayerBuffer[LeftIndex]
	assert(LeftBufferData, "Left buffer data is nil. Index: " .. LeftIndex)
	local RightBufferData = RightIndex <= UpdateRate and PlayerBuffer[RightIndex] or LeftBufferData

	local LeftFrameLimbData = LeftBufferData.LimbData[Character]
	local RightFrameLimbData = RightBufferData.LimbData[Character]

	if LeftFrameLimbData == nil then
		error("Left data is nil. Index:", LeftIndex)
	end

	local LerpedData = {}

	for LimbName, LeftLimbData in LeftFrameLimbData do
		local RightLimbData = RightFrameLimbData[LimbName]
		local LerpedCFrame = LeftLimbData[1]:Lerp(RightLimbData[1], Alpha)
		-- Extrapolate CFrame with velocity
		local RightVelocity = RightLimbData[2] * (Now - RightBufferData.Time)
		local ExtrapolatedCFrame = LerpedCFrame + RightVelocity
		LerpedData[LimbName] = ExtrapolatedCFrame
	end

	return LerpedData
end

return Module
