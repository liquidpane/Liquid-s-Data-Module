--[[

   Copyright 2026 liquidpane

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

]]

--!strict

local DEFAULT_WAIT_FOR_DATA_TIME_OUT = 10

export type StoreSettings = {
	UpdateDataRemote: RemoteEvent,
	GetDataRemote: RemoteFunction,
}

export type ValidKey = string
export type ValidValue = string | number | boolean | ValidTable | nil
export type ValidTable = { [string | number]: ValidValue }

export type DataClient = {
	Initialize: (storeSettings: StoreSettings) -> (),
	Get: (key: ValidKey) -> ValidValue,
	HasData: () -> (),
	WaitForData: (timeOut: number?) -> { [ValidKey]: ValidValue }?,
	Subscribe: (key: ValidKey, callback: (value: any) -> ()) -> typeof(newproxy(false)),
	Unsubscribe: (key: ValidKey, subscriptionId: typeof(newproxy(false))) -> (),
}

local storeSettings: StoreSettings
local hasInitialized = false
local profile: { [ValidKey]: ValidValue } = {}
local subscriptions: { [typeof(newproxy(false))]: { Key: ValidKey, Callback: (value: ValidValue) -> () } } = {}

local function throwWarn(warnMessage: string)
	warn("[LPDataClient]: " .. warnMessage)
end

local DataClient = {} :: DataClient

function DataClient.Initialize(p_storeSettings)
	if hasInitialized then
		throwWarn("Cannot initialize multiple times")
		return
	end
	hasInitialized = true

	storeSettings = p_storeSettings

	storeSettings.UpdateDataRemote.OnClientEvent:Connect(function(...)
		for i = 1, select("#", ...), 2 do
			local key = select(i, ...)
			local value = select(i + 1, ...)

			profile[key] = value

			for _, subscription in subscriptions do
				if subscription.Key ~= key then
					continue
				end
				subscription.Callback(value)
			end
		end
	end)

	task.defer(function()
		profile = storeSettings.GetDataRemote:InvokeServer()
	end)
end

function DataClient.Get(key)
	local profile = profile
	if not profile then
		return nil
	end

	return profile[key]
end

function DataClient.WaitForData(p_timeOut)
	local timeOut = p_timeOut or 10

	local startTime = os.clock()
	while profile == nil or next(profile) == nil do
		if os.clock() - startTime > DEFAULT_WAIT_FOR_DATA_TIME_OUT then
			return nil
		end

		task.wait()
	end

	return profile
end

function DataClient.HasData()
	return profile ~= nil
end

function DataClient.Subscribe(key, callback)
	local subscriptionId = newproxy(false)

	subscriptions[subscriptionId] = { ["Key"] = key, ["Callback"] = callback }

	return subscriptionId
end

function DataClient.Unsubscribe(subscriptionId)
	if subscriptions[subscriptionId] == nil then
		return
	end

	subscriptions[subscriptionId] = nil
end

return DataClient
