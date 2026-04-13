--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Modules //--
local Packets = require(ReplicatedStorage:WaitForChild("Packets"))

--// Variables //--
local ReplicationAssets = ReplicatedStorage.ReplicationAssets

local Camera = workspace.CurrentCamera :: Camera

local Player = Players.LocalPlayer
local Character = script.CharacterController

local Core = Character:WaitForChild("Core")
local Controller = Character.Default:WaitForChild("Controller") :: LinearVelocity
local HorizontalOrientation = Character.Default:WaitForChild("HorizontalOrentation") :: AlignOrientation
local Jump = Character.Default:WaitForChild("Jump") :: LinearVelocity

local MoveSpeed = 20

local MoveDirection = Vector3.zero
local IsJumping = false

local LastActivity = os.clock()
local IsActive = true
local IdleThreshold = 3

local LastSentCFrame = CFrame.new()
local PositionThreshold = 0.05
local RotationThreshold = 0.02

--// Jump handling connection
--// Uses a LinearVelocity impulse instead of Humanoid states, giving deterministic physics control
--// Tweening the LineVelocity creates a short acceleration curve instead of an instant force spike
UserInputService.InputBegan:Connect(function(Input, GPE)
	if GPE or Input.KeyCode ~= Enum.KeyCode.Space or IsJumping then
		return 
	end

	IsJumping = true
	Jump.Enabled = true
	LastActivity = os.clock()

	local Tween = TweenService:Create(Jump, TweenInfo.new(0.1), { LineVelocity = 25 })
	Tween:Play()
	Tween.Completed:Wait()

	Jump.Enabled = false
	Jump.LineVelocity = 15

	task.wait(0.3)

	IsJumping = false
end)

--// Activity tracking connection
--// Updates last input time to drive idle-based network throttling (prevents constant replication spam)
UserInputService.InputEnded:Connect(function(Input)
	if Input.KeyCode == Enum.KeyCode.W or Input.KeyCode == Enum.KeyCode.A or Input.KeyCode == Enum.KeyCode.S or Input.KeyCode == Enum.KeyCode.D then
		LastActivity = os.clock()
	end
end)

--// Input -> movement vector abstraction
--// Decouples raw input from physics, allowing custom controller logic and camera-relative movement
local function GetMoveDirection()
	local Direction = Vector3.zero

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then Direction += Vector3.new(0, 0, 1) end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then Direction += Vector3.new(0, 0, -1) end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then Direction += Vector3.new(-1, 0, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then Direction += Vector3.new(1, 0, 0) end

	--// Normalization prevents faster diagonal movement (classic vector math issue)
	return Direction.Magnitude > 0 and Direction.Unit or Vector3.zero
end

local BufferTime = 0.15
local MaxBufferSize = 30
local History: { [number]: { { Time: number, CFrame: CFrame } } } = {}
local AnimationCache = {}

--// Remote character replication handler
--// Responsible for:
 --> Lazy rig creation (client-side prediction model)
 --> Buffering snapshots for interpolation
 --> Animation state management based on movement delta
local function UpdateCharacter(OtherPlayer: Player, NewCFrame: CFrame)
	local PlayerRig: Model = workspace.Characters:FindFirstChild(tostring(OtherPlayer.UserId)) or workspace.Characters:FindFirstChild(OtherPlayer.DisplayName)

	--// Create visual proxy if it doesn't exist (decoupled from actual Player.Character)
	if not PlayerRig then
		PlayerRig = ReplicationAssets.R15:Clone()
		PlayerRig.Name = OtherPlayer.DisplayName or tostring(OtherPlayer.UserId)
		PlayerRig.Parent = workspace.Characters

		--// Apply HumanoidDescription asynchronously (can yield + fail -> wrapped in pcall)
		pcall(function()
			local HumanoidDescription = Players:GetHumanoidDescriptionFromUserId(tonumber(OtherPlayer.UserId)) :: HumanoidDescription
			local Humanoid = PlayerRig:WaitForChild("Humanoid", 10) :: Humanoid

			Humanoid:ApplyDescription(HumanoidDescription)
		end)
	end

	local ID = OtherPlayer:GetAttribute("NetID")
	if not ID then return end

	--// Snapshot buffering (time-based, not frame-based -> critical for interpolation accuracy)
	History[ID] = History[ID] or {}
	local PlayerHistory = History[ID]

	table.insert(PlayerHistory, { Time = workspace:GetServerTimeNow(), CFrame = NewCFrame })
	if #PlayerHistory > MaxBufferSize then
		table.remove(PlayerHistory, 1)
	end

	--// Animation system (cached per rig to avoid reloading tracks every frame)
	local Humanoid = PlayerRig:FindFirstChild("Humanoid")
	if not Humanoid then
		return 
	end

	local Animator = Humanoid:FindFirstChildOfClass("Animator")
	if not Animator then
		return 
	end

	local Cache = AnimationCache[PlayerRig]
	if not Cache then
		Cache = {
			Walk = Animator:LoadAnimation(script.Walk),
			Idle = Animator:LoadAnimation(script.Idle)
		}

		Cache.Idle:Play()
		AnimationCache[PlayerRig] = Cache
	end

	--// Movement-based animation switching using positional delta instead of velocity (more reliable over network)
	local MoveDelta = (NewCFrame.Position - PlayerRig:GetPivot().Position).Magnitude
	if MoveDelta > 0.005 then
		if not Cache.Walk.IsPlaying then
			Cache.Idle:Stop(0.2)
			Cache.Walk:Play(0.2)
		end
	else
		if not Cache.Idle.IsPlaying then
			Cache.Walk:Stop(0.2)
			Cache.Idle:Play(0.2)
		end
	end
end

Character.Parent = workspace
Camera.CameraSubject = Character
Camera.CameraType = Enum.CameraType.Custom

--// The Interval can be changed depending on how many times you want it to update per second so for example
 --> 1/60 is 60 times per second, etc
local Interval = 1/60
local Accumulator = 0

--// Core simulation loop (PreRender since RenderStep is technically outdated)
--// Handles:
 --> Movement physics (camera-relative via CFrame basis vectors)
 --> Network replication throttling
 --> Client-side interpolation/extrapolation of other players
RunService.PreRender:Connect(function(DeltaTime)
	MoveDirection = GetMoveDirection()

	if MoveDirection.Magnitude > 0 then
		LastActivity = os.clock()
	end

	--// Idle-based replication gating (bandwidth optimization)
	if IsActive and os.clock() - LastActivity >= IdleThreshold then
		IsActive = false
	elseif not IsActive and (MoveDirection.Magnitude > 0 or IsJumping) then
		IsActive = true
		LastActivity = os.clock()
	end

	--// Camera-relative movement using CFrame vectors (LookVector/RightVector projected to XZ plane)
	if MoveDirection.Magnitude > 0 then
		local Forward = Camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		local Right = Camera.CFrame.RightVector * Vector3.new(1, 0, 1)
		local MoveWorld = (Forward * MoveDirection.Z + Right * MoveDirection.X).Unit * MoveSpeed

		--// AlignOrientation used instead of setting CFrame directly -> physics-friendly rotation
		HorizontalOrientation.CFrame = CFrame.lookAt(Core.WorldPosition, Core.WorldPosition + MoveWorld)

		--// Convert world velocity into local plane space for LinearVelocity constraint
		local LocalMove = HorizontalOrientation.CFrame:VectorToObjectSpace(MoveWorld)
		Controller.PlaneVelocity = Vector2.new(LocalMove.X, -LocalMove.Z)
	else
		Controller.PlaneVelocity = Vector2.zero
	end

	--// Fixed timestep replication (decoupled from FPS -> consistent networking)
	Accumulator += DeltaTime
	if Accumulator >= Interval and IsActive then
		Accumulator -= Interval

		local CurrentCFrame = Character.CFrame or Core.WorldCFrame
		Packets.Replication:Fire(CurrentCFrame)
	end

	--// Interpolation system (client-side lag compensation)
	local Now = workspace:GetServerTimeNow()
	local CutoffTime = Now - BufferTime - 1

	for ID, Frames in History do
		while #Frames > 2 and Frames[1].Time < CutoffTime do
			table.remove(Frames, 1)
		end

		if #Frames < 2 then continue end

		local RenderTime = Now - BufferTime
		local Previous, NextFrame

		--// Find correct interpolation window based on server timestamps
		for Index = 1, #Frames - 1 do
			local A, B = Frames[Index], Frames[Index + 1]
			if RenderTime >= A.Time and RenderTime <= B.Time then
				Previous, NextFrame = A, B
				break
			end
		end

		--// Extrapolation fallback when packets are missing (predict forward using velocity)
		if not NextFrame then
			Previous, NextFrame = Frames[#Frames - 1], Frames[#Frames]
			if not Previous or not NextFrame then continue end

			local DeltaTime = NextFrame.Time - Previous.Time
			local Speed = (NextFrame.CFrame.Position - Previous.CFrame.Position) / math.max(DeltaTime, 1/60)
			local Extrapolated = NextFrame.CFrame + Speed * math.min(Now - NextFrame.Time, 0.1)
			NextFrame = { CFrame = Extrapolated, Time = Now }
		end

		local Alpha = math.clamp((RenderTime - Previous.Time) / (NextFrame.Time - Previous.Time), 0, 1)
		local Interpolation = Previous.CFrame:Lerp(NextFrame.CFrame, Alpha)

		--// Apply smoothing layer (secondary Lerp) to reduce visual jitter
		for _, OtherPlayer in Players:GetPlayers() do
			if OtherPlayer:GetAttribute("NetID") == ID then
				local PlayerRig = workspace.Characters:FindFirstChild(OtherPlayer.DisplayName) or workspace.Characters:FindFirstChild(tostring(OtherPlayer.UserId))

				if PlayerRig then
					PlayerRig:PivotTo(PlayerRig:GetPivot():Lerp(Interpolation, 0.3))
				end

				break
			end
		end
	end
end)

--// Network receive handler
--// Maps incoming NetID -> Player, then feeds snapshot into interpolation system
Packets.Replication.OnClientEvent:Connect(function(NewCFrame: CFrame, NetID: number)
	for _, OtherPlayer in Players:GetPlayers() do
		if OtherPlayer:GetAttribute("NetID") == NetID then
			UpdateCharacter(OtherPlayer, NewCFrame)
			break
		end
	end
end)

--// Cleanup handler
--// Ensures no memory leaks by clearing history buffers and animation caches when players leave
Players.PlayerRemoving:Connect(function(RemovedPlayer)
	local ID = RemovedPlayer:GetAttribute("NetID")
	if ID then
		History[ID] = nil
	end

	local PlayerRig = workspace.Characters:FindFirstChild(RemovedPlayer.DisplayName) or workspace.Characters:FindFirstChild(tostring(RemovedPlayer.UserId))
	if PlayerRig then
		AnimationCache[PlayerRig] = nil
		PlayerRig:Destroy()
	end
end)
