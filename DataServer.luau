--[[

   Copyright 2026 liquidpane

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

]]

--!strict

local CAN_SET_KEYS_NOT_INCLUDED_IN_TEMPLATE = false
local DATA_RETRIEVAL_TIMEOUT = 120
local EDITING_SESSION_TIMEOUT = 120
local DEFAULT_WAIT_FOR_DATA_TIME_OUT = 10
local STUDIO_GAME_CLOSE_YIELD = 2
local AUTO_SAVE_INTERVAL = 30
local SESSION_LOCK_KEY_NAME = "SessionLock"
local SESSION_LOCK_PLACE_KEY_NAME = "SessionLockPlace"
local SESSION_LOCK_DATE_KEY_NAME = "SessionLockDate"
local SESSION_LOCK_TIME_FORGIVENESS = 120
local PLAYER_KICK_MESSAGE = "A data issue occured, please rejoin!"

export type ValidKey = string
export type ValidValue = string | number | boolean | ValidTable | nil
export type ValidTable = { [string | number]: ValidValue }

export type StoreSettings = {
	Name: string,
	Template: { [ValidKey]: ValidValue },
}

export type SyncSettings = {
	UpdateDataRemote: RemoteEvent,
	GetDataRemote: RemoteFunction,
}

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local placeId = game.PlaceId
local sessionId = game.JobId
local hasInitialized = false
local storeSettings: StoreSettings
local syncSettings: SyncSettings?
local profiles: { [Player]: { [ValidKey]: ValidValue } } = {}
local hasProfileBeenChanged: { [Player]: boolean? } = {}
local dataStore: DataStore
local keysBeingEdited: { [Player]: { [ValidKey]: thread } } = {}
local subscriptions: { [Player]: { [typeof(newproxy(false))]: { Key: ValidKey, Callback: (value: ValidValue) -> () } } } =
	{}

local function throwWarn(warnMessage: string)
	warn("[DataServer]: " .. warnMessage)
end

local function dictionaryUnpack(t: { [any]: any }): ...any
	local result = {}

	for k, v in pairs(t) do
		table.insert(result, k)
		table.insert(result, v)
	end

	return table.unpack(result)
end

local function deepMerge<A, B>(target: A & { [any]: any }, source: B & { [any]: any }): A & B
	local result = {}

	for key, value in pairs(target) do
		if type(value) == "table" then
			result[key] = deepMerge(value, {})
		else
			result[key] = value
		end
	end

	for key, value in pairs(source) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = deepMerge(result[key], value)
		else
			if type(value) == "table" then
				result[key] = deepMerge(value, {})
			else
				result[key] = value
			end
		end
	end

	return result
end

local function compareValues(v1: any, v2: any): boolean
	if v1 == v2 then
		return true
	end

	if type(v1) ~= "table" or type(v2) ~= "table" then
		return false
	end

	for k, v in pairs(v1) do
		if not compareValues(v, v2[k]) then
			return false
		end
	end

	for k in pairs(v2) do
		if v1[k] == nil then
			return false
		end
	end

	return true
end

local function deepClone<T>(original: T & { [any]: any }): T
	local clone = table.clone(original)

	for key, value in pairs(clone) do
		if type(value) == "table" then
			clone[key] = deepClone(value)
		end
	end

	return clone
end

local function waitForBudget()
	local budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	while budget < 1 do
		budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		task.wait(0.5)
	end
end

export type DataServer = {
	Initialize: <T>(storeSettings: StoreSettings, syncSettings: SyncSettings?) -> (),
	Edit: (player: Player, callback: ({ [ValidKey]: ValidValue }) -> boolean?, key1: ValidKey, ...ValidKey) -> boolean?,
	Get: (player: Player, key: ValidKey) -> ValidValue,
	WaitForData: (player: Player, timeOut: number?) -> { [ValidKey]: ValidValue }?,
	HasData: (player: Player) -> boolean,
	Subscribe: (player: Player, key: ValidKey, callback: (value: any) -> ()) -> typeof(newproxy(false)),
	Unsubscribe: (player: Player, subscriptionId: typeof(newproxy(false))) -> (),
}

local function registerPlayer(player: Player)
	if profiles[player] then
		return
	end
	profiles[player] = {}
	subscriptions[player] = {}
	keysBeingEdited[player] = {}
	hasProfileBeenChanged[player] = false

	local dataStoreKey = tostring(player.UserId)

	local success, retrievedData
	local startTime = os.time()
	repeat
		waitForBudget()

		local failedSessionLock = false

		local errorMessage
		success, errorMessage = pcall(function()
			dataStore:UpdateAsync(dataStoreKey, function(currentData): { [ValidKey]: ValidValue }?
				local unix = DateTime.now().UnixTimestamp

				if currentData == nil then
					return {
						[SESSION_LOCK_KEY_NAME] = sessionId,
						[SESSION_LOCK_PLACE_KEY_NAME] = placeId,
						[SESSION_LOCK_DATE_KEY_NAME] = unix,
					}
				end

				local sessionLock = currentData[SESSION_LOCK_KEY_NAME]
				local sessionLockDate = currentData[SESSION_LOCK_DATE_KEY_NAME] :: number
				if
					sessionLock
					and sessionLock ~= sessionId
					and unix - sessionLockDate < SESSION_LOCK_TIME_FORGIVENESS
				then
					failedSessionLock = true
					return nil
				end

				retrievedData = currentData

				currentData[SESSION_LOCK_KEY_NAME] = sessionId
				currentData[SESSION_LOCK_PLACE_KEY_NAME] = placeId
				currentData[SESSION_LOCK_DATE_KEY_NAME] = unix

				return currentData
			end)
		end)

		if failedSessionLock then
			throwWarn("Key " .. dataStoreKey .. " has failed session lock check")
			player:Kick(PLAYER_KICK_MESSAGE)
			return
		end

		if not success then
			throwWarn("Error when loading data for key " .. dataStoreKey .. ", error: " .. errorMessage :: string)
			task.wait(3)
		end
	until success or os.time() - startTime >= DATA_RETRIEVAL_TIMEOUT or player.Parent == nil

	if not success then
		throwWarn("All GetAsync attempts failed(timeout) for key: " .. dataStoreKey)
		player:Kick(PLAYER_KICK_MESSAGE)
		return
	end

	if not profiles[player] then
		return
	end

	if retrievedData == nil then
		profiles[player] = deepClone(storeSettings.Template)
		return
	end

	if type(retrievedData) ~= "table" then
		throwWarn(
			"GetAsync for key "
				.. dataStoreKey
				.. " returned data which is not a table, setting players profile to the template"
		)
		profiles[player] = deepClone(storeSettings.Template)
		return
	end

	for key, value in pairs(storeSettings.Template) do
		local retrievedValue = retrievedData[key]

		if retrievedValue == nil then
			profiles[player][key] = if type(value) == "table" then deepClone(value :: { [any]: any }) else value
		else
			profiles[player][key] = retrievedValue
		end
	end
end

local function unregisterPlayer(player: Player)
	if not profiles[player] then
		return
	end

	local dataStoreKey = tostring(player.UserId)

	keysBeingEdited[player] = nil
	subscriptions[player] = nil

	local profile = profiles[player]
	profiles[player] = nil

	if hasProfileBeenChanged[player] == nil then
		hasProfileBeenChanged[player] = nil
		return
	end

	if profile == nil or next(profile) == nil then
		hasProfileBeenChanged[player] = nil
		return
	end

	local dataToSave = {}
	if hasProfileBeenChanged[player] then
		for key, value in pairs(profile) do
			local templateValue = storeSettings.Template[key]

			if templateValue == nil and not CAN_SET_KEYS_NOT_INCLUDED_IN_TEMPLATE then
				throwWarn(
					"Data contained a key that is not included in the data template, if this is intentional set CAN_SET_KEYS_NOT_INCLUDED_IN_TEMPLATE to true"
				)
				continue
			end

			if compareValues(value, templateValue) then
				continue
			end

			dataToSave[key] = value
		end
	end

	hasProfileBeenChanged[player] = nil

	local success
	local startTime = os.time()
	repeat
		waitForBudget()
		local errorMessage = ""
		success, errorMessage = pcall(function()
			dataStore:UpdateAsync(tostring(player.UserId), function(currentData): { [ValidKey]: ValidValue }?
				if currentData == nil or type(currentData) ~= "table" then
					return dataToSave
				end

				if not currentData[SESSION_LOCK_KEY_NAME] or currentData[SESSION_LOCK_KEY_NAME] ~= sessionId then
					return nil
				end

				local isCurrentDataSafe = currentData ~= nil and type(currentData) == "table"

				local returnData: { [ValidKey]: ValidValue } = if isCurrentDataSafe
					then deepMerge(currentData, dataToSave)
					else deepClone(dataToSave)

				returnData[SESSION_LOCK_KEY_NAME] = nil
				returnData[SESSION_LOCK_PLACE_KEY_NAME] = nil
				returnData[SESSION_LOCK_DATE_KEY_NAME] = nil

				return returnData
			end)
		end)

		if not success then
			throwWarn(
				"UpdateAsync failed for key: " .. dataStoreKey .. " with error message: " .. errorMessage :: string
			)
			task.wait(3)
		end
	until success or os.time() - startTime >= DATA_RETRIEVAL_TIMEOUT

	if not success then
		throwWarn("All UpdateAsync attempts failed(timeout) for key: " .. dataStoreKey)
	end
end

local DataServer = {} :: DataServer

function DataServer.Initialize(p_storeSettings, p_syncSettings)
	if hasInitialized then
		throwWarn("Cannot initialize multiple times")
		return
	end
	hasInitialized = true

	storeSettings = p_storeSettings
	syncSettings = p_syncSettings

	dataStore = DataStoreService:GetDataStore(storeSettings.Name)

	profiles = {}

	Players.PlayerAdded:Connect(registerPlayer)
	for _, player in Players:GetPlayers() do
		task.defer(registerPlayer, player)
	end

	Players.PlayerRemoving:Connect(unregisterPlayer)
	local autoSaveThread = task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL)
			for player, profile in profiles do
				if profile and next(profile) and hasProfileBeenChanged[player] then
					local dataToSave = {}
					for key, value in pairs(profile) do
						local templateValue = storeSettings.Template[key]
						if templateValue == nil and not CAN_SET_KEYS_NOT_INCLUDED_IN_TEMPLATE then
							continue
						end
						if compareValues(value, templateValue) then
							continue
						end
						dataToSave[key] = value
					end

					waitForBudget()
					local success, errorMessage = pcall(function()
						dataStore:UpdateAsync(
							tostring(player.UserId),
							function(currentData): { [ValidKey]: ValidValue }?
								if currentData == nil or type(currentData) ~= "table" then
									return nil
								end
								if currentData[SESSION_LOCK_KEY_NAME] ~= sessionId then
									return nil
								end

								local returnData = deepMerge(currentData, dataToSave)
								returnData[SESSION_LOCK_DATE_KEY_NAME] = DateTime.now().UnixTimestamp
								return returnData :: { [ValidKey]: ValidValue }
							end
						)
					end)

					if not success then
						throwWarn("Auto-save failed for player " .. player.Name .. ": " .. tostring(errorMessage))
					end
				end
			end
		end
	end)

	game:BindToClose(function()
		task.cancel(autoSaveThread)
		
		if RunService:IsStudio() then
			task.wait(STUDIO_GAME_CLOSE_YIELD)
			return
		end

		local players = Players:GetPlayers()
		local playersLeft = #players

		for _, player in players do
			coroutine.wrap(function()
				unregisterPlayer(player)
				playersLeft -= 1
			end)()
		end
	end)

	if syncSettings then
		syncSettings.GetDataRemote.OnServerInvoke = function(player: Player)
			local profile = DataServer.WaitForData(player, 60 * 5)

			return profile
		end
	end
end

function DataServer.Edit(player, callback, ...)
	local profile = profiles[player]
	if not profile or next(profile) == nil then
		return false
	end

	local data = {}
	local seen = {}
	for i = 1, select("#", ...) do
		local validKey = select(i, ...)
		if seen[validKey] then
			throwWarn("EditData issue, same key was passed in twice")
			continue
		end
		seen[validKey] = true

		local playerKeysBeingEdited = keysBeingEdited[player]
		if not playerKeysBeingEdited then
			break
		end

		while playerKeysBeingEdited[validKey] ~= nil do
			task.wait()
		end
		playerKeysBeingEdited[validKey] = coroutine.running()

		local value = profile[validKey]

		data[validKey] = if type(value) == "table" then deepClone(value) else value
	end

	local success, shouldSave
	local thread = task.spawn(function()
		success, shouldSave = xpcall(function()
			return callback(data)
		end, function(errorMessage: string)
			throwWarn("EditData issue, error message: " .. errorMessage)
		end)
	end)

	local startTime = os.time()
	while success == nil and os.time() - startTime < EDITING_SESSION_TIMEOUT do
		task.wait()
	end

	if success and shouldSave then
		for key, value in data do
			if profiles[player] == nil then
				break
			end

			profile[key] = value
			local subscriptions = subscriptions[player]
			if subscriptions then
				for _, subscription in subscriptions do
					if subscription.Key ~= key then
						continue
					end
					subscription.Callback(value)
				end
			end
		end

		if profiles[player] == nil then
			return false
		end

		hasProfileBeenChanged[player] = true
	else
		task.cancel(thread)
	end

	if syncSettings and success and shouldSave then
		syncSettings.UpdateDataRemote:FireClient(player, dictionaryUnpack(data))
	end

	for i = 1, select("#", ...) do
		local validKey = select(i, ...)

		local playerKeysBeingEdited = keysBeingEdited[player]
		if playerKeysBeingEdited == nil then
			break
		end

		if playerKeysBeingEdited and playerKeysBeingEdited[validKey] ~= coroutine.running() then
			continue
		end
		playerKeysBeingEdited[validKey] = nil
	end
	
	return shouldSave
end

function DataServer.Get(player, key)
	local profile = profiles[player]
	if profile == nil then
		return nil
	end

	return profile[key]
end

function DataServer.WaitForData(player, p_timeOut)
	local timeOut = p_timeOut or DEFAULT_WAIT_FOR_DATA_TIME_OUT

	local startTime = os.clock()
	while profiles[player] == nil or next(profiles[player]) == nil do
		if os.clock() - startTime > timeOut then
			return nil
		end

		task.wait()
	end

	return profiles[player]
end

function DataServer.HasData(player)
	return profiles[player] ~= nil
end

function DataServer.Subscribe(player, key, callback)
	local playerSubscriptions = subscriptions[player]

	if playerSubscriptions == nil then
		return
	end

	local subscriptionId = newproxy(false)

	playerSubscriptions[subscriptionId] = { ["Key"] = key, ["Callback"] = callback }

	return subscriptionId
end

function DataServer.Unsubscribe(player, subscriptionId)
	local playerSubscriptions = subscriptions[player]
	if playerSubscriptions == nil then
		return
	end

	if playerSubscriptions[subscriptionId] == nil then
		return
	end

	playerSubscriptions[subscriptionId] = nil
end

return DataServer
