--!strict
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerModules = ServerStorage.Modules
local ServerData = ServerStorage.Data

local WeaponData = require(ServerData.DataTypes.WeaponData)

local DamageModule = require(ServerModules.Combat.DamageModule)

local MovementModule = require(ServerModules.State.MovementModule)
local StateModule = require(ServerModules.State.StateModule)

local AnimationModule = require(ServerModules.Data.AnimationModule)
local ProfileModule = require(ServerModules.Data.ProfileModule)

local Timer = require(ServerModules.Patterns.Timer)
local EventModule = require(ServerModules.Patterns.EventModule)

local HitVerificationModule = require(script.HitVerificationModule)
local WeaponCasterModule = require(script.WeaponCasterModule)

local AudioModule = require(ReplicatedStorage.Modules.AudioModule)

local Module = {}

Module.CurrentCombo = {}
Module.LastAttacked = {}
Module.AnimationLengths = {}

local State = StateModule.State
local ImmutableState = StateModule.ImmutableState

local ReplicatedAssets = ReplicatedStorage.Assets

local OnPlayerStunned = EventModule.GetEvent("OnPlayerStunned")
local OnPlayerDamaged = EventModule.GetEvent("OnPlayerDamaged")

local function TimePassed(Timestamp, Duration)
	assert(Timestamp, "Argument #1 to 'TimePassed' is nil")
	assert(Duration, "Argument #2 to 'TimePassed' is nil")
	return os.clock() - Timestamp > Duration
end

local function StrictIndex(Table: {})
	setmetatable(Table, {
		__index = function(_, key)
			error("Unable to find value with that key - " .. tostring(key))
		end,
	})

	return Table
end

local SlashDataHolder = {}
function Module.GetSlashData(Character: Model, Class: string)
	local SlashData = SlashDataHolder[Character]
	local ItemData = SlashData and SlashData[Class]

	if not SlashData or not ItemData then
		local AnimationLengths = StrictIndex({})
		if not SlashData then
			SlashData = {}
			SlashDataHolder[Character] = SlashData

			Character.Destroying:Connect(function()
				SlashDataHolder[Character] = nil
			end)
		end
		assert(SlashData, "")

		SlashData[Class] = {
			LastAttacked = { Light = 0, Heavy = 0, Charge = 0 },
			CurrentCombo = { Light = 1, Heavy = 1, Charge = 1 },
			AnimationLengths = AnimationLengths,
		}

		local AnimationsHolder = ReplicatedAssets.Animations.Weapons[Class]
		for _, Animation in next, AnimationsHolder:GetChildren() do
			local AnimationLength = AnimationModule.GetAnimationLength(Animation)
			assert(AnimationLength, "No AnimationLength found for animation " .. Animation:GetFullName())
			AnimationLengths[Animation.Name] = AnimationLength
		end
	end

	return SlashData[Class]
end

function Module.CanUseAttackType(Character, ItemData: ProfileModule.WeaponItemData, AttackType: string)
	local StateManager = StateModule.GetStateManager(Character)

	if StateManager:GetState() == ImmutableState.Slashing then
		print("[SERVER - " .. ItemData.Class .. "] Still slashing")
		return
	end

	local SlashData = Module.GetSlashData(Character, ItemData.Class)
	local CombatData = WeaponData.GetCombatData(ItemData.Class)[AttackType]

	local LastAttacked = SlashData.LastAttacked
	local CurrentComboCount: number = SlashData.CurrentCombo[AttackType]
	local PreviousComboCount = math.max(CurrentComboCount - 1, 1)

	local AnimationSpeed = CombatData.AnimationSpeed or 1

	-- Reset combo if already reached last attack in combo
	if CurrentComboCount > CombatData.Length then
		SlashData.CurrentCombo[AttackType] = 1
		CurrentComboCount = 1
	end

	local TrackLength = CombatData.MainLength[CurrentComboCount] / AnimationSpeed
	local PreviousTrackLength = CombatData.MainLength[PreviousComboCount] / AnimationSpeed

	local DebounceTime = PreviousTrackLength + (CombatData.Recoveries[PreviousComboCount] or 0)

	-- Reset combo if too long time passed since last attack
	if TimePassed(LastAttacked[AttackType], math.max(DebounceTime + 1, 2)) then
		SlashData.CurrentCombo[AttackType] = 1
		CurrentComboCount = 1

		TrackLength = CombatData.MainLength[CurrentComboCount] / AnimationSpeed
		DebounceTime = TrackLength + (CombatData.Recoveries[CurrentComboCount] or 0)
	end

	-- Trying to attack before previous attack cools off?
	if not TimePassed(LastAttacked[AttackType], DebounceTime - 0.1) then
		return
	end

	return true
end

function Module.OnTypesCooldown(Character, ItemData)
	for _, AttackType in { "Light", "Heavy", "Charge" } do
		if not Module.CanUseAttackType(Character, ItemData, AttackType) then
			return true
		end
	end
	return false
end

local PreviousItems: { [Model]: ProfileModule.WeaponItemData } = {}
function Module.CanSlash(Character: Model, ItemData: ProfileModule.WeaponItemData)
	local HumanoidRoot = Character:FindFirstChild("HumanoidRootPart") or nil

	if not HumanoidRoot then
		print("[SERVER - " .. ItemData.Class .. "] No HumanoidRootPart found")
		return false
	elseif Module.OnTypesCooldown(Character, ItemData) then
		return false
	end

	local PreviousItem = PreviousItems[Character]
	if PreviousItem and Module.OnTypesCooldown(Character, PreviousItem) then
		return false
	end

	return true
end

local CollidedConnections = {}
function Module.Slash(Character: Model, AttackType: string, ItemData: ProfileModule.WeaponItemData)
	if not Module.CanSlash(Character, ItemData) then
		print("Cannot slash")
		return
	end
	print("Attacking")

	local StateManager = StateModule.GetStateManager(Character)

	local SlashData = Module.GetSlashData(Character, ItemData.Class)
	local CombatData = WeaponData.GetCombatData(ItemData.Class)[AttackType]

	local ComboCount = SlashData.CurrentCombo[AttackType] :: number

	local AnimationName = AttackType .. "_" .. ComboCount
	local AnimationLength = (SlashData.AnimationLengths[AnimationName] :: number) / (CombatData.AnimationSpeed or 1)

	SlashData.CurrentCombo[AttackType] = ComboCount + 1
	SlashData.LastAttacked[AttackType] = os.clock()

	local HitboxTimes = CombatData.Hitbox[ComboCount]
	local HitboxStart, HitboxEnd = unpack(HitboxTimes)

	local DamageTimer = Timer.EventTimer.new(HitboxEnd, Character, OnPlayerStunned, OnPlayerDamaged)
	StateManager:SetState(ImmutableState.Slashing)

	PreviousItems[Character] = ItemData

	local Restrained = MovementModule.RestrainCharacter({
		RestrainedJumpPower = 0,
		RestrainedWalkSpeed = 6,
		CanRotate = true,

		Duration = 10,
		Target = Character,
	})

	local CasterHitConnection: RBXScriptConnection?
	local Caster = WeaponCasterModule.GetCaster(Character, ItemData.Serial)

	local WasDisrupted = false
	local function TimerCallback(TimerState)
		WasDisrupted = true

		task.delay(TimerState == "Stopped" and 0 or 0.45, function()
			if CasterHitConnection then
				CasterHitConnection:Disconnect()
				CollidedConnections[Character] = nil
			end
			if StateManager:GetState() ~= ImmutableState.Slashing then
				Caster:Stop()
			end
		end)
		Restrained:Disconnect()
	end

	task.delay(HitboxStart, function()
		local AlreadyDamaged = {}

		DamageTimer:OnStopped(function()
			TimerCallback("Stopped")
		end)
		DamageTimer:OnFinished(function()
			TimerCallback("Finished")
		end)

		task.delay(HitboxEnd, function()
			StateManager:SetState(State.Idling)
		end)

		DamageTimer:Start()
		Caster:Start()

		if CollidedConnections[Character] then
			CollidedConnections[Character]:Disconnect()
		end
		CasterHitConnection = Caster.HumanoidCollided:Connect(
			function(Data, HitHumanoid: Humanoid, AttachmentName, HitTime, TimePositionA, TimePositionB, LimbPosition)
				local HitCharacter = HitHumanoid.Parent
				if AlreadyDamaged[HitCharacter] or HitCharacter == Character then
					return
				elseif type(HitTime) ~= "number" then
					return
				elseif
					typeof(LimbPosition) ~= "Vector3"
					or type(TimePositionA) ~= "number"
					or type(TimePositionB) ~= "number"
				then
					return
				end

				if
					not HitVerificationModule.IsValidHit({
						Character = Character,
						RayData = Data,
						HitHumanoid = HitHumanoid,
						HitTime = HitTime,
						AnimationData = {
							Length = AnimationLength,
							Name = AnimationName,

							TimePositionA = math.clamp(TimePositionA, 0, AnimationLength),
							TimePositionB = math.clamp(TimePositionB, 0, AnimationLength),
							LimbPosition = LimbPosition,
						},
						CombatData = CombatData,
						AttachmentName = AttachmentName,
						ItemData = ItemData,
					})
				then
					return
				end

				AlreadyDamaged[HitCharacter] = true

				if Character then
					DamageModule.DealDamage({
						Damaging = HitCharacter :: Model,
						DamagedBy = Character,
						CombatData = CombatData,
						AttackIndex = ComboCount,
					}, {
						{
							CFrame = CFrame.lookAt(Data.Position, Data.Position + Data.Normal),
							Fade = false,
							Name = "Hit Blunt",
						},
					})
				end
			end
		)
		CollidedConnections[Character] = CasterHitConnection :: RBXScriptConnection
	end)

	if CombatData.SlashSound then
		task.delay(HitboxStart, function()
			if WasDisrupted then
				return
			end
			AudioModule.PlayWeaponSound(Character, ItemData.Class, CombatData.SlashSound)
		end)
	end
end

return Module
