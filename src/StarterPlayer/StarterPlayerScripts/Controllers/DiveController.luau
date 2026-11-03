--!strict
-- 「潜る」操作の受け付け(クライアント側)。仕様書 001。
-- E キー(スマホは画面ボタン)を押した/離したことをサーバーにお願いするだけ。
-- 潜れるかどうかの判定は、サーバーが行う。
-- 仕様書 016:やくわりが農家さん(Player の Attribute "Role" が "Farmer")のときは、潜らないので、画面のボタンもキーも出さない(取り外す)。
--   ザリガニに戻ったら、また出す。サーバーも、農家さんの潜る要求は無視する。
--   スタートメニューの間(RoundState が "Menu")も、同じく、出さない(メニューの上に、ボタンが残らないように)。メニューを出たら、やくわりに合わせて、また取り付ける。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local DiveController = {}

local ACTION_NAME = "CrayfishDive"
local BUTTON_TITLE = "潜る"
local REMOTE_WAIT_SECONDS = 10
local ROLE_ATTRIBUTE = "Role" -- SetupService が Player につける「やくわり」
local ROLE_FARMER = "Farmer"
local STATE_MENU = "Menu" -- スタートメニューの間(RoundState)

local actionBound = false -- いま操作(キー・ボタン)を取り付けているか
local inMenuState = true -- いまスタートメニューの間か(最初の知らせが届くまでは、メニューと同じ扱い)

-- いまのやくわりが農家さんか
local function isFarmerRole(): boolean
	return Players.LocalPlayer:GetAttribute(ROLE_ATTRIBUTE) == ROLE_FARMER
end

function DiveController.Start()
	local found = ReplicatedStorage:WaitForChild(Config.DiveRemoteName, REMOTE_WAIT_SECONDS)
	if not found or not found:IsA("RemoteEvent") then
		warn(`[DiveController] {Config.DiveRemoteName} が見つかりません。潜る操作は使えません。`)
		return
	end
	local remote = found

	local function handle(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
		if inputState == Enum.UserInputState.Begin then
			remote:FireServer(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			remote:FireServer(false)
		end
		return Enum.ContextActionResult.Sink
	end

	-- やくわりに合わせて、操作を取り付ける・取り外す(二重に取り付けない)
	local function refreshBinding()
		local shouldBind = (not isFarmerRole()) and (not inMenuState) -- 農家さんのときと、メニューの間は、取り付けない
		if shouldBind == actionBound then
			return
		end
		actionBound = shouldBind
		if shouldBind then
			ContextActionService:BindAction(ACTION_NAME, handle, true, Enum.KeyCode.E)
			ContextActionService:SetTitle(ACTION_NAME, BUTTON_TITLE)
		else
			ContextActionService:UnbindAction(ACTION_NAME) -- 画面のボタンも消える
		end
	end

	refreshBinding()
	Players.LocalPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(refreshBinding)

	-- スタートメニューの間は、操作を取り外す。RoundState が見つからないときは、これまでどおり(メニューではない扱い)
	task.spawn(function()
		local stateFound = ReplicatedStorage:WaitForChild(Config.RoundStateRemoteName, REMOTE_WAIT_SECONDS)
		if not stateFound or not stateFound:IsA("RemoteEvent") then
			inMenuState = false
			refreshBinding()
			return
		end
		stateFound.OnClientEvent:Connect(function(state: unknown, _stageName: unknown, _remaining: unknown)
			if typeof(state) ~= "string" then
				return
			end
			inMenuState = (state == STATE_MENU)
			refreshBinding()
		end)
	end)
end

return DiveController
