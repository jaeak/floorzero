-- Holds each player's character until they press [ BEGIN ] on the title menu.
-- Set HOLD_SPAWN_UNTIL_BEGIN = false to keep normal auto-spawning.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HOLD_SPAWN_UNTIL_BEGIN = true
local FALLBACK_SPAWN_SECONDS = 300 -- spawn anyway if a client never presses BEGIN

local remote = Instance.new("RemoteFunction")
remote.Name = "IntroSpawnRequest"
remote.Parent = ReplicatedStorage

if not HOLD_SPAWN_UNTIL_BEGIN then
	remote.OnServerInvoke = function()
		return false
	end
	return
end

Players.CharacterAutoLoads = false
local spawned = {}

local function spawnPlayer(player)
	if spawned[player] or not player.Parent then
		return false
	end
	spawned[player] = true
	player:LoadCharacter()
	return true
end

remote.OnServerInvoke = spawnPlayer

local function onPlayerAdded(player)
	-- With auto-loading off we handle respawning after death ourselves
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid")
		humanoid.Died:Connect(function()
			task.wait(Players.RespawnTime)
			if player.Parent and player.Character == character then
				player:LoadCharacter()
			end
		end)
	end)
	task.delay(FALLBACK_SPAWN_SECONDS, spawnPlayer, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerRemoving:Connect(function(player)
	spawned[player] = nil
end)
