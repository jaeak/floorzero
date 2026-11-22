--!nonstrict
--[[
	IntroCutscene  (ReplicatedStorage.IntroCutscene)

	Join cutscene + title menu. Everything is built with Instance.new(); no uploaded assets needed.

	IntroCutscene.Play() -> boolean
		Dark pawn-shop floor POV -> a tall figure walks up and speaks -> you pass out ->
		title menu -> [ BEGIN ]. Yields until the player has control again.
		Returns false if it is already running. Safe to call again any time while testing.

	IntroCutscene.IsPlaying() -> boolean

	Audio:    fill in SOUNDS below with your asset ids. Any id left at 0 is skipped.
	Spawning: if ReplicatedStorage has a RemoteFunction named CONFIG.SpawnRemoteName
	          (created by ServerScriptService > Server > IntroSpawn), BEGIN asks the server to
	          spawn the character. Without it, BEGIN hands control back to the existing character.
	Lighting: set Lighting.Technology = Future in Studio for the long lantern/moonlight shadows.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HapticService = game:GetService("HapticService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IntroCutscene = {}

---------------------------------------------------------------------------
-- CONFIG — edit freely
---------------------------------------------------------------------------
local CONFIG = {
	GameTitle = "FLOOR ZERO",
	Subtitle = "A SECOND CHANCE",
	LogoImage = "", -- e.g. "rbxassetid://1234567" to swap the text logo for an image
	VersionText = "v0.1",
	SpawnRemoteName = "IntroSpawnRequest",
	RoomOrigin = Vector3.new(0, 4000, 0), -- far away from your map
	CameraRoll = 28, -- degrees
	FovMin = 56,
	FovMax = 70,
	TypeSpeed = 36, -- characters per second
}

local SOUNDS = {
	Ambience = 0, -- looped low room tone / wood creaks
	Breath = 0, -- looped ragged breathing
	Heartbeat = 0, -- one soft heartbeat thump (played twice per beat: lub-dub)
	Footstep = 0, -- one wooden footstep (echo is added automatically)
	Chuckle = 0, -- soft low chuckle
	Typewriter = 0, -- very short UI tick
	PassOut = 0, -- low thud / ear ringing
	MenuMusic = 0, -- looped title theme
	Hover = 0, -- button hover
	Click = 0, -- button click
}

local INTRO_NARRATION = { speaker = "", text = "You hear faint footsteps... slowly stepping toward you.", italic = true }
local DIALOGUE = {
	{ speaker = "???", text = "It seems that this life wasn't well-suited for you." },
	{ speaker = "???", text = "What if I told you I could give you another chance?" },
	{ speaker = "You", text = "...ngh...", murmur = true },
	{ speaker = "", text = "You struggle to speak, but only a broken breath escapes your lips...", italic = true },
	{ speaker = "???", text = "[Chuckles softly]" },
}

---------------------------------------------------------------------------
-- Scene layout (studs, relative to CONFIG.RoomOrigin; floor top is y = 0)
---------------------------------------------------------------------------
local HW, HL, ROOM_H = 11, 18, 12 -- half width (x), half length (z), height
local DOOR_MIN_X, DOOR_MAX_X, DOOR_H = -3.8, 1.0, 8.5
local DOOR_X = (DOOR_MIN_X + DOOR_MAX_X) / 2
local CORRIDOR_END_Z = -32
local CRACK_PLANK_Z = -4.2
local CRACK_Z = CRACK_PLANK_Z - 0.6 + 0.225
local CAM_LOCAL = Vector3.new(2.5, 0.55, 12)
local FIGURE_START = Vector3.new(DOOR_X, 0, -29)
local FIGURE_STOP = Vector3.new(1.2, 0, 1.5)
local FIGURE_SPEED = 3.6
local FIGURE_STEP_TIME = 0.78
local FIGURE_HIP = 4.3
local FIGURE_LEG = 4.3

local BLACK = Color3.new(0, 0, 0)
local WOOD = {
	Color3.fromRGB(82, 60, 43),
	Color3.fromRGB(70, 52, 38),
	Color3.fromRGB(92, 68, 49),
	Color3.fromRGB(62, 46, 34),
	Color3.fromRGB(78, 58, 43),
}

local CUTSCENE_LIGHTING = {
	Ambient = Color3.fromRGB(34, 38, 48),
	OutdoorAmbient = Color3.fromRGB(22, 27, 38),
	Brightness = 0.1,
	ClockTime = 0,
	FogStart = 8,
	FogEnd = 78,
	FogColor = Color3.fromRGB(30, 34, 40),
	ExposureCompensation = 0.22,
	EnvironmentDiffuseScale = 0.05,
	EnvironmentSpecularScale = 0,
	GlobalShadows = true,
	ColorShift_Top = BLACK,
	ColorShift_Bottom = BLACK,
}
local LIGHT_PROPS = {}
for prop in CUTSCENE_LIGHTING do
	table.insert(LIGHT_PROPS, prop)
end

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

local function smoothstep(x)
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

local function new(className, props)
	local inst = Instance.new(className)
	local parent
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function tween(inst, info, goal)
	local tw = TweenService:Create(inst, info, goal)
	tw:Play()
	return tw
end

local function corner(parent, radius)
	return new("UICorner", { CornerRadius = radius or UDim.new(0, 6), Parent = parent })
end

local function makeScreenGui(playerGui, name, order, safeInsets)
	return new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		ScreenInsets = safeInsets and Enum.ScreenInsets.CoreUISafeInsets or Enum.ScreenInsets.None,
		DisplayOrder = order,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
end

local function gradientFrame(parent, props, rotation, transparency)
	props.BackgroundColor3 = props.BackgroundColor3 or BLACK
	props.BorderSizePixel = 0
	props.Parent = parent
	local frame = new("Frame", props)
	new("UIGradient", { Rotation = rotation, Transparency = transparency, Parent = frame })
	return frame
end

local function makeSound(key, props, parent)
	local id = SOUNDS[key]
	if not id or id == 0 or id == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = "Intro_" .. key
	sound.SoundId = type(id) == "number" and ("rbxassetid://" .. id) or id
	for k, v in props or {} do
		sound[k] = v
	end
	sound.Parent = parent or SoundService
	return sound
end

local function playSound(sound, volume, speed)
	if not sound then
		return
	end
	if volume then
		sound.Volume = volume
	end
	if speed then
		sound.PlaybackSpeed = speed
	end
	sound.TimePosition = 0
	sound:Play()
end

local function getControls(player)
	local ok, controls = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5)
		return require(module):GetControls()
	end)
	return ok and controls or nil
end

---------------------------------------------------------------------------
-- Haptics (gamepad + supported mobile devices; silently does nothing elsewhere)
---------------------------------------------------------------------------
local hapticTargets = nil
local function setHaptic(value)
	if not hapticTargets then
		hapticTargets = {}
		for _, inputType in { Enum.UserInputType.Gamepad1, Enum.UserInputType.Touch } do
			local ok, supported = pcall(HapticService.IsVibrationSupported, HapticService, inputType)
			if ok and supported then
				for _, motor in { Enum.VibrationMotor.Large, Enum.VibrationMotor.Small } do
					local ok2, motorOk = pcall(HapticService.IsMotorSupported, HapticService, inputType, motor)
					if ok2 and motorOk then
						table.insert(hapticTargets, { inputType, motor })
					end
				end
			end
		end
	end
	for _, target in hapticTargets do
		pcall(HapticService.SetMotor, HapticService, target[1], target[2], value)
	end
end

---------------------------------------------------------------------------
-- Pawn shop room
---------------------------------------------------------------------------
local function buildRoom(rng)
	local O = CONFIG.RoomOrigin
	local model = Instance.new("Model")
	model.Name = "IntroPawnShop"

	local function P(size, where, color, material, extra)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Locked = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if extra and extra.Shape then
			p.Shape = extra.Shape
		end
		p.Size = size
		p.CFrame = CFrame.new(O) * (typeof(where) == "CFrame" and where or CFrame.new(where))
		p.Color = color
		p.Material = material or Enum.Material.Wood
		if extra then
			for k, v in extra do
				if k ~= "Shape" then
					p[k] = v
				end
			end
		end
		p.Parent = model
		return p
	end

	local function wood(darken)
		local c = WOOD[rng:NextInteger(1, #WOOD)]
		return darken and c:Lerp(BLACK, darken) or c
	end

	local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> Y
	local CYL = { Shape = Enum.PartType.Cylinder }
	local DARK = Color3.fromRGB(6, 5, 5)

	-- Outer black shell so no outside light/sky leaks through plank gaps
	do
		local x0, x1 = -HW - 1.6, HW + 1.6
		local y0, y1 = -1.6, ROOM_H + 1.6
		local z0, z1 = CORRIDOR_END_Z - 1.6, HL + 1.6
		local c = Vector3.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
		local s = Vector3.new(x1 - x0, y1 - y0, z1 - z0)
		for _, axis in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis } do
			for _, sign in { -1, 1 } do
				local size = s * (Vector3.one - axis) + axis
				P(size, c + axis * sign * (s:Dot(axis) / 2), BLACK, Enum.Material.SmoothPlastic)
			end
		end
	end

	-- Floor planks (random lengths, small gaps showing the dark subfloor)
	for x = -HW + 0.55, HW, 1.1 do
		local z = -HL
		while z < HL - 0.01 do
			local len = math.min(rng:NextNumber(5, 12), HL - z)
			P(Vector3.new(1.04, 0.35, len - 0.05), Vector3.new(x, -0.175, z + len / 2), wood(), Enum.Material.Wood)
			z += len
		end
	end
	P(Vector3.new(HW * 2 + 2, 0.5, HL * 2 + 2), Vector3.new(0, -0.6, 0), Color3.fromRGB(10, 7, 5), Enum.Material.SmoothPlastic)

	-- Plank walls
	local function wall(alongX, fixed, from, to, door, crack)
		local w = 1.2
		local c = from + w / 2
		while c < to do
			local width, shift = w - 0.05, 0
			if crack and math.abs(c - crack) < 0.01 then
				width, shift = w - 0.45, 0.2 -- leaves a thin slit for the moonlight
			end
			local height, y = ROOM_H, ROOM_H / 2
			if door and c > door[1] and c < door[2] then
				height = ROOM_H - DOOR_H
				y = DOOR_H + height / 2
			end
			local size = alongX and Vector3.new(width, height, 0.35) or Vector3.new(0.35, height, width)
			local pos = alongX and Vector3.new(c + shift, y, fixed) or Vector3.new(fixed, y, c + shift)
			P(size, pos, wood(0.3), Enum.Material.Wood)
			c += w
		end
	end
	wall(true, -HL - 0.175, -HW, HW, { DOOR_MIN_X, DOOR_MAX_X })
	wall(true, HL + 0.175, -HW, HW)
	wall(false, -HW - 0.175, -HL, HL)
	wall(false, HW + 0.175, -HL, HL, nil, CRACK_PLANK_Z)

	-- Ceiling, beams, corner posts, baseboards
	P(Vector3.new(HW * 2 + 1, 0.4, HL * 2 + 1), Vector3.new(0, ROOM_H + 0.2, 0), wood(0.55), Enum.Material.WoodPlanks)
	for _, z in { -12, -4, 4, 12 } do
		P(Vector3.new(HW * 2, 0.7, 0.7), Vector3.new(0, ROOM_H - 0.35, z), wood(0.45), Enum.Material.Wood)
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(Vector3.new(0.6, ROOM_H, 0.6), Vector3.new(sx * (HW - 0.3), ROOM_H / 2, sz * (HL - 0.3)), wood(0.5), Enum.Material.Wood)
		end
		P(Vector3.new(0.25, 0.5, HL * 2), Vector3.new(sx * (HW - 0.12), 0.25, 0), wood(0.5), Enum.Material.Wood)
	end

	-- Doorway + dark corridor the figure comes out of
	for _, x in { DOOR_MIN_X - 0.2, DOOR_MAX_X + 0.2 } do
		P(Vector3.new(0.4, DOOR_H, 0.6), Vector3.new(x, DOOR_H / 2, -HL), wood(0.55), Enum.Material.Wood)
	end
	P(Vector3.new(DOOR_MAX_X - DOOR_MIN_X + 0.8, 0.45, 0.6), Vector3.new(DOOR_X, DOOR_H + 0.22, -HL), wood(0.55), Enum.Material.Wood)
	local corridorLen = -HL - CORRIDOR_END_Z
	local corridorZ = (-HL + CORRIDOR_END_Z) / 2
	for x = DOOR_MIN_X + 0.6, DOOR_MAX_X, 1.2 do
		P(Vector3.new(1.15, 0.35, corridorLen), Vector3.new(x, -0.175, corridorZ), wood(0.5), Enum.Material.Wood)
	end
	P(Vector3.new(0.4, DOOR_H, corridorLen), Vector3.new(DOOR_MIN_X - 0.2, DOOR_H / 2, corridorZ), DARK, Enum.Material.Wood)
	P(Vector3.new(0.4, DOOR_H, corridorLen), Vector3.new(DOOR_MAX_X + 0.2, DOOR_H / 2, corridorZ), DARK, Enum.Material.Wood)
	P(Vector3.new(DOOR_MAX_X - DOOR_MIN_X + 0.8, 0.4, corridorLen), Vector3.new(DOOR_X, DOOR_H + 0.2, corridorZ), DARK, Enum.Material.Wood)
	P(Vector3.new(DOOR_MAX_X - DOOR_MIN_X + 0.8, DOOR_H, 0.4), Vector3.new(DOOR_X, DOOR_H / 2, CORRIDOR_END_Z), DARK, Enum.Material.Wood)

	-- Crates
	local function crate(size, pos, yaw)
		local cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
		P(size, cf, wood(0.1), Enum.Material.WoodPlanks)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				P(Vector3.new(0.22, size.Y + 0.02, 0.22), cf * CFrame.new(sx * (size.X / 2 - 0.09), 0, sz * (size.Z / 2 - 0.09)), wood(0.45), Enum.Material.Wood)
			end
		end
	end
	crate(Vector3.new(3, 3, 3), Vector3.new(-7.5, 1.5, -3), 8) -- lantern sits on this one
	crate(Vector3.new(2.4, 2.4, 2.4), Vector3.new(-8.4, 1.2, 0.6), -14)
	crate(Vector3.new(2, 2, 2), Vector3.new(-8.1, 3.4, 0.4), 22)
	crate(Vector3.new(3.2, 3.2, 3.2), Vector3.new(7.6, 1.6, -12.5), 4)
	crate(Vector3.new(2.2, 2.2, 2.2), Vector3.new(7.9, 4.3, -12.3), -18)
	crate(Vector3.new(2, 2, 2), Vector3.new(8.8, 1, -9.4), 30)
	crate(Vector3.new(2.6, 2.6, 2.6), Vector3.new(-6.2, 1.3, -15.2), -6)
	crate(Vector3.new(2.2, 2.2, 2.2), Vector3.new(8.4, 1.1, 9.5), 12)
	crate(Vector3.new(1.6, 1.6, 1.6), Vector3.new(-8.8, 0.8, 11), -25)

	-- Barrels
	for _, pos in { Vector3.new(5.2, 1.5, -15.5), Vector3.new(9.3, 1.5, 5.4) } do
		P(Vector3.new(3, 2.2, 2.2), CFrame.new(pos) * UPRIGHT, wood(0.15), Enum.Material.Wood, CYL)
		for _, dy in { -0.9, 0.9 } do
			P(Vector3.new(0.15, 2.28, 2.28), CFrame.new(pos + Vector3.new(0, dy, 0)) * UPRIGHT, Color3.fromRGB(30, 28, 26), Enum.Material.Metal, CYL)
		end
	end

	-- Shelves full of pawned junk (left wall)
	local shelfX, shelfZ0, shelfZ1 = -10.15, -14, -7
	for _, z in { shelfZ0, (shelfZ0 + shelfZ1) / 2, shelfZ1 } do
		for _, dx in { -0.7, 0.7 } do
			P(Vector3.new(0.25, 9, 0.25), Vector3.new(shelfX + dx, 4.5, z), wood(0.4), Enum.Material.Wood)
		end
	end
	for _, boardY in { 1.2, 3.4, 5.6, 7.8 } do
		P(Vector3.new(1.6, 0.18, shelfZ1 - shelfZ0 + 0.3), Vector3.new(shelfX, boardY, (shelfZ0 + shelfZ1) / 2), wood(0.3), Enum.Material.Wood)
		local z = shelfZ0 + 0.5
		while z < shelfZ1 - 0.4 do
			local x = shelfX + rng:NextNumber(-0.35, 0.35)
			local y = boardY + 0.09
			local kind = rng:NextInteger(1, 5)
			if kind == 1 then -- jar
				local h = rng:NextNumber(0.6, 1.0)
				local tint = Color3.fromRGB(90, 85, 50):Lerp(Color3.fromRGB(60, 80, 70), rng:NextNumber())
				P(Vector3.new(h, 0.55, 0.55), CFrame.new(x, y + h / 2, z) * UPRIGHT, tint, Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, Transparency = 0.35 })
				P(Vector3.new(0.08, 0.6, 0.6), CFrame.new(x, y + h + 0.04, z) * UPRIGHT, Color3.fromRGB(40, 32, 25), Enum.Material.Metal, CYL)
			elseif kind == 2 then -- bottle
				local tint = Color3.fromRGB(40, 60, 35):Lerp(Color3.fromRGB(70, 35, 20), rng:NextNumber())
				P(Vector3.new(0.7, 0.3, 0.3), CFrame.new(x, y + 0.35, z) * UPRIGHT, tint, Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, Transparency = 0.25 })
				P(Vector3.new(0.3, 0.12, 0.12), CFrame.new(x, y + 0.85, z) * UPRIGHT, tint, Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, Transparency = 0.25 })
			elseif kind == 3 then -- small box
				local s = Vector3.new(rng:NextNumber(0.4, 0.8), rng:NextNumber(0.3, 0.6), rng:NextNumber(0.4, 0.8))
				P(s, CFrame.new(x, y + s.Y / 2, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), wood(0.2), Enum.Material.WoodPlanks)
			elseif kind == 4 then -- book stack
				local stackY = y
				for _ = 1, rng:NextInteger(2, 3) do
					local colors = { Color3.fromRGB(70, 20, 18), Color3.fromRGB(25, 45, 30), Color3.fromRGB(55, 40, 25) }
					P(Vector3.new(0.6, 0.16, 0.8), CFrame.new(x, stackY + 0.08, z) * CFrame.Angles(0, rng:NextNumber(-0.3, 0.3), 0), colors[rng:NextInteger(1, 3)], Enum.Material.Fabric)
					stackY += 0.16
				end
			else -- candle stub
				P(Vector3.new(0.45, 0.22, 0.22), CFrame.new(x, y + 0.225, z) * UPRIGHT, Color3.fromRGB(175, 165, 145), Enum.Material.SmoothPlastic, CYL)
			end
			z += rng:NextNumber(0.6, 1.1)
		end
	end
	P(Vector3.new(0.05, 3.2, 2.2), Vector3.new(-HW + 0.05, 7.2, -4.5), Color3.fromRGB(45, 30, 30), Enum.Material.Fabric) -- hanging cloth

	-- Table with coins
	local tableCF = CFrame.new(7.2, 0, 1)
	P(Vector3.new(4.5, 0.25, 2.6), tableCF * CFrame.new(0, 3.1, 0), wood(0.2), Enum.Material.Wood)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(Vector3.new(0.25, 3, 0.25), tableCF * CFrame.new(sx * 2, 1.5, sz * 1.1), wood(0.35), Enum.Material.Wood)
		end
	end
	for _ = 1, 9 do
		P(Vector3.new(0.04, 0.22, 0.22), tableCF * CFrame.new(rng:NextNumber(-1.6, 1.6), 3.25, rng:NextNumber(-0.9, 0.9)) * UPRIGHT, Color3.fromRGB(130, 105, 40), Enum.Material.Metal, { Shape = Enum.PartType.Cylinder, Reflectance = 0.1 })
	end
	P(Vector3.new(0.9, 0.55, 0.6), tableCF * CFrame.new(-1.2, 3.5, 0.3) * CFrame.Angles(0, 0.4, 0), Color3.fromRGB(50, 20, 20), Enum.Material.Fabric) -- jewelry box

	-- Toppled chair + broken planks near you
	local chairCF = CFrame.new(-2.5, 0.9, 6) * CFrame.Angles(0, 0.6, math.pi / 2)
	for _, sx in { -0.7, 0.7 } do
		for _, sz in { -0.7, 0.7 } do
			P(Vector3.new(0.18, 1.5, 0.18), chairCF * CFrame.new(sx, 0.75, sz), wood(0.25), Enum.Material.Wood)
		end
	end
	P(Vector3.new(1.6, 0.2, 1.6), chairCF * CFrame.new(0, 1.55, 0), wood(0.2), Enum.Material.Wood)
	P(Vector3.new(1.6, 1.8, 0.18), chairCF * CFrame.new(0, 2.5, 0.7), wood(0.2), Enum.Material.Wood)
	for _ = 1, 3 do
		P(Vector3.new(0.9, 0.15, rng:NextNumber(2.5, 4)), CFrame.new(rng:NextNumber(-5, 6), 0.08, rng:NextNumber(3, 10)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0.05), wood(0.2), Enum.Material.Wood)
	end
	for _, x in { -3, 4.5 } do
		P(Vector3.new(0.08, 3.5, 0.08), Vector3.new(x, ROOM_H - 2.45, -4), Color3.fromRGB(80, 70, 55), Enum.Material.Fabric) -- ropes
	end

	-- Your blood, slowly spreading across the boards
	local pool = P(Vector3.new(0.03, 2.6, 2.6), CFrame.new(2.9, 0.015, 10.8) * UPRIGHT, Color3.fromRGB(48, 2, 4), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Reflectance = 0.12, CastShadow = false })
	P(Vector3.new(0.03, 1.6, 1.6), CFrame.new(2.0, 0.016, 11.7) * UPRIGHT, Color3.fromRGB(40, 2, 3), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, Reflectance = 0.12, CastShadow = false })

	-- Lantern: the only warm light
	local lx, ly, lz = -7.5, 3, -3
	local brass = Color3.fromRGB(35, 30, 25)
	P(Vector3.new(0.85, 0.15, 0.85), Vector3.new(lx, ly + 0.075, lz), brass, Enum.Material.Metal)
	P(Vector3.new(0.6, 0.95, 0.6), Vector3.new(lx, ly + 0.62, lz), Color3.fromRGB(255, 180, 90), Enum.Material.Glass, { Transparency = 0.55, CastShadow = false })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(Vector3.new(0.06, 0.95, 0.06), Vector3.new(lx + sx * 0.32, ly + 0.62, lz + sz * 0.32), brass, Enum.Material.Metal, { CastShadow = false })
		end
	end
	P(Vector3.new(0.75, 0.12, 0.75), Vector3.new(lx, ly + 1.16, lz), brass, Enum.Material.Metal)
	local flame = P(Vector3.new(0.16, 0.32, 0.16), Vector3.new(lx, ly + 0.5, lz), Color3.fromRGB(255, 150, 60), Enum.Material.Neon, { CastShadow = false })
	local lantern = new("PointLight", { Color = Color3.fromRGB(255, 125, 48), Range = 30, Brightness = 2.7, Shadows = true, Parent = flame })

	-- Moonlight through the wall crack
	local moonColor = Color3.fromRGB(150, 175, 230)
	P(Vector3.new(0.1, 8, 0.7), Vector3.new(HW + 0.9, 6.5, CRACK_Z), moonColor, Enum.Material.Neon, { CastShadow = false })
	local beamCF = CFrame.new(HW - 0.05, 7.5, CRACK_Z) * CFrame.Angles(0, 0.35, 0) * CFrame.Angles(0, 0, 0.5)
	local emitter = P(Vector3.new(0.2, 0.2, 0.2), beamCF, BLACK, Enum.Material.SmoothPlastic, { Transparency = 1, CastShadow = false })
	new("SpotLight", { Face = Enum.NormalId.Left, Angle = 40, Range = 55, Brightness = 3, Color = Color3.fromRGB(120, 150, 235), Shadows = true, Parent = emitter })
	local beamDir = beamCF:VectorToWorldSpace(-Vector3.xAxis)
	local beamStart = beamCF.Position
	for i, width in { 0.35, 0.9 } do
		P(Vector3.new(width, 5.5, 18), CFrame.lookAt(beamStart, beamStart + beamDir) * CFrame.new(0, 0, -9), moonColor, Enum.Material.Neon, { Transparency = i == 1 and 0.95 or 0.98, CastShadow = false })
	end

	-- Dust motes + low floor mist (built-in engine textures, no uploads)
	local dustBox = P(Vector3.new(HW * 2 - 1, ROOM_H - 1, HL * 2 - 1), Vector3.new(0, ROOM_H / 2, 0), BLACK, Enum.Material.SmoothPlastic, { Transparency = 1, CastShadow = false })
	local dust = new("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Rate = 40,
		Lifetime = NumberRange.new(6, 11),
		Speed = NumberRange.new(0.05, 0.25),
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.5, 0.1), NumberSequenceKeypoint.new(1, 0.04) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.45), NumberSequenceKeypoint.new(0.8, 0.5), NumberSequenceKeypoint.new(1, 1) }),
		Color = ColorSequence.new(Color3.fromRGB(255, 225, 190)),
		LightEmission = 0.15,
		LightInfluence = 1,
		RotSpeed = NumberRange.new(-20, 20),
		Acceleration = Vector3.new(0, -0.03, 0),
		Parent = dustBox,
	})
	local mistBox = P(Vector3.new(HW * 2 - 2, 0.6, HL * 2 - 2), Vector3.new(0, 0.5, 0), BLACK, Enum.Material.SmoothPlastic, { Transparency = 1, CastShadow = false })
	local mist = new("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Rate = 3,
		Lifetime = NumberRange.new(10, 14),
		Speed = NumberRange.new(0.1, 0.3),
		SpreadAngle = Vector2.new(180, 0),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 10) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.86), NumberSequenceKeypoint.new(0.7, 0.88), NumberSequenceKeypoint.new(1, 1) }),
		Color = ColorSequence.new(Color3.fromRGB(40, 32, 30)),
		LightInfluence = 1,
		RotSpeed = NumberRange.new(-5, 5),
		Parent = mistBox,
	})

	return { model = model, lantern = lantern, flame = flame, pool = pool, dust = dust, mist = mist }
end

---------------------------------------------------------------------------
-- The figure: tall faceless silhouette, posed procedurally every frame
---------------------------------------------------------------------------
local function buildFigure(parent)
	local model = Instance.new("Model")
	model.Name = "Figure"
	-- Every body part is an ellipsoid (block + sphere mesh) so the silhouette is smooth, not boxy
	local function fp(name, size)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Locked = true
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = BLACK
		p.Size = size
		new("SpecialMesh", { MeshType = Enum.MeshType.Sphere, Parent = p })
		p.Parent = model
		return p
	end
	local f = {
		model = model,
		legL = fp("LegL", Vector3.new(0.5, FIGURE_LEG, 0.5)),
		legR = fp("LegR", Vector3.new(0.5, FIGURE_LEG, 0.5)),
		hem = fp("Hem", Vector3.new(3.0, 4.4, 1.9)),
		flare = fp("Flare", Vector3.new(3.3, 1.5, 2.2)),
		torso = fp("Torso", Vector3.new(2.3, 4.2, 1.35)),
		shoulders = fp("Shoulders", Vector3.new(2.9, 1.0, 1.1)),
		neck = fp("Neck", Vector3.new(0.5, 0.9, 0.5)),
		head = fp("Head", Vector3.new(0.9, 1.3, 0.95)),
		hood = fp("Hood", Vector3.new(1.55, 2.0, 1.55)),
		hoodTip = fp("HoodTip", Vector3.new(0.7, 1.4, 0.7)),
	}
	for i = 1, 5 do
		f["tatter" .. i] = fp("Tatter" .. i, Vector3.new(0.32, 1.9, 0.14))
	end
	for _, tag in { "L", "R" } do
		f["upperArm" .. tag] = fp("UpperArm" .. tag, Vector3.new(0.36, 2.3, 0.36))
		f["foreArm" .. tag] = fp("ForeArm" .. tag, Vector3.new(0.3, 2.4, 0.3))
		f["hand" .. tag] = fp("Hand" .. tag, Vector3.new(0.22, 1.0, 0.38))
		for k = 1, 3 do
			f["finger" .. tag .. k] = fp("Finger" .. tag .. k, Vector3.new(0.07, 1.0, 0.07))
		end
	end
	new("Highlight", {
		FillColor = BLACK,
		FillTransparency = 0,
		OutlineColor = Color3.fromRGB(20, 20, 20),
		OutlineTransparency = 1,
		DepthMode = Enum.HighlightDepthMode.Occluded,
		Adornee = model,
		Parent = model,
	})
	new("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Rate = 14,
		Lifetime = NumberRange.new(2, 3.5),
		Speed = NumberRange.new(0.15, 0.5),
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 3.5) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.8), NumberSequenceKeypoint.new(1, 1) }),
		Color = ColorSequence.new(Color3.fromRGB(10, 10, 12)),
		LightInfluence = 0,
		Parent = f.hem,
	})
	model.Parent = parent
	return f
end

local function poseFigure(f, rootCF, st, t, parts, cframes)
	table.clear(parts)
	table.clear(cframes)
	local function put(part, cf)
		parts[#parts + 1] = part
		cframes[#cframes + 1] = cf
	end
	local swing = math.sin(st.phase) * 0.38 * st.walk
	local chuck = st.chuckle * math.sin(t * 17)
	local bob = math.abs(math.sin(st.phase)) * 0.1 * st.walk - math.abs(chuck) * 0.04
	local breathe = math.sin(t * 0.9) * 0.03
	local hip = rootCF * CFrame.new(0, FIGURE_HIP + bob, 0)
	local upper = hip * CFrame.Angles(st.lean - 0.04 * st.walk, math.sin(st.phase) * 0.05 * st.walk, 0)
	local sway = math.sin(st.phase) * 0.03 * st.walk

	put(f.legL, hip * CFrame.new(-0.4, 0, 0) * CFrame.Angles(swing, 0, 0) * CFrame.new(0, -FIGURE_LEG / 2, 0))
	put(f.legR, hip * CFrame.new(0.4, 0, 0) * CFrame.Angles(-swing, 0, 0) * CFrame.new(0, -FIGURE_LEG / 2, 0))
	put(f.hem, hip * CFrame.new(0, -1.7, 0) * CFrame.Angles(swing * 0.1, 0, sway))
	put(f.flare, hip * CFrame.new(0, -3.1, 0) * CFrame.Angles(swing * 0.1, 0, sway))
	for i = 1, 5 do -- ragged coat tatters swaying at the hem
		local x = (i - 3) * 0.62
		local z = (i % 2 == 0 and 0.5 or -0.4)
		put(f["tatter" .. i], hip * CFrame.new(x, -3.2, z) * CFrame.Angles(math.sin(t * 1.5 + i) * 0.12 + swing * 0.15, 0, math.sin(t * 1.1 + i * 1.7) * 0.1) * CFrame.new(0, -0.9, 0))
	end
	put(f.torso, upper * CFrame.new(0, 1.4 + breathe, 0))
	put(f.shoulders, upper * CFrame.new(0, 2.9 + breathe, 0))
	local neckCF = upper * CFrame.new(0, 3.4 + breathe + chuck * 0.04, 0)
	put(f.neck, neckCF)
	local headBase = neckCF * CFrame.Angles(st.head + chuck * 0.05, 0, st.headRoll + 0.04 * math.sin(t * 0.7))
	local headCF = headBase * CFrame.new(0, 0.6, 0)
	put(f.head, headCF)
	put(f.hood, headBase * CFrame.new(0, 0.7, 0.1))
	put(f.hoodTip, headBase * CFrame.new(0, 1.45, 0.16) * CFrame.Angles(0.2, 0, 0))

	local armSwing = swing * 0.5
	for _, side in { -1, 1 } do
		local tag = side < 0 and "L" or "R"
		local reach = side > 0 and st.reach or st.reach * 0.35
		local shoulder = upper * CFrame.new(side * 1.25, 2.9 + breathe, 0)
		local a1 = shoulder * CFrame.Angles(-armSwing * side + reach * 0.9, 0, side * (0.07 + chuck * 0.02))
		put(f["upperArm" .. tag], a1 * CFrame.new(0, -1.05, 0))
		local e = a1 * CFrame.new(0, -2.1, 0) * CFrame.Angles(0.1 + reach * 0.8, 0, 0)
		put(f["foreArm" .. tag], e * CFrame.new(0, -1.1, 0))
		local w = e * CFrame.new(0, -2.2, 0) * CFrame.Angles(0.15 + reach * 0.25, 0, 0)
		put(f["hand" .. tag], w * CFrame.new(0, -0.45, 0))
		for k = 1, 3 do -- long, thin, slightly curled fingers
			local curl = 0.25 + 0.08 * k + 0.06 * math.sin(t * 1.3 + k + side)
			put(f["finger" .. tag .. k], w * CFrame.new((k - 2) * 0.09, -0.85, 0) * CFrame.Angles(curl, 0, (k - 2) * 0.12) * CFrame.new(0, -0.5, 0))
		end
	end

	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	return headCF.Position, (upper * CFrame.new(0, 1.5, 0)).Position
end

---------------------------------------------------------------------------
-- Title menu
---------------------------------------------------------------------------
local function spaced(text)
	return (text:gsub(".", "%0 "):gsub("%s+$", ""))
end

local function runTitleMenu(playerGui, fadeBlack, rng)
	local gui = makeScreenGui(playerGui, "TitleMenu", 150)

	-- Animated backdrop
	local backdrop = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = gui })
	local bgGrad = new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 24, 28)),
			ColorSequenceKeypoint.new(0.45, Color3.fromRGB(8, 7, 16)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 20, 16)),
		}),
		Rotation = 25,
		Parent = backdrop,
	})

	local glows = {}
	local function glow(color, x, y, size)
		local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y), Size = UDim2.fromScale(size, size), BackgroundTransparency = 1, Parent = gui })
		new("UIAspectRatioConstraint", { AspectRatio = 1, Parent = holder })
		for i = 1, 6 do
			local s = i / 6
			local ring = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(s, s), BackgroundColor3 = color, BackgroundTransparency = 0.955, BorderSizePixel = 0, Parent = holder })
			corner(ring, UDim.new(1, 0))
		end
		table.insert(glows, { holder = holder, x = x, y = y, phase = rng:NextNumber(0, 6.28) })
	end
	glow(Color3.fromRGB(170, 170, 180), 0.5, 0.42, 0.75)
	glow(Color3.fromRGB(255, 120, 60), 0.15, 0.85, 0.5)
	glow(Color3.fromRGB(95, 110, 130), 0.88, 0.15, 0.45)

	gradientFrame(gui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.45) }, -90, NumberSequence.new(0.15, 1))
	gradientFrame(gui, { Size = UDim2.fromScale(1, 0.25) }, 90, NumberSequence.new(0.35, 1))

	local emberLayer = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = gui })
	local embers = {}
	for i = 1, 48 do
		local size = rng:NextInteger(2, 5)
		local warm = rng:NextNumber() < 0.65
		local frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = warm and Color3.fromRGB(255, 150, 80) or Color3.fromRGB(200, 170, 140),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = emberLayer,
		})
		corner(frame, UDim.new(1, 0))
		embers[i] = {
			frame = frame,
			x = rng:NextNumber(),
			y = rng:NextNumber(0, 1.1),
			speed = rng:NextNumber(0.025, 0.07),
			drift = rng:NextNumber(0.005, 0.02),
			freq = rng:NextNumber(0.4, 1.2),
			phase = rng:NextNumber(0, 6.28),
			alpha = rng:NextNumber(0.35, 0.85),
		}
	end

	-- Logo
	local logo = new("CanvasGroup", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.43), Size = UDim2.new(0.9, 0, 0, 220), BackgroundTransparency = 1, GroupTransparency = 1, Parent = gui })
	new("UISizeConstraint", { MaxSize = Vector2.new(1100, 220), Parent = logo })
	local glowText, titleStroke
	if CONFIG.LogoImage ~= "" then
		new("ImageLabel", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(1, 0, 0, 136), BackgroundTransparency = 1, Image = CONFIG.LogoImage, ScaleType = Enum.ScaleType.Fit, Parent = logo })
	else
		local function titleLabel(props)
			props.AnchorPoint = Vector2.new(0.5, 0)
			props.Position = UDim2.new(0.5, 0, 0, 10)
			props.Size = UDim2.new(1, -40, 0, 130)
			props.BackgroundTransparency = 1
			props.Font = Enum.Font.GothamBlack
			props.Text = CONFIG.GameTitle
			props.TextScaled = true
			props.Parent = logo
			local label = new("TextLabel", props)
			new("UITextSizeConstraint", { MaxTextSize = 110, Parent = label })
			return label
		end
		glowText = titleLabel({ TextColor3 = Color3.fromRGB(190, 190, 198), TextTransparency = 0.6 })
		new("UIStroke", { Color = Color3.fromRGB(170, 170, 180), Thickness = 10, Transparency = 0.86, Parent = glowText })
		local title = titleLabel({ TextColor3 = Color3.new(1, 1, 1) })
		new("UIGradient", { Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 210)), Rotation = 90, Parent = title })
		titleStroke = new("UIStroke", { Color = Color3.fromRGB(200, 200, 205), Thickness = 1.5, Transparency = 0.4, Parent = title })
	end
	local accent = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 156), Size = UDim2.new(0, 0, 0, 2), BackgroundColor3 = Color3.fromRGB(200, 190, 180), BorderSizePixel = 0, Parent = logo })
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) }), Parent = accent })
	new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 156), Size = UDim2.fromOffset(8, 8), Rotation = 45, BackgroundColor3 = Color3.fromRGB(235, 225, 215), BorderSizePixel = 0, Parent = logo })
	new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 172),
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		Text = spaced(CONFIG.Subtitle),
		TextSize = 16,
		TextColor3 = Color3.fromRGB(190, 188, 184),
		Parent = logo,
	})

	-- BEGIN button
	local buttonGroup = new("CanvasGroup", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.7), Size = UDim2.fromOffset(360, 120), BackgroundTransparency = 1, GroupTransparency = 1, Parent = gui })
	local btnGlow = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(250, 56), BackgroundColor3 = Color3.fromRGB(170, 170, 180), BackgroundTransparency = 1, BorderSizePixel = 0, Parent = buttonGroup })
	corner(btnGlow, UDim.new(0, 10))
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(240, 54),
		BackgroundColor3 = Color3.fromRGB(14, 14, 16),
		BackgroundTransparency = 0.25,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		Text = "BEGIN",
		TextSize = 22,
		TextColor3 = Color3.fromRGB(232, 230, 228),
		Parent = buttonGroup,
	})
	corner(button, UDim.new(0, 4))
	local btnStroke = new("UIStroke", { Color = Color3.fromRGB(190, 190, 196), Thickness = 1.5, Transparency = 0.35, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	local function bracket(text, anchorX, offset)
		return new("TextLabel", { AnchorPoint = Vector2.new(anchorX, 0.5), Position = UDim2.new(0.5, offset, 0.5, -2), Size = UDim2.fromOffset(20, 44), BackgroundTransparency = 1, Font = Enum.Font.Gotham, Text = text, TextSize = 34, TextColor3 = Color3.fromRGB(200, 195, 188), Parent = buttonGroup })
	end
	local bracketL = bracket("[", 1, -128)
	local bracketR = bracket("]", 0, 128)

	new("TextLabel", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 18, 1, -14), Size = UDim2.fromOffset(200, 16), BackgroundTransparency = 1, Font = Enum.Font.Gotham, Text = CONFIG.VersionText, TextSize = 12, TextColor3 = Color3.fromRGB(150, 148, 146), TextTransparency = 0.4, TextXAlignment = Enum.TextXAlignment.Left, Parent = gui })

	local hoverSound = makeSound("Hover", { Volume = 0.5 })
	local clickSound = makeSound("Click", { Volume = 0.7 })
	local music = makeSound("MenuMusic", { Looped = true, Volume = 0 })
	if music then
		music:Play()
		tween(music, TweenInfo.new(2.5), { Volume = 0.45 })
	end

	local ready, clicked, hovered = false, false, false
	local function setHover(on)
		if clicked or hovered == on then
			return
		end
		hovered = on
		local info = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		tween(button, info, {
			Size = on and UDim2.fromOffset(262, 58) or UDim2.fromOffset(240, 54),
			BackgroundColor3 = on and Color3.fromRGB(44, 44, 48) or Color3.fromRGB(14, 14, 16),
			TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(232, 230, 228),
		})
		tween(btnStroke, info, { Transparency = on and 0 or 0.35, Thickness = on and 2 or 1.5 })
		tween(btnGlow, info, { BackgroundTransparency = on and 0.82 or 1, Size = on and UDim2.fromOffset(290, 78) or UDim2.fromOffset(250, 56) })
		tween(bracketL, info, { Position = UDim2.new(0.5, on and -150 or -128, 0.5, -2) })
		tween(bracketR, info, { Position = UDim2.new(0.5, on and 150 or 128, 0.5, -2) })
		if on then
			playSound(hoverSound)
		end
	end
	button.MouseEnter:Connect(function()
		setHover(true)
	end)
	button.MouseLeave:Connect(function()
		setHover(false)
	end)
	button.SelectionGained:Connect(function()
		setHover(true)
	end)
	button.SelectionLost:Connect(function()
		setHover(false)
	end)

	local t = 0
	local conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		bgGrad.Rotation = 25 + 12 * math.sin(t * 0.08)
		bgGrad.Offset = Vector2.new(0.08 * math.sin(t * 0.05), 0.05 * math.cos(t * 0.06))
		for _, g in glows do
			g.holder.Position = UDim2.fromScale(g.x + 0.03 * math.sin(t * 0.13 + g.phase), g.y + 0.025 * math.cos(t * 0.11 + g.phase))
		end
		for _, e in embers do
			e.y -= e.speed * dt
			if e.y < -0.05 then
				e.y = 1.05
				e.x = rng:NextNumber()
			end
			e.frame.Position = UDim2.fromScale(e.x + e.drift * math.sin(t * e.freq + e.phase), e.y)
			local edge = clamp01(math.min((1.05 - e.y) * 5, (e.y + 0.05) * 5))
			local twinkle = 0.75 + 0.25 * math.sin(t * e.freq * 4 + e.phase)
			e.frame.BackgroundTransparency = 1 - e.alpha * edge * twinkle
		end
		if titleStroke then
			titleStroke.Transparency = 0.45 + 0.2 * math.sin(t * 1.4)
		end
		if glowText then
			glowText.TextTransparency = 0.6 + 0.12 * math.sin(t * 1.4)
		end
		if not hovered and not clicked then
			btnStroke.Transparency = 0.35 + 0.15 * math.sin(t * 2)
		end
	end)

	-- Intro animation
	fadeBlack(1, 1.6, true)
	tween(logo, TweenInfo.new(1.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.4) })
	task.delay(0.5, function()
		tween(accent, TweenInfo.new(1.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = UDim2.new(0.5, 0, 0, 2) })
	end)
	task.delay(0.9, function()
		tween(buttonGroup, TweenInfo.new(1.0, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { GroupTransparency = 0 })
		ready = true
		if UserInputService.GamepadEnabled then
			GuiService.SelectedObject = button
		end
	end)

	local done = Instance.new("BindableEvent")
	button.Activated:Connect(function()
		if clicked or not ready then
			return
		end
		clicked = true
		playSound(clickSound)
		tween(button, TweenInfo.new(0.07), { Size = UDim2.fromOffset(236, 50) })
		task.delay(0.07, function()
			tween(button, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(262, 58), BackgroundColor3 = Color3.fromRGB(110, 108, 106) })
		end)
		if music then
			tween(music, TweenInfo.new(1.2), { Volume = 0 })
		end
		done:Fire()
	end)
	done.Event:Wait()
	done:Destroy()

	task.wait(0.25)
	local fadeInfo = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	tween(logo, fadeInfo, { GroupTransparency = 1 })
	tween(buttonGroup, fadeInfo, { GroupTransparency = 1 })
	fadeBlack(0, 0.9)

	if GuiService.SelectedObject == button then
		GuiService.SelectedObject = nil
	end
	conn:Disconnect()
	for _, s in { music, hoverSound, clickSound } do
		if s then
			s:Destroy()
		end
	end
	gui:Destroy()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function IntroCutscene.IsPlaying()
	return isPlaying
end

function IntroCutscene.Play()
	assert(RunService:IsClient(), "IntroCutscene.Play() must be called from a LocalScript")
	if isPlaying then
		return false
	end
	isPlaying = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local camera = workspace.CurrentCamera
	local rng = Random.new()
	local seed = rng:NextNumber(0, 500)

	-- Black cover first so nothing flashes on screen while we build
	local transitionGui = makeScreenGui(playerGui, "IntroTransition", 200)
	local blackFrame = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BorderSizePixel = 0, Parent = transitionGui })
	local fadeTween
	local function fadeBlack(target, time, async)
		if fadeTween then
			fadeTween:Cancel()
		end
		blackFrame.Visible = true
		local tw = TweenService:Create(blackFrame, TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = target })
		fadeTween = tw
		tw:Play()
		local function onDone(state)
			if state == Enum.PlaybackState.Completed and target >= 1 then
				blackFrame.Visible = false
			end
		end
		if async then
			tw.Completed:Once(onDone)
		else
			onDone(tw.Completed:Wait())
		end
	end

	-- Snapshots
	local camSnap = { FieldOfView = camera.FieldOfView }
	local lightSnap = {}
	for _, prop in LIGHT_PROPS do
		lightSnap[prop] = Lighting[prop]
	end
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") -- would override our fog
	local coreSnap = {}
	for _, coreType in Enum.CoreGuiType:GetEnumItems() do
		if coreType ~= Enum.CoreGuiType.All then
			local ok, enabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, coreType)
			coreSnap[coreType] = ok and enabled
		end
	end
	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.All, false)
	local controls = getControls(player)
	if controls then
		pcall(function()
			controls:Disable()
		end)
	end

	---------------------------------------------------------------- scene
	local O = CONFIG.RoomOrigin
	local camPos = O + CAM_LOCAL
	local doorFocus = O + Vector3.new(DOOR_X, 3.2, -HL)
	local figStart, figStop = O + FIGURE_START, O + FIGURE_STOP
	local figTotal = (figStop - figStart).Magnitude

	local room = buildRoom(rng)
	local figure = buildFigure(room.model)
	room.model.Parent = workspace
	room.dust:Emit(220)
	room.mist:Emit(25)

	if atmosphere then
		atmosphere.Parent = nil
	end
	for prop, value in CUTSCENE_LIGHTING do
		pcall(function()
			Lighting[prop] = value
		end)
	end
	local blur = new("BlurEffect", { Name = "IntroBlur", Size = 14, Parent = Lighting })
	local grade = new("ColorCorrectionEffect", { Name = "IntroGrade", Saturation = -0.5, Contrast = 0.05, Brightness = -0.04, TintColor = Color3.fromRGB(204, 212, 226), Parent = Lighting })
	local dof = new("DepthOfFieldEffect", { Name = "IntroDoF", FarIntensity = 0.35, NearIntensity = 0.2, FocusDistance = 14, InFocusRadius = 12, Parent = Lighting })
	local bloom = new("BloomEffect", { Name = "IntroBloom", Intensity = 0.3, Size = 28, Threshold = 1.1, Parent = Lighting })

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 63
	camera.CFrame = CFrame.lookAt(camPos, doorFocus)

	local sounds = {
		ambience = makeSound("Ambience", { Looped = true, Volume = 0.4 }),
		breath = makeSound("Breath", { Looped = true, Volume = 0.3 }),
		heartbeat = makeSound("Heartbeat", { Volume = 0.6 }),
		typewriter = makeSound("Typewriter", { Volume = 0.25 }),
		passOut = makeSound("PassOut", { Volume = 0.8 }),
		footstep = makeSound("Footstep", { Volume = 1, RollOffMaxDistance = 90, RollOffMinDistance = 6 }, figure.coat),
		chuckle = makeSound("Chuckle", { Volume = 0.9, RollOffMinDistance = 8 }, figure.head),
	}
	if sounds.footstep then
		new("EchoSoundEffect", { Delay = 0.22, Feedback = 0.35, DryLevel = 0, WetLevel = -5, Parent = sounds.footstep })
	end
	if sounds.chuckle then
		new("EchoSoundEffect", { Delay = 0.18, Feedback = 0.25, DryLevel = 0, WetLevel = -8, Parent = sounds.chuckle })
	end
	if sounds.ambience then
		sounds.ambience:Play()
	end
	if sounds.breath then
		sounds.breath:Play()
	end

	---------------------------------------------------------------- vision GUI
	local visionGui = makeScreenGui(playerGui, "IntroVision", 100)

	-- Double vision: two offset copies of the room blended over the real view
	local function makeGhost(transparency)
		local vp = new("ViewportFrame", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ImageTransparency = transparency, ZIndex = 0,
			Ambient = Color3.fromRGB(70, 74, 88), LightColor = Color3.fromRGB(90, 95, 110),
			LightDirection = Vector3.new(-0.4, -1, -0.3), ImageColor3 = Color3.fromRGB(190, 195, 210), Parent = visionGui,
		})
		local cam = new("Camera", { Parent = vp })
		vp.CurrentCamera = cam
		local model = room.model:Clone()
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Highlight") or d:IsA("Sound") then
				d:Destroy()
			end
		end
		model.Parent = vp
		local map = {}
		local figModel = model:FindFirstChild("Figure")
		if figModel then
			for _, part in figModel:GetChildren() do
				if part:IsA("BasePart") then
					map[part.Name] = part
				end
			end
		end
		return { vp = vp, cam = cam, map = map }
	end
	local ghosts = { makeGhost(0.7), makeGhost(0.82) }

	-- Grey haze, drifting clouds, messy dark-grey paint/blood splatters, and scratches
	local haze = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(104, 106, 112), BackgroundTransparency = 0.78, BorderSizePixel = 0, ZIndex = 1, Parent = visionGui })
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.5, 0.8), NumberSequenceKeypoint.new(1, 0.3) }), Rotation = 90, Parent = haze })

	local function blob(parent, x, y, w, h, tone, alpha)
		local f = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(w, h),
			BackgroundColor3 = Color3.fromRGB(tone, tone, tone + 3),
			BackgroundTransparency = alpha,
			BorderSizePixel = 0,
			ZIndex = 1,
			Parent = parent,
		})
		corner(f, UDim.new(1, 0))
		return f
	end

	local clouds = {}
	for i = 1, 10 do
		local size = rng:NextNumber(0.5, 0.95)
		local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber()), Size = UDim2.fromScale(size, size), BackgroundTransparency = 1, ZIndex = 1, Parent = visionGui })
		new("UIAspectRatioConstraint", { AspectRatio = rng:NextNumber(1.2, 2), Parent = holder })
		local tone = rng:NextInteger(70, 115)
		for r = 1, 6 do
			local sc = r / 6
			blob(holder, 0.5 + rng:NextNumber(-0.05, 0.05), 0.5 + rng:NextNumber(-0.05, 0.05), sc, sc, tone, 0.95 + (1 - sc) * 0.02)
		end
		clouds[i] = { holder = holder, x = holder.Position.X.Scale, y = holder.Position.Y.Scale, phase = rng:NextNumber(0, 6.28), speed = rng:NextNumber(0.03, 0.09) }
	end

	local smudges = {}
	for i = 1, 24 do
		local side = rng:NextInteger(1, 4)
		local along, edge = rng:NextNumber(), rng:NextNumber(-0.03, 0.07)
		local x, y
		if side == 1 then
			x, y = along, edge
		elseif side == 2 then
			x, y = along, 1 - edge
		elseif side == 3 then
			x, y = edge, along
		else
			x, y = 1 - edge, along
		end
		local size = rng:NextNumber(0.09, 0.3)
		local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y), Size = UDim2.fromScale(size, size), BackgroundTransparency = 1, ZIndex = 1, Parent = visionGui })
		new("UIAspectRatioConstraint", { Parent = holder })
		local tone = rng:NextInteger(34, 66)
		local alpha = rng:NextNumber(0.5, 0.74)
		for _ = 1, rng:NextInteger(3, 5) do -- lumpy core
			blob(holder, 0.5 + rng:NextNumber(-0.2, 0.2), 0.5 + rng:NextNumber(-0.2, 0.2), rng:NextNumber(0.25, 0.6), rng:NextNumber(0.2, 0.5), tone, alpha)
		end
		for _ = 1, rng:NextInteger(1, 3) do -- drips running down
			local w, h = rng:NextNumber(0.04, 0.09), rng:NextNumber(0.25, 0.6)
			local dx, dy = 0.5 + rng:NextNumber(-0.25, 0.25), 0.55 + h * 0.5
			blob(holder, dx, dy, w, h, tone, alpha)
			blob(holder, dx, dy + h * 0.5, w * 1.7, w * 1.7, tone, alpha) -- droplet at the end
		end
		for _ = 1, rng:NextInteger(5, 9) do -- flung satellite flecks
			local ang, rad = rng:NextNumber(0, 6.28), rng:NextNumber(0.4, 0.95)
			local d = rng:NextNumber(0.025, 0.08)
			blob(holder, 0.5 + math.cos(ang) * rad, 0.5 + math.sin(ang) * rad, d, d, tone, alpha + 0.04)
		end
		smudges[i] = { holder = holder, x = x, y = y, phase = rng:NextNumber(0, 6.28), speed = rng:NextNumber(0.05, 0.14) }
	end

	for i = 1, 48 do -- fine scratches on the "lens"
		local x, y = rng:NextNumber(), rng:NextNumber()
		if rng:NextNumber() < 0.6 then
			x = rng:NextNumber() < 0.5 and rng:NextNumber(0, 0.2) or rng:NextNumber(0.8, 1)
		end
		local line = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromOffset(rng:NextInteger(40, 340), rng:NextInteger(1, 2)),
			Rotation = rng:NextNumber(-80, 80),
			BackgroundColor3 = Color3.fromRGB(rng:NextInteger(150, 205), rng:NextInteger(150, 205), rng:NextInteger(155, 210)),
			BackgroundTransparency = rng:NextNumber(0.74, 0.92),
			BorderSizePixel = 0,
			ZIndex = 1,
			Parent = visionGui,
		})
		new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) }), Parent = line })
	end

	local edgeSeq = NumberSequence.new(0, 1)
	local vigColor = Color3.fromRGB(26, 26, 28)
	local vignette = {
		gradientFrame(visionGui, { Size = UDim2.fromScale(0.34, 1), ZIndex = 1, BackgroundColor3 = vigColor }, 0, edgeSeq),
		gradientFrame(visionGui, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.34, 1), ZIndex = 1, BackgroundColor3 = vigColor }, 180, edgeSeq),
		gradientFrame(visionGui, { Size = UDim2.fromScale(1, 0.3), ZIndex = 1, BackgroundColor3 = vigColor }, 90, edgeSeq),
		gradientFrame(visionGui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.3), ZIndex = 1, BackgroundColor3 = vigColor }, -90, edgeSeq),
	}
	local lidSeq = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.72, 0), NumberSequenceKeypoint.new(1, 1) })
	local lidColor = Color3.fromRGB(8, 8, 9)
	local topLid = gradientFrame(visionGui, { Size = UDim2.fromScale(1, 0), ZIndex = 2, BackgroundColor3 = lidColor }, 90, lidSeq)
	local bottomLid = gradientFrame(visionGui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), ZIndex = 2, BackgroundColor3 = lidColor }, -90, lidSeq)

	local box = new("CanvasGroup", {
		Name = "Dialogue",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -46),
		Size = UDim2.new(0.62, 0, 0, 122),
		BackgroundColor3 = Color3.fromRGB(9, 9, 10),
		BackgroundTransparency = 0.2,
		GroupTransparency = 1,
		ZIndex = 5,
		Parent = visionGui,
	})
	new("UISizeConstraint", { MinSize = Vector2.new(300, 0), MaxSize = Vector2.new(860, 200), Parent = box })
	corner(box, UDim.new(0, 4))
	local topLine = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromRGB(120, 120, 125), BorderSizePixel = 0, Parent = box })
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.2), NumberSequenceKeypoint.new(1, 1) }), Parent = topLine })
	new("Frame", { Position = UDim2.new(0, 0, 0, 14), Size = UDim2.new(0, 2, 1, -28), BackgroundColor3 = Color3.fromRGB(120, 120, 125), BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = box })
	local speakerLabel = new("TextLabel", { Position = UDim2.new(0, 22, 0, 14), Size = UDim2.new(1, -44, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(170, 170, 175), Text = "", Parent = box })
	local textLabel = new("TextLabel", { Position = UDim2.new(0, 22, 0, 38), Size = UDim2.new(1, -44, 1, -62), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 20, TextWrapped = true, RichText = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = Color3.fromRGB(230, 228, 226), Text = "", Parent = box })
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local prompt = new("TextLabel", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -18, 1, -10), Size = UDim2.fromOffset(260, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Color3.fromRGB(150, 148, 146), Text = touchOnly and "[Tap to continue]" or "[Press ENTER to continue]", Visible = false, Parent = box })

	local skipGui = makeScreenGui(playerGui, "IntroSkip", 300, true)
	local skipButton = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 16),
		Size = UDim2.fromOffset(92, 30),
		BackgroundColor3 = Color3.fromRGB(10, 10, 11),
		BackgroundTransparency = 0.5,
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		Text = "[ SKIP ]",
		TextSize = 13,
		TextColor3 = Color3.fromRGB(205, 203, 200),
		TextTransparency = 0.35,
		Parent = skipGui,
	})
	corner(skipButton, UDim.new(0, 4))
	local skipStroke = new("UIStroke", { Color = Color3.fromRGB(130, 130, 135), Thickness = 1, Transparency = 0.65, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = skipButton })
	skipButton.MouseEnter:Connect(function()
		tween(skipButton, TweenInfo.new(0.15), { TextTransparency = 0, BackgroundTransparency = 0.3 })
		tween(skipStroke, TweenInfo.new(0.15), { Transparency = 0.2 })
	end)
	skipButton.MouseLeave:Connect(function()
		tween(skipButton, TweenInfo.new(0.15), { TextTransparency = 0.35, BackgroundTransparency = 0.5 })
		tween(skipStroke, TweenInfo.new(0.15), { Transparency = 0.65 })
	end)

	---------------------------------------------------------------- vision state
	local vis = {
		cur = {
			lid = 0.92, blur = 14, sat = -0.5, contrast = 0.05, bright = -0.04,
			fovMid = (CONFIG.FovMin + CONFIG.FovMax) / 2, fovAmp = (CONFIG.FovMax - CONFIG.FovMin) / 2,
			sway = 1, violence = 0, vignette = 0.8, weakness = 0,
			figLean = 0, figHead = 0, figHeadRoll = 0, figReach = 0, figChuckle = 0,
		},
		target = {},
		rate = {},
	}
	for k, v in vis.cur do
		vis.target[k] = v
		vis.rate[k] = 2
	end
	local function setVis(key, value, rate)
		vis.target[key] = value
		vis.rate[key] = rate or 2
	end
	local lidOverride = new("NumberValue", { Value = 0 })

	local fig = { dist = 0, phase = 0, walk = 0, walking = false, arrived = false, lastStep = 0 }
	local figParts, figCFrames = {}, {}
	local t, pulse, spike, thump = 0, 0, 0, 0
	local nextSpike, nextBlink, blinkStart = 3, 5, -10
	local nextNod, nodStart, nodJerked = 5, -10, false
	local fallStart = nil
	local pausedOnce, pauseUntil = false, 0
	local hb = { next = 0.6, dub = nil, dubStrength = 0 }
	local hapticOffAt = nil

	local function heartbeat(strength)
		pulse = math.max(pulse, strength)
		playSound(sounds.heartbeat, 0.25 + 0.6 * strength, 0.95)
		setHaptic(strength)
		hapticOffAt = t + 0.09
	end

	local function step(dt)
		t += dt
		local prog = clamp01(t / 30) -- vision keeps getting worse
		local cur = vis.cur
		for k, target in vis.target do
			cur[k] += (target - cur[k]) * math.min(1, dt * vis.rate[k])
		end
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end

		-- Figure walk
		if fig.walking and not pausedOnce and fig.dist > figTotal * 0.52 then
			pausedOnce = true
			pauseUntil = t + 1.9
			setVis("figHeadRoll", 0.28, 1.5)
			setVis("figHead", -0.12, 1.5)
		end
		if fig.walking and t < pauseUntil then
			fig.walk = math.max(0, fig.walk - dt * 3)
		elseif fig.walking then
			if pausedOnce and cur.figHeadRoll > 0.1 then
				setVis("figHeadRoll", 0, 2)
				setVis("figHead", 0, 2)
			end
			fig.walk = math.min(1, fig.walk + dt * 2)
			fig.phase += dt * math.pi / FIGURE_STEP_TIME
			fig.dist += FIGURE_SPEED * dt * (0.55 + 0.45 * math.abs(math.cos(fig.phase)))
			local stepIndex = math.floor(fig.phase / math.pi)
			if stepIndex > fig.lastStep then
				fig.lastStep = stepIndex
				local closeness = 1 - clamp01(fig.dist / figTotal)
				playSound(sounds.footstep, 1, rng:NextNumber(0.9, 1.05))
				thump = math.max(thump, (1 - closeness) * 0.05)
				if fig.dist > figTotal * 0.5 then
					setHaptic(0.15 * (1 - closeness))
					hapticOffAt = t + 0.05
				end
			end
			if fig.dist >= figTotal then
				fig.dist = figTotal
				fig.walking = false
				fig.arrived = true
				playSound(sounds.footstep, 1, 0.85)
				thump = 0.06
			end
		else
			fig.walk = math.max(0, fig.walk - dt * 1.5)
			fig.phase += dt * math.pi / FIGURE_STEP_TIME * fig.walk
		end
		local figPos = figStart:Lerp(figStop, fig.dist / figTotal)
		local rootCF = CFrame.lookAt(figPos, Vector3.new(camPos.X, figPos.Y, camPos.Z))
		local headPos, chestPos = poseFigure(figure, rootCF, {
			phase = fig.phase, walk = fig.walk, lean = cur.figLean, head = cur.figHead,
			headRoll = cur.figHeadRoll, reach = cur.figReach, chuckle = cur.figChuckle,
		}, t, figParts, figCFrames)

		-- Heartbeat: slow, uneven, weakening
		local weakness = clamp01(t / 55 * 0.7 + cur.weakness)
		if t >= hb.next then
			local strength = lerp(0.75, 0.18, weakness)
			heartbeat(strength)
			hb.dub, hb.dubStrength = t + 0.26, strength * 0.6
			hb.next = t + lerp(1.05, 1.95, weakness) + rng:NextNumber(-0.06, 0.12)
		end
		if hb.dub and t >= hb.dub then
			heartbeat(hb.dubStrength)
			hb.dub = nil
		end
		if hapticOffAt and t >= hapticOffAt then
			setHaptic(0)
			hapticOffAt = nil
		end
		pulse *= math.exp(-dt * 7)
		thump *= math.exp(-dt * 10)

		-- Focus-loss blur spikes
		if t >= nextSpike then
			spike = rng:NextNumber(8, 18) * (1 + cur.violence)
			nextSpike = t + rng:NextNumber(2.2, 5.5) * (1 - 0.6 * cur.violence)
		end
		spike *= math.exp(-dt * 3)
		local spikeN = clamp01(spike / 18)
		blur.Size = math.clamp(cur.blur + prog * 16 + spike + cur.violence * (math.noise(t * 6, seed, 30) + 0.5) * 10, 0, 56)
		dof.FocusDistance = lerp(14, 3, clamp01(spikeN + cur.violence * 0.5 + prog * 0.7))
		dof.FarIntensity = 0.35 + prog * 0.5

		-- Breathing camera sway + gaze
		local breath = math.sin(t * 1.6 + 0.9 * math.sin(t * 0.37))
		local swayAmt = cur.sway
		-- Dozing head-bob: slow droop, sharp jerk back up, groggy settle
		if t >= nextNod and not fallStart then
			nodStart = t
			nodJerked = false
			nextNod = t + rng:NextNumber(4.5, 7) - prog * 1.5
		end
		local ns = t - nodStart
		local nod = 0
		if ns >= 0 and ns < 3.4 then
			if ns < 1.5 then
				nod = smoothstep(ns / 1.5) -- drifting off
			elseif ns < 1.78 then
				nod = lerp(1, -0.3, smoothstep((ns - 1.5) / 0.28)) -- startled awake
				if not nodJerked then
					nodJerked = true
					spike = math.max(spike, 13)
				end
			else
				local s2 = ns - 1.78
				nod = -0.3 * math.exp(-s2 * 2.6) * math.cos(s2 * 5) -- uneasy overshoot, then settle
			end
		end
		-- Fall at the end: fast drop, head thumps the boards and bounces
		local fallY, fallRoll, fallPitch = 0, 0, 0
		if fallStart then
			local fs = t - fallStart
			local drop = clamp01(fs / 0.2)
			drop = drop * drop
			local bs = math.max(0, fs - 0.2)
			local bounce = math.abs(math.sin(bs * 15)) * math.exp(-bs * 8)
			fallY = -0.42 * drop + 0.26 * bounce
			fallRoll = math.rad(14) * drop
			fallPitch = -math.rad(16) * drop + math.rad(9) * bounce
		end
		local eye = camPos + Vector3.new(
			math.noise(t * 0.5, seed, 1) * 0.16 * swayAmt + math.noise(t * 1.7, seed, 3) * 0.05 * swayAmt,
			breath * 0.07 * swayAmt - nod * 0.2 + fallY + thump * math.sin(t * 60),
			math.noise(t * 0.45, seed, 2) * 0.12 * swayAmt
		)
		local approach = smoothstep((fig.dist - 9) / (figTotal - 9))
		local focus = doorFocus:Lerp(chestPos:Lerp(headPos, approach), approach)
			+ Vector3.new(math.noise(t * 0.3, seed, 11) * 1.2, math.noise(t * 0.3, seed, 12) * 0.8, 0) * (1 - 0.5 * approach)
		local v = cur.violence
		local wobbleP = math.noise(t * 1.1, seed, 43) * math.rad(1.4) * swayAmt
		local wobbleY = math.noise(t * 0.9, seed, 44) * math.rad(1.8) * swayAmt
		local jitter = CFrame.Angles(
			math.noise(t * 9, seed, 40) * math.rad(8) * v + math.rad(1) * breath * swayAmt + wobbleP - nod * math.rad(13) + fallPitch,
			math.noise(t * 9, seed, 41) * math.rad(8) * v + wobbleY,
			math.rad(CONFIG.CameraRoll) + math.rad(2.5) * breath * swayAmt + math.noise(t * 0.8, seed, 45) * math.rad(3.5) * swayAmt + math.noise(t * 7, seed, 42) * math.rad(12) * v + fallRoll
		)
		camera.CFrame = CFrame.lookAt(eye, focus) * jitter

		-- FOV warping
		local fov = cur.fovMid + cur.fovAmp * math.sin(t * 0.55 + 0.5 * math.sin(t * 0.21)) - 1.5 * pulse + v * math.noise(t * 5, seed, 50) * 8
		camera.FieldOfView = math.clamp(fov, 35, 80)

		-- Double vision: worsens over time, spikes on nods and blur spikes
		local dbl = (0.7 + prog * 1.7) + spikeN * 1.2 + math.max(nod, 0) * 0.8 + v * 1.0
		local fovNow = camera.FieldOfView
		for gi, g in ghosts do
			local dir = gi == 1 and 1 or -1
			local yawA = dir * (math.rad(1.8) + math.noise(t * 0.45 + gi * 7, seed, 80 + gi) * math.rad(1.8)) * dbl
			local pitchA = math.noise(t * 0.4 + gi * 3, seed, 83 + gi) * math.rad(1.2) * dbl
			local rollA = math.noise(t * 0.5, seed, 86 + gi) * math.rad(1.3) * dbl
			g.cam.FieldOfView = fovNow * (1 + 0.015 * dbl * dir)
			g.cam.CFrame = camera.CFrame * CFrame.Angles(pitchA, yawA, rollA) * CFrame.new(dir * 0.05 * dbl, 0, 0)
			g.vp.ImageTransparency = math.clamp((gi == 1 and 0.66 or 0.8) - spikeN * 0.15 - prog * 0.12 - v * 0.1, 0.35, 0.9)
			for i, part in figParts do
				local gp = g.map[part.Name]
				if gp then
					gp.CFrame = figCFrames[i]
				end
			end
		end

		-- Haze thickens, clouds and splatters drift
		haze.BackgroundTransparency = clamp01(0.78 - prog * 0.16 - spikeN * 0.08 - math.max(nod, 0) * 0.05 - v * 0.08)
		for _, sm in smudges do
			sm.holder.Position = UDim2.fromScale(sm.x + 0.012 * math.sin(t * sm.speed * 3 + sm.phase), sm.y + 0.01 * math.cos(t * sm.speed * 2.4 + sm.phase))
		end
		for _, c in clouds do
			c.holder.Position = UDim2.fromScale(c.x + 0.05 * math.sin(t * c.speed + c.phase), c.y + 0.04 * math.cos(t * c.speed * 0.8 + c.phase))
		end

		-- Colour: desaturation/contrast dips
		grade.Saturation = cur.sat - spikeN * 0.2 - pulse * 0.05
		grade.Contrast = cur.contrast + pulse * 0.15 - spikeN * 0.1
		grade.Brightness = cur.bright - spikeN * 0.06 + pulse * 0.02
		grade.TintColor = Color3.fromRGB(204 - pulse * 10, 212 - pulse * 12, 226 - pulse * 10)

		-- Eyelids: drowsy drift + heavy blinks + spikes, clamped by the slam override
		if t >= nextBlink then
			blinkStart = t
			nextBlink = t + rng:NextNumber(4, 8)
		end
		local blink = math.sin(clamp01((t - blinkStart) / 0.55) * math.pi)
		local lid = clamp01(cur.lid + 0.05 * math.sin(t * 0.7 + math.sin(t * 0.23)) + 0.05 * math.noise(t * 1.1, seed, 60) + spikeN * 0.12 + pulse * 0.02 + math.max(nod, 0) * 0.28 + prog * 0.1)
		lid = math.max(lid + blink * (1 - lid) * 0.85, lidOverride.Value)
		topLid.Size = UDim2.fromScale(1, lid * 0.5)
		bottomLid.Size = UDim2.fromScale(1, lid * 0.5)
		for _, frame in vignette do
			frame.BackgroundTransparency = 1 - clamp01(cur.vignette + prog * 0.15)
		end

		-- World details
		room.lantern.Brightness = 2.6 + 0.3 * math.noise(t * 7, seed, 20) + 0.08 * math.sin(t * 31)
		local poolSize = lerp(2.6, 4.4, clamp01(t / 45))
		room.pool.Size = Vector3.new(0.03, poolSize, poolSize)
		if sounds.breath then
			sounds.breath.Volume = 0.2 + 0.15 * (breath + 1) * swayAmt
			sounds.breath.PlaybackSpeed = lerp(1, 0.85, weakness)
		end
		if prompt.Visible then
			prompt.TextTransparency = 0.35 + 0.3 * math.sin(t * 3)
		end
	end

	local renderConn = RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[IntroCutscene] " .. tostring(err))
		end
	end)

	---------------------------------------------------------------- dialogue
	local advancePressed = false
	local inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local key, kind = input.KeyCode, input.UserInputType
		if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.ButtonA
			or kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			advancePressed = true
		end
	end)

	local function say(line)
		speakerLabel.Text = line.speaker
		speakerLabel.TextColor3 = line.speaker == "You" and Color3.fromRGB(150, 148, 146) or Color3.fromRGB(170, 170, 175)
		local italic = line.murmur or line.italic
		textLabel.TextTransparency = line.murmur and 0.25 or (line.italic and 0.15 or 0)
		textLabel.Text = italic and ("<i>" .. line.text .. "</i>") or line.text
		textLabel.MaxVisibleGraphemes = 0
		local total = utf8.len(textLabel.ContentText) or #line.text
		local shown, lastTick = 0, 0
		advancePressed = false
		while shown < total do
			local dt = RunService.Heartbeat:Wait()
			if advancePressed then
				advancePressed = false
				break
			end
			local speed = CONFIG.TypeSpeed
			if line.murmur then
				speed = 13 * (0.3 + 1.2 * clamp01(math.noise(t * 2, seed, 70) + 0.5))
			end
			shown += dt * speed
			textLabel.MaxVisibleGraphemes = math.floor(shown)
			if math.floor(shown) >= lastTick + 2 then
				lastTick = math.floor(shown)
				playSound(sounds.typewriter, nil, rng:NextNumber(0.95, 1.1))
			end
		end
		textLabel.MaxVisibleGraphemes = -1
	end

	local function waitAdvance()
		task.wait(0.15)
		advancePressed = false
		prompt.Visible = true
		while not advancePressed do
			task.wait()
		end
		advancePressed = false
		prompt.Visible = false
	end

	---------------------------------------------------------------- sequence
	local finishing = false
	local function runSequence()
		-- Waking on the floor
		fadeBlack(1, 3.2, true)
		setVis("lid", 0.28, 0.5)
		setVis("blur", 4, 0.6)
		task.wait(2.2)

		-- Narration while the first faint footsteps start
		tween(box, TweenInfo.new(0.5), { GroupTransparency = 0 })
		fig.walking = true
		say(INTRO_NARRATION)
		task.wait(2.4)
		tween(box, TweenInfo.new(0.6), { GroupTransparency = 1 })

		while not fig.arrived do
			task.wait()
		end
		setVis("figLean", -0.3, 1.2)
		setVis("figHead", -0.35, 1.2)
		setVis("lid", 0.2, 1)
		setVis("sway", 1.4, 1)
		task.wait(1.2)

		tween(box, TweenInfo.new(0.5), { GroupTransparency = 0 })
		say(DIALOGUE[1])
		waitAdvance()
		setVis("figReach", 0.7, 0.6) -- slowly reaches a hand toward you
		say(DIALOGUE[2])
		waitAdvance()

		-- Your murmur: vision falls apart
		setVis("violence", 0.85, 3)
		setVis("blur", 9, 3)
		setVis("lid", 0.36, 1.5)
		setVis("weakness", 0.25, 1)
		setVis("sat", -0.85, 1)
		say(DIALOGUE[3])
		tween(textLabel, TweenInfo.new(1.4), { TextTransparency = 0.65 })
		task.wait(1.2)
		say(DIALOGUE[4])
		task.wait(1.6)
		setVis("violence", 0.3, 2)

		-- The chuckle
		playSound(sounds.chuckle)
		setVis("figChuckle", 1, 6)
		setVis("figHeadRoll", 0.18, 3)
		say(DIALOGUE[5])
		task.wait(1.4)
		setVis("figChuckle", 0, 4)

		-- Fast fall: your head thumps the floor and everything goes black
		finishing = true
		skipButton.Visible = false
		tween(box, TweenInfo.new(0.2), { GroupTransparency = 1 })
		fallStart = t
		setVis("violence", 0.6, 8)
		setVis("blur", 12, 6)
		task.wait(0.2)
		playSound(sounds.passOut)
		setHaptic(1)
		hapticOffAt = t + 0.3
		spike = 30
		thump = 0.4
		tween(lidOverride, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 0.6 })
		task.wait(0.12)
		tween(lidOverride, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 1 })
		task.wait(0.3)
		fadeBlack(0, 0.1)
		task.wait(0.4)
	end

	local done = Instance.new("BindableEvent")
	local resolved = false
	local function resolve(reason)
		if not resolved then
			resolved = true
			done:Fire(reason)
		end
	end
	local seqThread = task.spawn(function()
		local ok, err = pcall(runSequence)
		if not ok then
			warn("[IntroCutscene] " .. tostring(err))
		end
		resolve("finished")
	end)
	skipButton.Activated:Connect(function()
		if finishing or resolved then
			return
		end
		pcall(task.cancel, seqThread)
		resolve("skipped")
	end)
	local reason = done.Event:Wait()
	done:Destroy()

	if reason == "skipped" then
		fadeBlack(0, 0.3)
	end

	---------------------------------------------------------------- clean up cutscene
	renderConn:Disconnect()
	inputConn:Disconnect()
	setHaptic(0)
	for _, sound in sounds do
		if sound then
			sound:Destroy()
		end
	end
	room.model:Destroy()
	visionGui:Destroy()
	skipGui:Destroy()
	blur:Destroy()
	grade:Destroy()
	dof:Destroy()
	bloom:Destroy()
	lidOverride:Destroy()
	for prop, value in lightSnap do
		pcall(function()
			Lighting[prop] = value
		end)
	end
	if atmosphere then
		atmosphere.Parent = Lighting
	end
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = camSnap.FieldOfView

	task.wait(reason == "skipped" and 0.3 or 0.6)

	---------------------------------------------------------------- title menu
	runTitleMenu(playerGui, fadeBlack, rng)

	---------------------------------------------------------------- spawn + hand back control
	local remote = ReplicatedStorage:WaitForChild(CONFIG.SpawnRemoteName, 2)
	if remote and remote:IsA("RemoteFunction") then
		local ok, err = pcall(remote.InvokeServer, remote)
		if not ok then
			warn("[IntroCutscene] spawn request failed: " .. tostring(err))
		end
	end
	local deadline = os.clock() + 8
	local character = player.Character
	while not (character and character.Parent and character:FindFirstChildOfClass("Humanoid")) and os.clock() < deadline do
		task.wait(0.1)
		character = player.Character
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = camSnap.FieldOfView
	if controls then
		pcall(function()
			controls:Enable()
		end)
	end
	for coreType, enabled in coreSnap do
		if enabled then
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, true)
		end
	end

	fadeBlack(1, 0.9)
	transitionGui:Destroy()
	isPlaying = false
	return true
end

return IntroCutscene
