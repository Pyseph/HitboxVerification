--!strict
local StarterPlayer = game:GetService("StarterPlayer")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponData = require(ServerStorage.Data.DataTypes.WeaponData)

--- FUTURE EDIT
--- So, funny enough the animation editor in studio is mathematically wrong
--- as shown in my post here: https://devforum.roblox.com/t/animation-cubic-easing-direction-reversed/449068/38
--- I thought Roblox used this broken code in-game, but I believe in reality it's
--- just the animation editor that's broken. In-game, it's better to use
--- `TweenService:GetValue` instead for proper easing.
local EasingStyles = require(script.EasingStyles)

local ReplicatedAssets = ReplicatedStorage.Assets

local StarterCharacter = StarterPlayer.StarterCharacter

local Module = {}

local function OrderKeyframes(Keyframes)
	table.sort(Keyframes, function(a: Keyframe, b: Keyframe)
		return a.Time < b.Time
	end)
	return Keyframes
end
local function GetSequenceLength(Keyframes)
	Keyframes = OrderKeyframes(Keyframes)
	local LastKeyframe = Keyframes[#Keyframes]
	return LastKeyframe and LastKeyframe.Time or 0
end

local KeyframeSequences = {}
local AnimationLengths = {}

for _, Class in next, WeaponData.GetAllWeaponClasses() do
	local SequencesHolder = ReplicatedAssets.KeyframeSequences.Weapons:FindFirstChild(Class)

	if SequencesHolder then
		local ClassSequences = {}
		KeyframeSequences[Class] = ClassSequences

		for _, KeyframeSequence: KeyframeSequence in next, SequencesHolder:GetChildren() do
			local Keyframes = (KeyframeSequence:GetKeyframes() :: { any }) :: { Keyframe }

			local OrderedKeyframes = OrderKeyframes(Keyframes)
			local AnimationLength = GetSequenceLength(OrderedKeyframes)

			ClassSequences[KeyframeSequence.Name] = {
				Sequence = KeyframeSequence,
				Keyframes = OrderedKeyframes,
				Length = AnimationLength,
			}
			AnimationLengths[KeyframeSequence:GetAttribute("AnimationId")] = AnimationLength
		end
	else
		warn("No keyframe sequences found for weapon class: " .. Class)
	end
end

local ItemRigData = {}
for _, Rig in next, StarterCharacter["Right Arm"].AttachmentMotors:GetDescendants() do
	if Rig:IsA("Motor6D") then
		ItemRigData[Rig.Name] = {
			C0 = Rig.C0,
			C1 = Rig.C1,
		}
	end
end

local RootC0 = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0)
local RootC1 = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0)

local RightArmC0 = CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0)
local RightArmC1 = CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0)

--- FUTURE EDIT
--- If you're unfamiliar with the animation data format, each keyframe
--- has a bunch of poses; these poses are the CFrames of the parts during
--- each keyframe. The keyframe itself only has time data, and acts
--- as a container for the poses.
local function GetTimeFromPose(Pose: Pose): number
	return (Pose:FindFirstAncestorOfClass("Keyframe") :: Keyframe).Time
end
--- FUTURE EDIT
--- This was grabbed from the old animation editor's code. I forgot what it does at this point.
local function GetAlpha(Time: number, LastPose: Pose, NextPose: Pose)
	local TimeChunk = GetTimeFromPose(NextPose) - GetTimeFromPose(LastPose)
	local TimeIn = Time - GetTimeFromPose(LastPose)
	local Weight = TimeIn / TimeChunk

	return EasingStyles.GetEasing(LastPose.EasingStyle.Name, LastPose.EasingDirection.Name, 1 - Weight)
end

local function GetPose(Keyframe: Keyframe, SearchName): Pose?
	return Keyframe:FindFirstChild(SearchName, true) :: Pose?
end

--- FUTURE EDIT
--- Looking at this now I've no idea why it's so complicated-looking,
--- however the gist of it is you have a point between two markers on a line
--- and you want to find the two markers to the left and right of it.
--- This is what this function does.
local function GetNeighborPoses(Keyframes: { Keyframe }, Time, SearchName): (Pose?, Pose?)
	local LastIdx, NextIdx
	for Index, Keyframe in ipairs(Keyframes) do
		if Keyframe.Time > Time then
			LastIdx = Index - 1
			NextIdx = Index
			break
		end
	end

	if LastIdx == nil then
		LastIdx = #Keyframes
		NextIdx = #Keyframes
	elseif NextIdx == 1 then
		LastIdx = 1
		NextIdx = 0
	end

	local NextKeyframe = Keyframes[NextIdx]

	local Last = GetPose(Keyframes[LastIdx], SearchName)
	local Next = NextKeyframe and GetPose(NextKeyframe, SearchName) or nil

	if Last == nil then
		repeat
			LastIdx -= 1
		until GetPose(Keyframes[LastIdx], SearchName) ~= nil or LastIdx < 2
		Last = GetPose(Keyframes[LastIdx], SearchName)
	end
	if Next == nil then
		repeat
			NextIdx += 1
		until GetPose(Keyframes[NextIdx], SearchName) ~= nil or NextIdx >= #Keyframes
		Next = GetPose(Keyframes[NextIdx], SearchName) or Last
	end

	-- assert(Last, "Unable to find left-neighbor pose for " .. SearchName)
	return Last, Next
end

function Module.GetCFrameFromTrack(TrackData)
	local ClassSequences = KeyframeSequences[TrackData.Class]
	local AnimationData = ClassSequences and ClassSequences[TrackData.Name] or nil
	local AnimationSequence = AnimationData and AnimationData.Sequence or nil

	assert(ClassSequences, "Unable to find sequences for class " .. TrackData.Class)
	assert(AnimationData, "Unable to find animation for class " .. TrackData.Class .. " and name " .. TrackData.Name)
	assert(AnimationSequence, "No sequence for class " .. TrackData.Class .. " and name " .. TrackData.Name)

	local Keyframes = AnimationData.Keyframes

	--- FUTURE EDIT
	--- The stored animation data of the parts' CFrames is actually relative
	--- to its parent part, so we need to go backwards from the root part
	--- and iteratively multiply the CFrames of each limb to get
	--- the final CFrame of the attachment part that the weapon is welded to.
	local TorsoLastPose, TorsoNextPose = GetNeighborPoses(Keyframes, TrackData.Time, "Torso")
	local ArmLastPose, ArmNextPose = GetNeighborPoses(Keyframes, TrackData.Time, "Right Arm")
	local ProxyLastPose, ProxyNextPose =
		GetNeighborPoses(Keyframes, TrackData.Time, TrackData.Class .. "_RightArmEquipped")

	local TorsoAlpha = if TorsoLastPose and TorsoNextPose
		then GetAlpha(TrackData.Time, TorsoLastPose, TorsoNextPose)
		else 0
	local ArmAlpha = if ArmLastPose and ArmNextPose then GetAlpha(TrackData.Time, ArmLastPose, ArmNextPose) else 0

	local Rig = ItemRigData["Right" .. TrackData.Class]

	--- FUTURE EDIT
	--- Most of the time, your animation doesn't land exactly on a keyframe,
	--- so you need to interpolate between the two keyframes that your time
	--- is in between. This is what GetNeighborPoses and GetAlpha were for.
	local TorsoPose = if TorsoLastPose and TorsoNextPose
		then TorsoLastPose.CFrame:Lerp(TorsoNextPose.CFrame, TorsoAlpha)
		else CFrame.identity
	local ArmPose = if ArmLastPose and ArmNextPose
		then ArmLastPose.CFrame:Lerp(ArmNextPose.CFrame, ArmAlpha)
		else CFrame.identity
	local ProxyPose = if ProxyLastPose and ProxyNextPose
		then ProxyLastPose.CFrame:Lerp(ProxyNextPose.CFrame, ArmAlpha)
		else CFrame.identity

	local RelTorsoCFrame = RootC0 * TorsoPose * RootC1:Inverse()
	local RelRArmCFrame = RelTorsoCFrame * RightArmC0 * ArmPose * RightArmC1:Inverse()
	local RelAttachmentCFrame = RelRArmCFrame * Rig.C0 * ProxyPose * Rig.C1:Inverse()

	return {
		Torso = RelTorsoCFrame,
		RightArm = RelRArmCFrame,
		Attachment = RelAttachmentCFrame,
	}
end

function Module.GetAnimationLength(Animation)
	return AnimationLengths[Animation.AnimationId]
end

return Module
