--!nonstrict
--[[
	ReturnByDeathSequence
	Client-only, first-person "Return by Death" style death cutscene.

	API
		ReturnByDeathSequence.Play() -> boolean
			Plays the full 2.5s sequence, yields until it has finished and every
			camera/lighting property has been restored. Returns false immediately
			if a sequence is already running.
		ReturnByDeathSequence.IsPlaying() -> boolean

	Timeline
		0.00 – 0.65  Floor collapse   : Scriptable camera drops 3.5 studs, 26° roll, impact bounce,
		                                black fog (FogEnd -> 10) + cold desaturated ColorCorrection.
		0.65 – 1.85  Shadow void      : client-only black enclosure + 6 articulated shadow arms
		                                (black core / purple Highlight outline) creeping toward the lens.
		1.85 – 2.50  Heart grab & cut : FOV 70 -> 48 snap + shake while one hand lunges into the lens
		                                (1.85 – 2.10), pure black ScreenGui for 0.40s (2.10 – 2.50),
		                                then everything is destroyed and restored.

	No input bindings live in here — call .Play() from your own LocalScript.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local ReturnByDeathSequence = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
local T_IMPACT = 0.42 -- moment the camera hits the floor
local T_COLLAPSE_END = 0.65
local T_GRAB_START = 1.85
local T_BLACK_START = 2.10 -- black frame holds for 0.40s
local T_END = 2.50

local DROP_STUDS = 3.5
local ROLL_ANGLE = math.rad(26)
local FOV_NORMAL = 70
local FOV_GRAB = 48
local FOV_SNAP_TIME = 0.07
local FOG_END = 10

local ARM_COUNT = 6
local ARM_SEGMENTS = 5
local LUNGE_ARM = 1 -- arm 1 comes from the bottom of the screen
local VOID_HALF_SIZE = 6
local VOID_WALL_THICKNESS = 0.5

local BLACK = Color3.new(0, 0, 0)
local OUTLINE_COLOR = Color3.fromRGB(145, 45, 255)
local COLD_TINT = Color3.fromRGB(170, 190, 255)

local PALM_SIZE = Vector3.new(0.56, 0.12, 0.5)
local FINGER_WIDTH = 0.085
local FINGERS = {
	-- x = offset along palm width, spread = yaw at the knuckle, lens = phalange lengths
	{ x = -0.21, spread = 0.30, lens = { 0.30, 0.24, 0.19 } },
	{ x = -0.07, spread = 0.10, lens = { 0.34, 0.27, 0.21 } },
	{ x = 0.07, spread = -0.08, lens = { 0.33, 0.26, 0.20 } },
	{ x = 0.21, spread = -0.28, lens = { 0.27, 0.21, 0.17 } },
}
local THUMB = { x = 0.30, z = 0.06, spread = -1.0, lens = { 0.22, 0.18 } }

local isPlaying = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function clamp01(x)
	return math.clamp(x, 0, 1)
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function easeOutQuad(x)
	return 1 - (1 - x) * (1 - x)
end

local function easeOutQuint(x)
	return 1 - (1 - x) ^ 5
end

local function easeInOutSine(x)
	return -(math.cos(math.pi * x) - 1) / 2
end

local function quadBezier(a, b, c, u)
	local iu = 1 - u
	return a * (iu * iu) + b * (2 * iu * u) + c * (u * u)
end

local function capture(inst, props)
	local snap = {}
	for _, prop in props do
		snap[prop] = inst[prop]
	end
	return snap
end

local function restore(inst, snap)
	for prop, value in snap do
		pcall(function()
			inst[prop] = value
		end)
	end
end

-- CFrame at `from` looking at `to`, with a safe up vector
local function aim(from, to, upHint)
	local dir = to - from
	dir = dir.Magnitude > 1e-4 and dir.Unit or -Vector3.zAxis
	local up = upHint
	if math.abs(dir:Dot(up)) > 0.98 then
		up = math.abs(dir:Dot(Vector3.yAxis)) > 0.98 and Vector3.xAxis or Vector3.yAxis
	end
	return CFrame.lookAt(from, from + dir, up)
end

-- Point on an ellipse that matches the view frustum at `depth` studs in front of the lens.
-- factor 1 = exactly on the screen edge, >1 = off screen, <1 = inside the frame.
local function edgePoint(angle, depth, factor, tanHalf, aspect)
	local halfH = depth * tanHalf
	return Vector3.new(math.cos(angle) * halfH * aspect * factor, math.sin(angle) * halfH * factor, -depth)
end

local function newPart(parent, size, shape)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = BLACK
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.Parent = parent
	return part
end

local function getEyeCFrame(camera, player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return camera.CFrame
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		local up = camera.CFrame.UpVector
		flat = Vector3.new(up.X, 0, up.Z)
	end
	if flat.Magnitude < 1e-3 then
		flat = -Vector3.zAxis
	end
	local eye = head.Position + Vector3.new(0, 0.25, 0)
	return CFrame.lookAt(eye, eye + flat.Unit)
end

---------------------------------------------------------------------------
-- Builders
---------------------------------------------------------------------------
-- Hollow box made of 6 slabs (a single part would be back-face culled from inside)
local function buildEnclosure(parent, center)
	local model = Instance.new("Model")
	model.Name = "ShadowVoid"
	local h, t = VOID_HALF_SIZE, VOID_WALL_THICKNESS
	local s = (h + t) * 2
	local walls = {
		{ Vector3.new(h + t / 2, 0, 0), Vector3.new(t, s, s) },
		{ Vector3.new(-h - t / 2, 0, 0), Vector3.new(t, s, s) },
		{ Vector3.new(0, h + t / 2, 0), Vector3.new(s, t, s) },
		{ Vector3.new(0, -h - t / 2, 0), Vector3.new(s, t, s) },
		{ Vector3.new(0, 0, h + t / 2), Vector3.new(s, s, t) },
		{ Vector3.new(0, 0, -h - t / 2), Vector3.new(s, s, t) },
	}
	for _, wall in walls do
		newPart(model, wall[2]).CFrame = CFrame.new(center + wall[1])
	end
	model.Parent = parent
	return model
end

local function buildArm(parent, index, rng)
	local model = Instance.new("Model")
	model.Name = "ShadowArm" .. index

	local jitter = index == LUNGE_ARM and 0 or (rng:NextNumber() - 0.5) * 0.35
	local arm = {
		model = model,
		angle = -math.pi / 2 + (index - 1) * (2 * math.pi / ARM_COUNT) + jitter,
		phase = rng:NextNumber() * math.pi * 2,
		speed = rng:NextNumber(1.6, 2.6),
		reach = rng:NextNumber(0.9, 1.1),
		points = {},
		segments = {},
		joints = {},
		fingers = {},
		thumb = {},
	}

	for k = 1, ARM_SEGMENTS do
		local w = lerp(0.34, 0.17, (k - 1) / (ARM_SEGMENTS - 1))
		arm.segments[k] = { part = newPart(model, Vector3.new(w, w * 0.85, 1)), w = w }
		if k < ARM_SEGMENTS then
			arm.joints[k] = newPart(model, Vector3.one * w * 1.12, Enum.PartType.Ball)
		end
	end

	arm.palm = newPart(model, PALM_SIZE)

	local function buildDigit(lens)
		local digit = {}
		for m, len in ipairs(lens) do
			local w = FINGER_WIDTH * (1 - (m - 1) * 0.15)
			digit[m] = { part = newPart(model, Vector3.new(w, w, len + w * 0.5)), len = len }
		end
		return digit
	end
	for j, def in ipairs(FINGERS) do
		arm.fingers[j] = buildDigit(def.lens)
	end
	arm.thumb = buildDigit(THUMB.lens)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = BLACK
	highlight.FillTransparency = 0
	highlight.OutlineColor = OUTLINE_COLOR
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model

	model.Parent = parent
	return arm
end

---------------------------------------------------------------------------
-- Arm posing (all math in camera space, then multiplied by the camera CFrame)
---------------------------------------------------------------------------
local function poseDigit(digit, rootCF, curl, parts, cframes, viewCF)
	local cf = rootCF
	for m, phal in ipairs(digit) do
		cf = cf * CFrame.Angles(curl * (m == 1 and 0.7 or 1.15), 0, 0)
		parts[#parts + 1] = phal.part
		cframes[#cframes + 1] = viewCF * cf * CFrame.new(0, 0, -phal.len * 0.5)
		cf = cf * CFrame.new(0, 0, -phal.len)
	end
end

local function poseArm(arm, t, tanHalf, aspect, creep, lunge, parts, cframes, viewCF)
	local sway = t * arm.speed + arm.phase

	local function push(part, localCF)
		parts[#parts + 1] = part
		cframes[#cframes + 1] = viewCF * localCF
	end

	-- Shoulder anchored just outside the frame; the hand creeps from the edge toward the lens
	local base = edgePoint(arm.angle + 0.05 * math.sin(sway * 0.6), 2.3, 1.4, tanHalf, aspect)
	local tipFactor = lerp(1.2, 0.42, creep) * arm.reach + 0.05 * math.sin(sway * 1.3)
	local tip = edgePoint(arm.angle + 0.12 * math.sin(sway), lerp(2.0, 1.3, creep), tipFactor, tanHalf, aspect)

	if lunge > 0 then
		local l = easeOutQuint(math.min(lunge / 0.6, 1))
		base = base:Lerp(Vector3.new(base.X * 0.4, base.Y * 0.55, -1.6), l)
		tip = tip:Lerp(Vector3.new(0, 0, -0.32), l)
	end

	local radial = Vector3.new(base.X, base.Y, 0)
	radial = radial.Magnitude > 1e-3 and radial.Unit or -Vector3.yAxis
	local perp = radial:Cross(Vector3.zAxis)

	-- Elbow bulges outward and breathes
	local ctrl = (base + tip) * 0.5
		+ radial * (0.35 + 0.12 * math.sin(sway * 1.7))
		+ Vector3.new(0, 0, 0.15 * math.sin(sway * 0.9))

	local n = ARM_SEGMENTS
	local pts = arm.points
	for k = 0, n do
		local bend = (k * (n - k)) / (n * n * 0.25) -- 0 at both ends, 1 mid-arm
		pts[k] = quadBezier(base, ctrl, tip, k / n) + perp * (0.08 * math.sin(sway * 2.3 + k * 1.1) * bend)
	end

	for k = 1, n do
		local seg = arm.segments[k]
		local a, b = pts[k - 1], pts[k]
		local len = (b - a).Magnitude
		seg.part.Size = Vector3.new(seg.w, seg.w * 0.85, len + seg.w * 0.4)
		push(seg.part, aim(a, b, Vector3.zAxis) * CFrame.new(0, 0, -len * 0.5))
		if k < n then
			push(arm.joints[k], CFrame.new(b))
		end
	end

	-- Palm faces the lens where possible
	local wrist = pts[n]
	local dir = (pts[n] - pts[n - 1]).Unit
	local up = Vector3.zAxis - dir * dir:Dot(Vector3.zAxis)
	if up.Magnitude < 0.15 then
		up = radial
	end
	local palmCF = CFrame.lookAt(wrist, wrist + dir, up.Unit) * CFrame.new(0, 0, -PALM_SIZE.Z * 0.5)
	push(arm.palm, palmCF)

	-- Lunging hand: fingers splay wide open, then clench shut (the grab)
	local curl, spreadMul
	if lunge > 0 then
		if lunge < 0.5 then
			local s = lunge / 0.5
			curl, spreadMul = lerp(0.3, -0.3, s), lerp(1, 1.8, s)
		else
			local s = easeOutQuad((lunge - 0.5) / 0.5)
			curl, spreadMul = lerp(-0.3, 1.2, s), lerp(1.8, 0.5, s)
		end
	end

	for j, def in ipairs(FINGERS) do
		local c = curl or (0.35 + 0.22 * math.sin(sway * 2.1 + j * 0.8))
		local sm = spreadMul or (1 + 0.15 * math.sin(sway * 1.4 + j))
		local root = palmCF * CFrame.new(def.x, 0, -PALM_SIZE.Z * 0.5) * CFrame.Angles(0, def.spread * sm, 0)
		poseDigit(arm.fingers[j], root, c, parts, cframes, viewCF)
	end

	local thumbCurl = (curl or (0.3 + 0.15 * math.sin(sway * 1.8))) * 0.6
	local thumbRoot = palmCF * CFrame.new(THUMB.x, 0, THUMB.z) * CFrame.Angles(0, THUMB.spread * (spreadMul or 1), 0)
	poseDigit(arm.thumb, thumbRoot, thumbCurl, parts, cframes, viewCF)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function ReturnByDeathSequence.IsPlaying()
	return isPlaying
end

function ReturnByDeathSequence.Play()
	assert(RunService:IsClient(), "ReturnByDeathSequence.Play() must be called from a LocalScript")
	if isPlaying then
		return false
	end
	local camera = workspace.CurrentCamera
	local player = Players.LocalPlayer
	if not camera or not player then
		return false
	end
	isPlaying = true

	local rng = Random.new()
	local seed = rng:NextNumber(0, 1000)

	-- Snapshots of everything we touch
	local camSnap = capture(camera, { "CameraType", "CameraSubject", "CFrame", "FieldOfView" })
	local lightSnap = capture(Lighting, { "FogStart", "FogEnd", "FogColor" })
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") -- Atmosphere overrides classic fog
	local atmoSnap = atmosphere and capture(atmosphere, { "Density", "Offset", "Color", "Decay", "Glare", "Haze" })
	local ltmSnap = {}
	if player.Character then
		for _, d in player.Character:GetDescendants() do
			if d:IsA("BasePart") then
				ltmSnap[d] = d.LocalTransparencyModifier
			end
		end
	end

	local startCF = getEyeCFrame(camera, player)
	local startPos, startRot = startCF.Position, startCF.Rotation

	-- Temporary instances
	local folder = Instance.new("Folder")
	folder.Name = "ReturnByDeath_Local"
	folder.Parent = workspace

	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "ReturnByDeath_Grade"
	grade.Parent = Lighting

	local gui = Instance.new("ScreenGui")
	gui.Name = "ReturnByDeath_Black"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 10000
	gui.Enabled = false
	local blackFrame = Instance.new("Frame")
	blackFrame.Size = UDim2.fromScale(1, 1)
	blackFrame.BackgroundColor3 = BLACK
	blackFrame.BorderSizePixel = 0
	blackFrame.Parent = gui
	gui.Parent = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 2)

	-- Phase 1 lighting tweens
	local tweens = {}
	local function tween(inst, info, goal)
		local tw = TweenService:Create(inst, info, goal)
		tw:Play()
		table.insert(tweens, tw)
	end
	local collapseInfo = TweenInfo.new(T_COLLAPSE_END, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tween(Lighting, collapseInfo, { FogStart = 0, FogEnd = FOG_END, FogColor = BLACK })
	if atmosphere then
		tween(atmosphere, collapseInfo, { Density = 0.6, Offset = 0, Color = BLACK, Decay = BLACK, Glare = 0, Haze = 0 })
	end
	tween(grade, collapseInfo, { Saturation = -1, Contrast = 0.25, Brightness = -0.12, TintColor = COLD_TINT })

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = FOV_NORMAL
	camera.CFrame = startCF

	local arms = nil
	local parts, cframes = {}, {}
	local t = 0
	local cleaned = false
	local conn
	local finished = Instance.new("BindableEvent")

	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		if conn then
			conn:Disconnect()
		end
		for _, tw in tweens do
			tw:Cancel()
		end
		folder:Destroy()
		grade:Destroy()
		gui:Destroy()

		restore(Lighting, lightSnap)
		if atmosphere and atmoSnap then
			restore(atmosphere, atmoSnap)
		end
		for part, value in ltmSnap do
			if part.Parent then
				part.LocalTransparencyModifier = value
			end
		end

		-- Camera: if the character respawned mid-sequence, follow the new Humanoid
		local subject = camSnap.CameraSubject
		if subject and not subject:IsDescendantOf(game) then
			subject = nil
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and (subject == nil or subject:IsA("Humanoid")) then
			subject = humanoid
		end
		camera.FieldOfView = camSnap.FieldOfView
		camera.CameraType = camSnap.CameraType
		camera.CameraSubject = subject
		camera.CFrame = camSnap.CFrame

		isPlaying = false
	end

	local function step(dt)
		t += dt

		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		for part in ltmSnap do
			part.LocalTransparencyModifier = 1 -- hide own body in first person
		end

		-- Phase 1: collapse (accelerating drop + roll, then impact bounce that settles)
		local yOff, roll, pitch
		if t < T_IMPACT then
			local a = t / T_IMPACT
			yOff = -DROP_STUDS * a * a
			roll = ROLL_ANGLE * easeOutQuad(a)
			pitch = 0
		else
			local s = t - T_IMPACT
			local decay = math.exp(-s * 9)
			yOff = -DROP_STUDS + 0.45 * math.abs(math.sin(s * 20)) * decay
			roll = ROLL_ANGLE + math.rad(4) * math.sin(s * 26) * decay
			local x = s * 14
			pitch = -math.rad(7) * x * math.exp(1 - x) -- head-jolt kick
		end
		local camLocal = CFrame.Angles(pitch, 0, 0) * CFrame.Angles(0, 0, roll)

		-- Phase 2+: dread tremble that grows as the hands approach
		local creepLinear = clamp01((t - T_COLLAPSE_END) / (T_GRAB_START - T_COLLAPSE_END))
		if t >= T_COLLAPSE_END then
			local amp = lerp(0.004, 0.025, creepLinear) * 2
			camLocal = camLocal
				* CFrame.new(
					math.noise(t * 6, seed, 0.5) * amp,
					math.noise(t * 6, seed, 1.5) * amp + 0.03 * math.sin(t * 3),
					0
				)
				* CFrame.Angles(0, 0, math.rad(0.6) * math.sin(t * 1.7))
		end
		local viewCF = CFrame.new(startPos + Vector3.new(0, yOff, 0)) * startRot * camLocal

		-- Phase 3: FOV snap + violent shake
		local fov = FOV_NORMAL
		local shakeCF = CFrame.identity
		local grab = 0
		if t >= T_GRAB_START then
			grab = clamp01((t - T_GRAB_START) / (T_BLACK_START - T_GRAB_START))
			fov = lerp(FOV_NORMAL, FOV_GRAB, easeOutQuad(clamp01((t - T_GRAB_START) / FOV_SNAP_TIME)))
			local amp = (1 - 0.4 * grab) * 2
			local f = t * 32
			shakeCF = CFrame.new(math.noise(f, seed, 1.1) * 0.14 * amp, math.noise(f, seed, 2.3) * 0.14 * amp, 0)
				* CFrame.Angles(
					math.noise(f, seed, 3.7) * math.rad(2.5) * amp,
					math.noise(f, seed, 4.9) * math.rad(2.5) * amp,
					math.noise(f, seed, 6.1) * math.rad(3.5) * amp
				)
		end
		camera.FieldOfView = fov
		camera.CFrame = viewCF * shakeCF

		-- Phase 2 start: spawn the void and the arms
		if t >= T_COLLAPSE_END and not arms then
			buildEnclosure(folder, viewCF.Position)
			arms = {}
			for i = 1, ARM_COUNT do
				arms[i] = buildArm(folder, i, rng)
			end
		end

		-- Arms follow the un-shaken view so the shake reads against them
		if arms and t < T_BLACK_START then
			local creep = easeInOutSine(creepLinear)
			local tanHalf = math.tan(math.rad(fov) * 0.5)
			local viewport = camera.ViewportSize
			local aspect = viewport.Y > 0 and viewport.X / viewport.Y or 16 / 9
			table.clear(parts)
			table.clear(cframes)
			for i, arm in arms do
				poseArm(arm, t, tanHalf, aspect, creep, i == LUNGE_ARM and grab or 0, parts, cframes, viewCF)
			end
			workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end

		-- Hard cut to black for the last 0.40s
		if t >= T_BLACK_START and not gui.Enabled then
			gui.Enabled = true
		end
	end

	conn = RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[ReturnByDeathSequence] " .. tostring(err))
		end
		if not ok or t >= T_END then
			cleanup()
			finished:Fire()
		end
	end)

	finished.Event:Wait()
	finished:Destroy()
	return true
end

return ReturnByDeathSequence
