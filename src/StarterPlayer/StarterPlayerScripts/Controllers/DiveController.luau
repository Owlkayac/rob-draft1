--!strict
-- 「潜る」操作の受け付け(クライアント側)。仕様書 001。
-- E キー(スマホは画面ボタン)を押した/離したことをサーバーにお願いするだけ。
-- 潜れるかどうかの判定は、サーバーが行う。

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local DiveController = {}

local ACTION_NAME = "CrayfishDive"
local BUTTON_TITLE = "潜る"
local REMOTE_WAIT_SECONDS = 10

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

	ContextActionService:BindAction(ACTION_NAME, handle, true, Enum.KeyCode.E)
	ContextActionService:SetTitle(ACTION_NAME, BUTTON_TITLE)
end

return DiveController
