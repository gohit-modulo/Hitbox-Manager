local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = workspace

local hitboxManager = {}
hitboxManager.__index = hitboxManager

-- Module-level global hit records to prevent duplicate hits across concurrent hitboxes
local globalHitRecords = {}

-- Utility: current time (seconds)
local function now()
	return tick()
end

-- Initialize module-level settings (optional)
function hitboxManager.Init(options)
	options = options or {}
	hitboxManager._config = {
		Debug = options.Debug == true,
		DebugParent = options.DebugParent or Workspace
	}
	if hitboxManager._config.Debug then
		print("[HitboxManager] Debug mode enabled. Visual hitbox parts will be created.")
	else
		print("[HitboxManager] Initialized.")
	end
end

-- Helper: safe GetPartBoundsInBox wrapper (uses modern API when available)
local function getPartsInBox(cframe, size, params)
	-- params may include: IgnoreList (table of Instances), FilterType ("Blacklist" or "Whitelist")
	params = params or {}
	if Workspace.GetPartBoundsInBox then
		-- Use the efficient native call with an OverlapParams object
		local overlapParams = OverlapParams.new()
		if params.IgnoreList and type(params.IgnoreList) == "table" and #params.IgnoreList > 0 then
			overlapParams.FilterDescendantsInstances = params.IgnoreList
			overlapParams.FilterType = Enum.RaycastFilterType.Blacklist
		else
			if params.FilterType == "Whitelist" then
				overlapParams.FilterType = Enum.RaycastFilterType.Whitelist
			else
				overlapParams.FilterType = Enum.RaycastFilterType.Blacklist
			end
		end
		local parts = Workspace:GetPartBoundsInBox(cframe, size, overlapParams)
		return parts
	else
		-- Fallback: use Region3 (less precise & deprecated in many places)
		local half = size * 0.5
		local min = (cframe.Position - half)
		local max = (cframe.Position + half)
		local region = Region3.new(min, max)
		region = region:ExpandToGrid(4)
		local ignoreList = params.IgnoreList or {}
		local parts = Workspace:FindPartsInRegion3WithIgnoreList(region, ignoreList, 100)
		return parts
	end
end

-- Helper: determine if a part belongs to a player character and return the player (or nil)
local function playerFromPart(part)
	if not part then return nil end
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then return nil end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	local player = Players:GetPlayerFromCharacter(model)
	return player, model
end

-- Helper: create debug part representing the hitbox (server only)
local function createDebugPart(cframe, size, duration, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.CFrame = cframe
	p.Transparency = 0.5
	p.Name = "_HitboxDebug"
	p.Parent = parent or hitboxManager._config.DebugParent or Workspace
	-- Auto-clean after duration
	spawn(function()
		wait(duration or 0.2)
		if p and p.Parent then p:Destroy() end
	end)
	return p
end

-- Internal helper: try to resolve a Model -> best BasePart to use for CFrame
local function resolveModelBasePart(model)
	if not model then return nil end
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	-- prefer HumanoidRootPart if available
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then return hrp end
	-- fallback: any BasePart in model
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") then return child end
	end
	return nil
end

-- Creates a single hitbox controller object
-- params table fields (common):
--  centerCFrame (CFrame) OR targetPart (BasePart) OR targetPlayer (Player) OR cframeGetter (function -> CFrame)
--  Follow (Instance) optional: Player | Model | BasePart to follow (preferred over targetPart/targetPlayer if provided)
--  FollowOffset (CFrame) optional offset applied to Follow's CFrame
--  offset (CFrame) optional offset from target (legacy)
--  size (Vector3) required (box extents)
--  duration (seconds) how long the hitbox exists
--  interval (seconds) how often to sample the area (0 = every frame)
--  Track (boolean) if true, follow targetPart / targetPlayer every sample (deprecated if Follow used)
--  Moving (table) optional: {Direction = Vector3, Speed = number, TrackTarget = boolean} - moves continuously while alive
--  HitMultipleTargets (boolean) default false
--  HitMultipleTime (seconds) per-target cooldown; default 0 (can be used to prevent repeats)
--  UseGlobalCooldown (boolean) if true, register hits in globalHitRecords to prevent other hitboxes hitting the same target in the same window
--  TargetFilter (string or function) - "Players" (only player characters), "All" (any part), or custom function(part)->boolean
--  OnlyIfPlayer (boolean) - if true, OnHit will be invoked only when a player was hit (parts that are not players are ignored)
--  OnHit(part, player, hitboxController) - callback invoked when a hit is registered
--  Debug (boolean) override module debug for this hitbox
--  AllowExternalPositioning (boolean) if true, the returned controller exposes SetCFrame(newCFrame) so other scripts can move the hitbox each frame
-- Returns: controller with methods Stop(), SetCFrame(newCFrame) (if enabled)
function hitboxManager.CreateHitbox(params)
	assert(params and params.size, "CreateHitbox requires a size Vector3 in params.size")

	local controller = {}
	controller._startTime = now()
	controller._params = params
	controller._stopped = false
	controller._hitTimestamps = {} -- per-target last hit time

	-- resolve config values
	local size = params.size
	local duration = params.duration or 0.2
	local interval = nil
	if params.interval == 0 then
		interval = 0
	else
		interval = params.interval or (params.Track and 0 or 0.05) -- default 50ms when not tracking
	end
	local track = params.Track == true
	local hitMultipleTargets = params.HitMultipleTargets == true
	local hitMultipleTime = tonumber(params.HitMultipleTime) or 0
	local useGlobalCooldown = params.UseGlobalCooldown == true
	local targetFilter = params.TargetFilter or "Players"
	local onHit = params.OnHit or function() end
	local debug = params.Debug or hitboxManager._config.Debug
	local allowExternal = params.AllowExternalPositioning == true
	local onlyIfPlayer = params.OnlyIfPlayer == true -- NEW OPTION

	-- cframe getter: determine how to get current center
	local cframeGetter

	-- PRIORITY:
	-- 1) explicit cframeGetter function
	-- 2) Follow (Player | Model | BasePart) + FollowOffset
	-- 3) centerCFrame literal
	if params.cframeGetter and type(params.cframeGetter) == "function" then
		cframeGetter = params.cframeGetter

	elseif params.Follow then
		-- Follow can be Player, Model, or BasePart
		local followInst = params.Follow
		local offset = params.FollowOffset or params.offset or CFrame.new()
		if typeof(followInst) == "Instance" then
			-- Player
			if followInst:IsA("Player") then
				cframeGetter = function()
					local char = followInst.Character
					if char and char.Parent then
						local hrp = char:FindFirstChild("HumanoidRootPart")
						if hrp then return hrp.CFrame * offset end
						-- fallback to model base part
						local base = resolveModelBasePart(char)
						if base then return base.CFrame * offset end
					end
					return nil
				end

				-- Model
			elseif followInst:IsA("Model") then
				cframeGetter = function()
					local base = resolveModelBasePart(followInst)
					if base and base.Parent then
						return base.CFrame * offset
					end
					return nil
				end

				-- BasePart
			elseif followInst:IsA("BasePart") then
				cframeGetter = function()
					if followInst and followInst.Parent then
						return followInst.CFrame * offset
					end
					return nil
				end

			else
				error("Follow must be a Player, Model, or BasePart instance")
			end
		else
			error("Follow must be an Instance")
		end

	elseif params.centerCFrame and typeof(params.centerCFrame) == "CFrame" then
		local c = params.centerCFrame
		cframeGetter = function()
			return c
		end
	else
		error("CreateHitbox requires centerCFrame, Follow, or cframeGetter")
	end

	-- moving configuration
	local moving = params.Moving
	local moveStart = nil
	controller._moveDir = nil
	controller._moveSpeed = nil
	controller._externalCFrame = nil

	if moving then
		moveStart = cframeGetter()
		controller._moveStart = moveStart
		controller._moveDir = (moving.Direction and moving.Direction.Magnitude > 0) and moving.Direction.Unit or Vector3.new(0,0,-1)
		controller._moveSpeed = moving.Speed or 20
		-- TrackTarget default to true for moving hitboxes (follows target's base CFrame if present)
		controller._moveTrackTarget = moving.TrackTarget == nil and true or (moving.TrackTarget == true)
	end

	-- allow external positioning
	if allowExternal then
		function controller.SetCFrame(newCFrame)
			controller._externalCFrame = newCFrame
		end
	end

	-- internal sample function
	local function sample(currentCFrame, elapsed)
		if not currentCFrame and not controller._externalCFrame then return end

		-- if external frame provided, use it
		if controller._externalCFrame then
			currentCFrame = controller._externalCFrame
		end

		-- apply movement offset if moving
		if moving and controller._moveDir then
			local travelled = elapsed * controller._moveSpeed -- continuous movement until duration
			-- If TrackTarget is true, apply movement relative to current base cframe so it follows the target
			if controller._moveTrackTarget and cframeGetter then
				local base = cframeGetter()
				if base then
					currentCFrame = base * CFrame.new(controller._moveDir * travelled)
				end
			else
				-- use moveStart as the origin so it continues along the set direction
				if controller._moveStart then
					currentCFrame = controller._moveStart * CFrame.new(controller._moveDir * travelled)
				end
			end
		end

		-- debug part
		if debug then
			createDebugPart(currentCFrame, size, math.min(1, duration), hitboxManager._config.DebugParent)
		end

		-- find parts
		local parts = getPartsInBox(currentCFrame, size, {IgnoreList = params.IgnoreList or {}})
		for _, part in ipairs(parts) do
			-- filter
			local accept = false
			local player, character = playerFromPart(part)
			if typeof(targetFilter) == "function" then
				accept = targetFilter(part)
			elseif targetFilter == "Players" then
				accept = player ~= nil
			elseif targetFilter == "All" then
				accept = true
			else
				accept = true
			end

			-- NEW: OnlyIfPlayer option enforces that we only consider hits that are players
			if onlyIfPlayer and not player then
				accept = false
			end

			if accept then
				-- determine unique key for target (prefer player, else instance)
				local key = nil
				if player then key = player end
				if not key then key = part end

				local last = controller._hitTimestamps[key] or 0
				local gLast = globalHitRecords[key] or 0
				local nowTime = now()
				local canHitLocal = (hitMultipleTime <= 0) or (nowTime - last >= hitMultipleTime)
				local canHitGlobal = (not useGlobalCooldown) or (hitMultipleTime <= 0) or (nowTime - gLast >= hitMultipleTime)

				if canHitLocal and canHitGlobal then
					-- register hit
					controller._hitTimestamps[key] = nowTime
					if useGlobalCooldown then globalHitRecords[key] = nowTime end

					-- invoke callback
					local success, err = pcall(onHit, part, player, controller)
					if not success then
						warn("[HitboxManager] OnHit callback error:", err)
					end

					if not hitMultipleTargets then
						return true -- stop sampling after first hit
					end
				end
			end
		end

		return false
	end

	-- run loop
	local lastSample = 0
	local elapsed = 0
	local stopped = false
	local conn
	local startTime = now()

	local function stop()
		if stopped then return end
		stopped = true
		controller._stopped = true
		if conn then conn:Disconnect() end
	end

	controller.Stop = stop

	if interval == 0 then
		-- sample every frame
		conn = RunService.Heartbeat:Connect(function(dt)
			if stopped then return end
			elapsed = now() - startTime
			if elapsed >= duration then
				stop()
				return
			end
			local cframe = cframeGetter()
			local hit = sample(cframe, elapsed)
			if hit and not hitMultipleTargets then
				stop()
				return
			end
		end)
	else
		-- sample at given interval
		conn = RunService.Heartbeat:Connect(function(dt)
			if stopped then return end
			elapsed = now() - startTime
			if elapsed >= duration then
				stop()
				return
			end
			lastSample = lastSample + dt
			if lastSample >= interval then
				lastSample = 0
				local cframe = cframeGetter()
				local hit = sample(cframe, elapsed)
				if hit and not hitMultipleTargets then
					stop()
					return
				end
			end
		end)
	end

	return controller
end

-- Utility to clear expired entries from globalHitRecords (keeps memory small)
-- call periodically if you enable global cooldowns heavily
function hitboxManager.CleanupGlobalHits(maxAge)
	maxAge = maxAge or 5
	local t = now()
	for k, v in pairs(globalHitRecords) do
		if t - v > maxAge then
			globalHitRecords[k] = nil
		end
	end
end

-- Example helper for melee attack usage (returns controller)
function hitboxManager.MeleeSwing(options)
	local player = options.player
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then error("MeleeSwing requires a player's character with HumanoidRootPart") end

	local size = Vector3.new(options.width or 3, options.height or 3, options.range or 4)
	local forwardOffset = (options.range or 4) / 2
	local params = {
		Follow = hrp,
		FollowOffset = CFrame.new(0, 0, -forwardOffset),
		size = size,
		duration = options.duration or 0.2,
		interval = options.Track and 0 or (options.interval or 0.03),
		Track = options.Track,
		HitMultipleTargets = options.HitMultipleTargets,
		HitMultipleTime = options.HitMultipleTime,
		UseGlobalCooldown = options.UseGlobalCooldown,
		TargetFilter = options.TargetFilter or "Players",
		OnHit = options.OnHit,
		Debug = options.Debug,
		AllowExternalPositioning = options.AllowExternalPositioning,
		OnlyIfPlayer = options.OnlyIfPlayer
	}
	return hitboxManager.CreateHitbox(params)
end

-- Expose module
return hitboxManager
