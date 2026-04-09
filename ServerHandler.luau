--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

--// ModuleLoader //--
local ModuleLoader = require(ReplicatedStorage.ClientModules.Shared.ModuleLoader)

--// Modules //--
local CountdownHandler = ModuleLoader:Load("CountdownHandler")
local PlayerHandler = ModuleLoader:Load("PlayerHandler")
local SetOwnership = ModuleLoader:Load("SetOwnership")
local PlayerLogger = ModuleLoader:Load("PlayerLogger")
local DataHandler = ModuleLoader:Load("DataHandler")
local Generation = ModuleLoader:Load("Generation")
local MapLoader = ModuleLoader:Load("MapLoader")
local MapVote = ModuleLoader:Load("MapVote")
local Utility = ModuleLoader:Load("Utility")
local Ragdoll = ModuleLoader:Load("Ragdoll")
local Network = ModuleLoader:Load("Network")
local Config = ModuleLoader:Load("Config")

--// Variables //--
local GameValues = ReplicatedStorage.GameValues

local IntermissionValue = GameValues.StringValues.Intermission
local GamemodeString = GameValues.StringValues.Gamemode
local RoundValue = GameValues.StringValues.Round
local RoundActiveValue = GameValues.BoolValue.RoundActive
local MapValue = GameValues.ObjectValues.CurrentMap

local CurrentMaps = workspace.Maps

--// Main table that keeps all round and gamemode data.
--// CurrentGamemode is the gamemode running right now.
--// NextRoundGamemode is used when a gamemode could not run on the selected map,
--// so it gets saved and forced next round.
--// RoundCounter is used for deciding when special gamemodes should appear.
--// GamemodeHistory stores recently played gamemodes so the same one is not picked again.
--// GamemodeModules stores every loaded gamemode (module) except the default one.
local ServerHandler = {
	CurrentGamemode = nil,
	NextRoundGamemode = nil,

	RoundCounter = 0,

	GamemodeHistory = {},
	GamemodeModules = {},
}

--// This runs right before the round fully starts.
--// First it waits a moment so every player has time to be notified.
--// Then it removes ragdolls from everybody since players may still be ragdolled from last round.
--// Finally it lets the current gamemode add any needed tags to players.
--// The tags are used by abilities, UI, and round checks.
local function AddTagsAndPrepare()
	task.wait(1)
	Ragdoll.UnragdollEveryone()

	ServerHandler.CurrentGamemode.AddTags()
end

--// Loads every gamemode module from script.Modes
--// The module named "Default" is stored separately because it is the main gamemode.
--// Every other module gets inserted into GamemodeModules so they can be randomly chosen later.
--// pcall is used if a module breaks so it doesn't stop the break script.
--// Each loaded module also gets its Name set to the module's actual name.
function ServerHandler:LoadGamemodes()
	self.DefaultGamemode = nil
	self.GamemodeModules = {}

	for _, Module in script.Modes:GetChildren() do
		if Module:IsA("ModuleScript") then
			local Success, Gamemode = pcall(require, Module)

			if Success and type(Gamemode) == "table" then
				Gamemode.Name = Module.Name

				if Module.Name == "Default" then
					self.DefaultGamemode = Gamemode
				else
					table.insert(self.GamemodeModules, Gamemode)
				end
			end
		end
	end

	--// The game cannot continue without a default gamemode.
	if not self.DefaultGamemode then
		error("Default gamemode not found!")
	end

	--// Warn if there are no extra gamemodes loaded.
	if #self.GamemodeModules == 0 then
		warn("No additional gamemodes found, only default will be available")
	end
end

--// Picks which gamemode should run this round.
--// If NextRoundGamemode exists, that one is forced first.
--// Otherwise it may use the default gamemode or a random extra gamemode.
--// The game only uses random gamemodes every few rounds unless AlwaysGamemodes is enabled.
--// GamemodeHistory is used so recently played gamemodes are skipped.
function ServerHandler:SelectRandomGamemode()
	--// Force a saved gamemode from the previous round if needed.
	 --> Since some maps do not allow certain gamemodes so that way we won't reset the counter we'll just save the gamemode next time for a map that does allow it.
	if self.NextRoundGamemode then
		self.CurrentGamemode = self.NextRoundGamemode
		self.NextRoundGamemode = nil
		return
	end

	--// If there are no extra gamemodes, always use default.
	if #self.GamemodeModules == 0 then
		self.CurrentGamemode = self.DefaultGamemode
		return
	end

	--// Every 3 rounds there is a chance to use a special gamemode.
	local UseRandomGamemode = Config.AlwaysGamemodes or (self.RoundCounter % 3 == 0 and math.random() <= 0.7)

	if not UseRandomGamemode then
		self.CurrentGamemode = self.DefaultGamemode
		return
	end

	local Available = {}

	--// Build a list of gamemodes that have not been played recently.
	for _, Gamemode in self.GamemodeModules do
		if not table.find(self.GamemodeHistory, Gamemode.Name) then
			table.insert(Available, Gamemode)
		end
	end

	--// If every gamemode was recently played, clear the history and allow all of them again.
	if #Available == 0 then
		self.GamemodeHistory = {}
		Available = self.GamemodeModules
	end

	--// Pick one random gamemode from the allowed list.
	self.CurrentGamemode = Available[math.random(#Available)]
	table.insert(self.GamemodeHistory, self.CurrentGamemode.Name)

	--// Only keep the last 2 played gamemodes in memory.
	 --> Because by the time you've played 2 gamemodes a bunch of time would have passed so we allow more gamemodes to be chosen again.
	if #self.GamemodeHistory > 2 then
		table.remove(self.GamemodeHistory, 1)
	end
end

--// Starts the intermission between rounds.
--// During this time the game waits until enough non-AFK players are in the server.
--// Once there are enough players, the intermission countdown begins and the clients are notified.
--// When the countdown ends it automatically starts the next round.
function ServerHandler.StartIntermission()
	PlayerLogger:ClearAllCache()

	RoundActiveValue.Value = false

	--// Keep checking until enough active players are in the game.
	repeat
		local ActivePlayers = 0

		for _, Player in Players:GetPlayers() do
			if not Utility.IsPlayerAFK(Player) then
				ActivePlayers += 1
			end
		end

		if ActivePlayers < Config.MinPlayers then
			IntermissionValue.Value = "not enough"
			task.wait(5)
		else
			break
		end
	until false

	Network:FireAllClients("IntermissionStart")

	IntermissionValue.Value = tostring(Config.IntermissionDuration)

	CountdownHandler:StartCountdown("Intermission", Config.IntermissionDuration, IntermissionValue)

	--// After the countdown ends, the value changes to show that voting is starting.
	 --> Side note: the IntermissionValue has a .Changed event connected to every client so that's how they know.
	IntermissionValue.Value = "vote"

	ServerHandler.StartRound()
end

--// Starts a new round.
--// This function handles:
--// 1. Picking a gamemode
--// 2. Checking player count
--// 3. Cleaning old UI
--// 4. Voting and loading a map
--// 5. Making sure the map works with the chosen gamemode
--// 6. Giving players roles
--// 7. Starting the actual gamemode
function ServerHandler.StartRound()
	ServerHandler.RoundCounter += 1

	ServerHandler:SelectRandomGamemode()

	local AllPlayers = Players:GetPlayers()

	--// If there are not enough players anymore, go back to intermission.
	if #AllPlayers < Config.MinPlayers then
		ServerHandler.StartIntermission()
		return
	end

	--// Remove leftover UI from the previous round.
	for _, Player in AllPlayers do
		if Player and Player.Character then
			PlayerHandler.CleanupPlayerUI(Player)
		end
	end

	--// Start map voting while blocking the lobby from being chosen.
	 --> lobby is technically considered a map since it's a model inside the Maps folder so that's why we're excluding it.
	local SelectedMap = MapVote:StartVoting({"Lobby"})

	--// If no map was chosen, stop everything and go back to intermission.
	if not SelectedMap then
		MapVote:CleanupVotingUI()
		return ServerHandler.StartIntermission()
	end

	MapVote:CleanupVotingUI()

	--// Try to load the selected map.
	--// If it somehow fails it goes back to intermission.
	if not MapLoader.LoadMap(SelectedMap) then
		return ServerHandler.StartIntermission()
	end

	--// Some gamemodes may not work on some maps.
	--// If that happens, save the current gamemode for next round and use the default instead.
	local GamemodeConfig = Config[ServerHandler.CurrentGamemode.Name]

	if GamemodeConfig and GamemodeConfig.BlockedMaps then
		if table.find(GamemodeConfig.BlockedMaps, SelectedMap.Name) then
			ServerHandler.NextRoundGamemode = ServerHandler.CurrentGamemode
			ServerHandler.CurrentGamemode = ServerHandler.DefaultGamemode
		end
	end

	--// Let the gamemode assign survivor, hunter, infector, or other roles.
	--// If role assignment fails, cancel the round.
	if not ServerHandler.CurrentGamemode.AssignRoles() then
		return ServerHandler.StartIntermission()
	end

	GamemodeString.Value = ServerHandler.CurrentGamemode.Name

	RoundActiveValue.Value = true
	RoundValue.Value = tostring(ServerHandler.CurrentGamemode.RoundDuration)

	AddTagsAndPrepare()

	--// Some gamemodes need buttons to be generated around the map.
	if Config[ServerHandler.CurrentGamemode.Name].SpawnButtons then
		Generation:GenerateButtons(tostring(SelectedMap.Name), 15)
	end

	--// Finally start the gamemode logic itself.
	ServerHandler.CurrentGamemode.Start()
end

--// Ends the current round and resets the game back to the lobby.
--// It notifies players that the round ended, cleans the map, clears ability data,
--// stops the current gamemode, and then starts a new intermission.
function ServerHandler.EndRound()
	RoundActiveValue.Value = false

	for _, Player in Players:GetPlayers() do
		--// Skip players that are not marked as being in the round.
		if Player and Player.Character and not Player.Character:HasTag("InGame") then
			continue
		end

		Network:FireClient(Player, "RoundEnded")
	end

	task.wait(1)

	MapLoader.Clean()
	MapLoader.SendToLobby()

	DataHandler.ClearAbilityCache()

	ServerHandler.CurrentGamemode.End()

	ServerHandler.StartIntermission()
end

--// Returns the role name for a player based on the current gamemode.
--// Different gamemodes use different names for the enemy role.
--// Default and LightsOut use Hunter.
--// Infection uses Infector.
function ServerHandler.GetRole(Player)
	if ServerHandler.CurrentGamemode and (ServerHandler.CurrentGamemode.Name == "Default" or ServerHandler.CurrentGamemode.Name == "LightsOut") then
		if table.find(ServerHandler.CurrentGamemode.Survivors, Player) then
			return "Survivor"
		else
			return "Hunter"
		end
	elseif ServerHandler.CurrentGamemode and ServerHandler.CurrentGamemode.Name == "Infection" then
		if table.find(ServerHandler.CurrentGamemode.Survivors, Player) then
			return "Survivor"
		else
			return "Infector"
		end
	else
		return false
	end
end

--// Sets up everything the server needs when this module first starts.
--// It creates a network callback so clients can ask for the survivor list.
--// Then it loads gamemodes, creates the collision group used by player characters,
--// starts network ownership handling, waits a little, and begins the first intermission.
function ServerHandler:ServerInit()
	--// Lets clients request the current survivor list from the server.
	Network:OnServerInvoke("GetSurvivor", function()
		return ServerHandler.CurrentGamemode and table.unpack(ServerHandler.CurrentGamemode.Survivors) or nil
	end)

	ServerHandler:LoadGamemodes()

	--// Prevent characters from colliding with each other.
	PhysicsService:RegisterCollisionGroup("PlayerCharacters")
	PhysicsService:CollisionGroupSetCollidable("PlayerCharacters", "PlayerCharacters", false)

	SetOwnership.Start()

	task.wait(5)

	ServerHandler.StartIntermission()
end

return ServerHandler