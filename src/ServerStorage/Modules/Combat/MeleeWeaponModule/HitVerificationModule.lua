local Module = {}

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestService = game:GetService("TestService")
local StarterPlayer = game:GetService("StarterPlayer")

local ServerModules = ServerStorage.Modules

local AnimationModule = require(ServerModules.Data.AnimationModule)
local EntityPositionBuffer = require(ServerModules.Data.EntityPositionBuffer)

local Gizmo = require(ReplicatedStorage.Modules.Debug.Gizmo)

--- FUTURE EDIT
--- For some context, I didn't rig the weapons directly to the arm, but instead
--- had invisible parts that were rigged to the arm, and then used a normal weld
--- to attach the weapon to the invisible part. This made it easier for adding more
--- weapons and changing the position of the weapon in the arm.
local EQUIPPED_PROXY_SUFFIX = "RightArmEquipped"

local ProxyEquipOffsets = {}
for _, ProxyHolder in next, StarterPlayer.StarterCharacter.Attachments:GetChildren() do
	for _, Proxy in next, ProxyHolder:GetChildren() do
		if string.find(Proxy.Name, EQUIPPED_PROXY_SUFFIX) then
			local ProxyOffset = Proxy:FindFirstChildOfClass("Attachment")
			if ProxyOffset then
				ProxyEquipOffsets[ProxyHolder.Name] = ProxyOffset.CFrame
			end
			break
		end
	end
end

local HitboxData = {}
for _, DataType in next, ServerStorage.Objects.DataTypes:GetChildren() do
	local DataTypeData = {}
	for _, ClassFolder in next, DataType:GetChildren() do
		local ClassData = {}
		for _, ItemModel in next, ClassFolder:GetChildren() do
			local Hitbox = ItemModel.Hitbox
			local PrimaryPart = ItemModel.PrimaryPart
			local HandleAttachment = PrimaryPart:FindFirstChild("HandleAttachment")
			assert(PrimaryPart ~= nil, ItemModel.Name .. " has no PrimaryPart set")

			local AttachmentCount = 0
			for _, Attachment in next, Hitbox:GetChildren() do
				if Attachment:IsA("Attachment") then
					AttachmentCount += 1
					Attachment.Name = "DmgPoint" .. AttachmentCount
				end
			end

			local AttachmentOffset = HandleAttachment and HandleAttachment.CFrame or CFrame.identity
			local ProxyOffset = ProxyEquipOffsets[ClassFolder.Name] or CFrame.identity
			local HitboxOffset = (PrimaryPart.CFrame * AttachmentOffset):ToObjectSpace(Hitbox.CFrame)

			--- FUTURE EDIT
			--- Here I store the weld offset of the weapon to the proxy part. This is used to calculate the
			--- CFrame of the weapon in the character's hand.
			ClassData[ItemModel.Name] = {
				ProxyOffset = ProxyOffset,
				Offset = HitboxOffset,
				Object = Hitbox
			}
		end
		DataTypeData[ClassFolder.Name] = ClassData
	end

	HitboxData[DataType.Name] = DataTypeData
end

-- https://devforum.roblox.com/t/finding-the-closest-vector3-point-on-a-part-from-the-character/130679
local function ClosestPointOnPart(PartCFrame: CFrame, PartSize: Vector3, Point: Vector3)
	local Transform = PartCFrame:PointToObjectSpace(Point) -- Transform into local space
	local HalfSize = PartSize * 0.5
	return PartCFrame * Vector3.new( -- Clamp & transform into world space
		math.clamp(Transform.X, -HalfSize.X, HalfSize.X),
		math.clamp(Transform.Y, -HalfSize.Y, HalfSize.Y),
		math.clamp(Transform.Z, -HalfSize.Z, HalfSize.Z)
	)
end

function Module.CalculateProxyCFrame(Data)
	local CurrentCFrames = AnimationModule.GetCFrameFromTrack(Data.Track)
	if TestService.Visuals.Hitbox:GetAttribute("ServerRootCFrame") then
		Gizmo:DrawBox(Data.RootCFrame * CurrentCFrames.Torso, Vector3.new(2, 2, 1), 3, Color3.new(0, 1, 0))
	end
	if TestService.Visuals.Hitbox:GetAttribute("ServerProxyCFrame") then
		Gizmo:DrawSphere(Data.RootCFrame * CurrentCFrames.Attachment.Position, 0.05, Color3.new(0, 1, 0), 5)
		--Gizmo:DrawCFrame(Data.RootCFrame * CurrentCFrames.Attachment, 2, 5)
	end

	return CurrentCFrames.Attachment
end

function Module.GetAttachmentCFrame(Data)
	local ItemData = Data.ItemData
	local RelativeHandleCFrame = Module.CalculateProxyCFrame(Data)

	local ItemHitboxData = HitboxData[ItemData.DataType][ItemData.Class][ItemData.Name]
	local HitboxCFrame = RelativeHandleCFrame * ItemHitboxData.ProxyOffset * ItemHitboxData.Offset

	return HitboxCFrame:ToWorldSpace(ItemHitboxData.Object[Data.AttachmentName].CFrame)
end

-- Get distance of point p0 from line p1p2
local function DistanceFromLine(p0, p1, p2)
	return (p2 - p1):Cross(p1 - p0).Magnitude / (p2 - p1).Magnitude
end

function Module.GetHitDistance(Data)
	--- FUTURE EDIT
	--- since a raycast is just drawing a line from point A to point B, I get the two points
	--- from which the raycast was calculated from on the client to ensure I'm getting the
	--- same line on the server as the client.
	Data.Track.Time = Data.Track.TimeA
	local CurrentCFrame = Module.GetAttachmentCFrame(Data)

	if TestService.Visuals.Hitbox:GetAttribute("ServerAttachmentCFrame") then
		Gizmo:DrawSphere(Data.RootCFrame * CurrentCFrame.Position, 0.075, Color3.new(0, 1, 0), 5)
		--Gizmo:DrawCFrame(Data.RootCFrame * CurrentCFrame, 2, 5)
	end

	Data.Track.Time = Data.Track.TimeB
	local LastCFrame = Module.GetAttachmentCFrame(Data)

	if TestService.Visuals.Hitbox:GetAttribute("ServerHitLine") then
		Gizmo:DrawLine(Data.RootCFrame * CurrentCFrame.Position, Data.RootCFrame * LastCFrame.Position, nil, 3, Color3.new(0, 1, 0))
	end
	--- FUTURE EDIT
	--- This is the big part. I compare how much the line from the server's raycast line deviates
	--- from the client's raycast line. If it deviates too much, then it's likely that the hit was
	--- spoofed.
	return DistanceFromLine(Data.RootCFrame:PointToObjectSpace(Data.HitPosition), CurrentCFrame.Position, LastCFrame.Position)
end

function Module.IsValidHit(HitData)
	local RayData = HitData.RayData
	local AnimationData = HitData.AnimationData
	local ItemData = HitData.ItemData
	local CombatData = HitData.CombatData

	local HitCharacter = HitData.HitHumanoid.Parent
	local TravelTime = math.clamp(workspace:GetServerTimeNow() - HitData.HitTime, 0, 1)

	--- FUTURE EDIT
	--- This was used to make sure it didn't accept hits that were clearly out of reach.
	if TestService.Characters.Players:GetAttribute("SpoofHitbox") then
		RayData.Instance = HitCharacter["Right Leg"]
	end

	--- FUTURE EDIT
	--- Since the server's character position is not the same as the client's at the time of when the hit was
	--- calculated, I had used a buffer to go back in time to get the position of the limbs at the time of the hit.
	local LimbPositions = EntityPositionBuffer.GetLimbPositions(HitData.Character, TravelTime)
	local HitLimbPositions = EntityPositionBuffer.GetLimbPositions(HitCharacter, TravelTime) 
	local HitPosition = RayData.Position

	local CachedLimbCFrame = HitLimbPositions[RayData.Instance.Name]

	--- FUTURE EDIT
	--- The biggest place for exploitation in the hit detection were the limb positions. For better anti-exploit
	--- measures, this would require a lot more finetuning to make sure its better in-sync with the client, while
	--- making sure it wasn't spoofed.
	if not CachedLimbCFrame then
		warn("Unable to limb CFrame for", RayData.Instance)
		return
	elseif (AnimationData.LimbPosition - CachedLimbCFrame.Position).Magnitude > 7 then
		warn("Possible Instance exploit (1). Distance:", (AnimationData.LimbPosition - CachedLimbCFrame.Position).Magnitude)
		return
	elseif (HitPosition - ClosestPointOnPart(CachedLimbCFrame, RayData.Instance.Size, HitPosition)).Magnitude > 4 then
		warn("Possible instance exploit (2). Distance:", HitPosition - ClosestPointOnPart(CachedLimbCFrame, RayData.Instance.Size, HitPosition))
	end
	--print(HitPosition - ClosestPointOnPart(CachedLimbCFrame, Data.Instance.Size, HitPosition))

	local Distance = Module.GetHitDistance({
		Class = ItemData.Class,

		Track = {
			TimeA = AnimationData.TimePositionA,
			TimeB = AnimationData.TimePositionB,
			Length = AnimationData.Length,

			Name = AnimationData.Name,
			Class = ItemData.Class,
		},

		AnimationName = AnimationData.Name,

		HitPosition = HitPosition,
		ItemData = ItemData,
		AttachmentName = HitData.AttachmentName,

		RootCFrame = LimbPositions.HumanoidRootPart,
		Character = HitData.Character
	})

	if TestService.Visuals.Hitbox:GetAttribute("ServerHitDistance") then
		print("Calculated distance:", Distance)
	end
	if Distance > CombatData.MaxHitReach then
		warn("Out of reach", ItemData.Class, AnimationData.Name)
		warn(CombatData.MaxHitReach, Distance)
		return
	end

	return true
end

return Module