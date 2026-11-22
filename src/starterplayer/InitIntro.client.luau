-- Plays the intro cutscene + title menu when the player joins.
-- Re-trigger any time while testing with: require(game.ReplicatedStorage.IntroCutscene).Play()
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local IntroCutscene = require(ReplicatedStorage:WaitForChild("IntroCutscene"))
IntroCutscene.Play()
