--!strict
-- 画面(UI)をコードで作って、サーバーからの RoundState で表示を更新する。仕様書 004 の 2。
-- 画面は表示だけ。「もう一度」は、サーバーにお願いするだけで、判定はサーバーが行う。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local GuiController = {}

local REMOTE_WAIT_SECONDS = 10
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local PANEL_COLOR = Color3.fromRGB(30, 30, 30)
local BUTTON_COLOR = Color3.fromRGB(70, 150, 70)
local TEXT_FONT = Enum.Font.GothamBold

local TEXT_CAUGHT = "つかまった"
local TEXT_CLEARED = "稲刈りの日まで生き延びた!"
local TEXT_RESTART = "もう一度"

-- 文字だけの TextLabel を作る共通の関数
local function makeLabel(name: string, size: UDim2, position: UDim2, textSize: number, parent: Instance): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.TextColor3 = TEXT_COLOR
	label.TextStrokeTransparency = 0.5
	label.Font = TEXT_FONT
	label.TextSize = textSize
	label.Text = ""
	label.Parent = parent
	return label
end

-- 画面を作る。更新に使う部品だけを返す
local function buildGui(): (TextLabel, TextLabel, Frame, TextLabel, TextButton)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RoundGui"
	screenGui.ResetOnSpawn = false -- 生まれ直しても画面を消さない
	screenGui.IgnoreGuiInset = false

	-- 画面の上の真ん中:残り時間と段階の名前
	local topPanel = Instance.new("Frame")
	topPanel.Name = "TopPanel"
	topPanel.AnchorPoint = Vector2.new(0.5, 0)
	topPanel.Position = UDim2.new(0.5, 0, 0, 10)
	topPanel.Size = UDim2.fromOffset(240, 80)
	topPanel.BackgroundColor3 = PANEL_COLOR
	topPanel.BackgroundTransparency = 0.4
	topPanel.Parent = screenGui
	local timeLabel = makeLabel("TimeLabel", UDim2.new(1, 0, 0.55, 0), UDim2.new(0, 0, 0, 0), 36, topPanel)
	local stageLabel = makeLabel("StageLabel", UDim2.new(1, 0, 0.45, 0), UDim2.new(0, 0, 0.55, 0), 24, topPanel)

	-- 画面の真ん中:つかまった/クリアの表示と、ボタン
	local overlay = Instance.new("Frame")
	overlay.Name = "ResultPanel"
	overlay.AnchorPoint = Vector2.new(0.5, 0.5)
	overlay.Position = UDim2.fromScale(0.5, 0.5)
	overlay.Size = UDim2.fromOffset(420, 240)
	overlay.BackgroundColor3 = PANEL_COLOR
	overlay.BackgroundTransparency = 0.3
	overlay.Visible = false
	overlay.Parent = screenGui
	local messageLabel = makeLabel("MessageLabel", UDim2.new(1, 0, 0.5, 0), UDim2.new(0, 0, 0.05, 0), 40, overlay)
	messageLabel.TextWrapped = true

	local button = Instance.new("TextButton")
	button.Name = "RestartButton"
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, 0, 0.6, 0)
	button.Size = UDim2.fromOffset(240, 70) -- スマホでも押しやすい大きさ
	button.BackgroundColor3 = BUTTON_COLOR
	button.TextColor3 = TEXT_COLOR
	button.Font = TEXT_FONT
	button.TextSize = 32
	button.Text = TEXT_RESTART
	button.Parent = overlay

	screenGui.Parent = playerGui
	return timeLabel, stageLabel, overlay, messageLabel, button
end

-- 秒を「分:秒」の文字にする
local function formatTime(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

function GuiController.Start()
	local stateFound = ReplicatedStorage:WaitForChild(Config.RoundStateRemoteName, REMOTE_WAIT_SECONDS)
	local restartFound = ReplicatedStorage:WaitForChild(Config.RestartRemoteName, REMOTE_WAIT_SECONDS)
	if not stateFound or not stateFound:IsA("RemoteEvent") then
		warn(`[GuiController] {Config.RoundStateRemoteName} が見つかりません。画面は更新されません。`)
		return
	end
	if not restartFound or not restartFound:IsA("RemoteEvent") then
		warn(`[GuiController] {Config.RestartRemoteName} が見つかりません。「もう一度」は使えません。`)
		return
	end
	local stateRemote = stateFound
	local restartRemote = restartFound

	local timeLabel, stageLabel, overlay, messageLabel, button = buildGui()

	button.Activated:Connect(function()
		restartRemote:FireServer() -- お願いを送るだけ。やり直すかはサーバーが決める
	end)

	stateRemote.OnClientEvent:Connect(function(state: unknown, stageName: unknown, remaining: unknown)
		if typeof(state) ~= "string" or typeof(stageName) ~= "string" or typeof(remaining) ~= "number" then
			return
		end
		timeLabel.Text = formatTime(remaining)
		stageLabel.Text = stageName
		if state == "Caught" then
			messageLabel.Text = TEXT_CAUGHT
			overlay.Visible = true
		elseif state == "Cleared" then
			messageLabel.Text = TEXT_CLEARED
			overlay.Visible = true
		else
			overlay.Visible = false
		end
	end)
end

return GuiController
