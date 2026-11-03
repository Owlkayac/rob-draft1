--!strict
-- 画面(UI)をコードで作って、サーバーからの RoundState で表示を更新する。仕様書 004 の 2。
-- 画面は表示だけ。「もう一度」「メニューへ」は、サーバーにお願いするだけで、判定はサーバーが行う。
-- 状態が "Menu"(スタートメニューの間。仕様書 015)のときは、残り時間・点数・予告・結果の画面を出さない。
-- 仕様書 016:「やくわり」(Player の Attribute "Role")で、表示を分ける。
--   ・農家さん(Farmer)のとき、左上に「のこり: N ひき」(Attribute "PreyRemaining")を出す。稲刈り機の予告は出さない(稲刈り機が出ないため)。
--   ・結果の文言は、やくわりごと(RESULT_TEXTS)。点数・ベスト・ボタンは、どちらも同じ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local GuiController = {}

local REMOTE_WAIT_SECONDS = 10
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local PANEL_COLOR = Color3.fromRGB(30, 30, 30)
local BUTTON_COLOR = Color3.fromRGB(70, 150, 70)
local MENU_BUTTON_COLOR = Color3.fromRGB(70, 110, 160)
local TEXT_FONT = Enum.Font.GothamBold

-- 結果の文言(やくわり → 終わり方 → 文)。知らないやくわりは、ザリガニの文言を使う
local RESULT_TEXTS: { [string]: { Caught: string, Cleared: string } } = {
	Crayfish = { Caught = "つかまった", Cleared = "稲刈りの日まで生き延びた!" },
	Farmer = { Caught = "にげられた…", Cleared = "ぜんいん つかまえた!" },
}
local ROLE_CRAYFISH = "Crayfish"
local ROLE_FARMER = "Farmer"
local ROLE_ATTRIBUTE = "Role" -- SetupService が Player につける「やくわり」
local PREY_REMAINING_ATTRIBUTE = "PreyRemaining" -- PreyService が Player につける「のこりのひき数」
local TEXT_PREY_REMAINING = "のこり: %d ひき"
local TEXT_RESTART = "もう一度"
local TEXT_MENU = "メニューへ" -- 結果の画面の、もうひとつのボタン(仕様書 015)
local STATE_MENU = "Menu" -- スタートメニューの間(MenuController がメニューを出す)

-- 稲刈り機の予告(仕様書 006 の 5)
local TEXT_HARVESTER_WARNING = "稲刈り機が動き出した!"
local DIFFICULTY_ATTRIBUTE = "Difficulty" -- SetupService が Player につける「なんいど」
local HARVESTER_WARNING_COLOR = Color3.fromRGB(255, 220, 80)

-- 点数の表示(仕様書 012)
local TEXT_SCORE = "てん: "
local TEXT_BEST = "ベスト: "
local TEXT_NEW_BEST = "ベスト更新!"
local SCORE_COLOR = Color3.fromRGB(255, 210, 90)

-- いまの「やくわり」。Attribute がまだ届いていないときは、ザリガニ
local function getRole(): string
	local role = Players.LocalPlayer:GetAttribute(ROLE_ATTRIBUTE)
	if typeof(role) == "string" then
		return role
	end
	return ROLE_CRAYFISH
end

-- 結果の文言(終わり方は "Caught" か "Cleared")
local function getResultText(role: string, state: string): string
	local texts = RESULT_TEXTS[role] or RESULT_TEXTS[ROLE_CRAYFISH]
	return if state == "Cleared" then texts.Cleared else texts.Caught
end

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
local function buildGui(): (TextLabel, TextLabel, Frame, TextLabel, TextButton, TextLabel, Frame, TextButton)
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

	-- ボタンは2つ、横に並べる(左:もう一度、右:メニューへ)。スマホでも押しやすい大きさ
	local button = Instance.new("TextButton")
	button.Name = "RestartButton"
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.27, 0, 0.6, 0)
	button.Size = UDim2.fromOffset(190, 70)
	button.BackgroundColor3 = BUTTON_COLOR
	button.TextColor3 = TEXT_COLOR
	button.Font = TEXT_FONT
	button.TextSize = 28
	button.Text = TEXT_RESTART
	button.Parent = overlay

	local menuButton = Instance.new("TextButton")
	menuButton.Name = "MenuButton"
	menuButton.AnchorPoint = Vector2.new(0.5, 0)
	menuButton.Position = UDim2.new(0.73, 0, 0.6, 0)
	menuButton.Size = UDim2.fromOffset(190, 70)
	menuButton.BackgroundColor3 = MENU_BUTTON_COLOR
	menuButton.TextColor3 = TEXT_COLOR
	menuButton.Font = TEXT_FONT
	menuButton.TextSize = 28
	menuButton.Text = TEXT_MENU
	menuButton.Parent = overlay

	-- 画面の上:稲刈り機の予告(ふだんは隠しておく)
	local warningLabel = makeLabel("HarvesterWarning", UDim2.fromOffset(520, 50), UDim2.new(0.5, 0, 0, 100), 36, screenGui)
	warningLabel.AnchorPoint = Vector2.new(0.5, 0)
	warningLabel.TextColor3 = HARVESTER_WARNING_COLOR
	warningLabel.Text = TEXT_HARVESTER_WARNING
	warningLabel.Visible = false

	screenGui.Parent = playerGui
	return timeLabel, stageLabel, overlay, messageLabel, button, warningLabel, topPanel, menuButton
end

-- 点数の表示を作る(左上の点数と、結果の画面の点数・ベスト)。buildGui のあとに呼ぶ
local function buildScoreLabels(): (TextLabel?, TextLabel?)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = playerGui:FindFirstChild("RoundGui")
	if not screenGui then
		return nil, nil
	end
	local scoreLabel = makeLabel("ScoreLabel", UDim2.fromOffset(220, 40), UDim2.fromOffset(10, 10), 30, screenGui)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Left
	scoreLabel.TextColor3 = SCORE_COLOR
	scoreLabel.Visible = false

	local overlay = screenGui:FindFirstChild("ResultPanel")
	if not overlay then
		return scoreLabel, nil
	end
	local resultLabel = makeLabel("ScoreResultLabel", UDim2.new(1, 0, 0.14, 0), UDim2.new(0, 0, 0.45, 0), 26, overlay)
	resultLabel.TextColor3 = SCORE_COLOR
	resultLabel.TextWrapped = true -- 長い数字でも、パネルからはみ出さず、折り返す
	return scoreLabel, resultLabel
end

-- 農家さんのときの、左上の「のこり: N ひき」を作る(点数の下)。buildGui のあとに呼ぶ
local function buildPreyLabel(): TextLabel?
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = playerGui:FindFirstChild("RoundGui")
	if not screenGui then
		return nil
	end
	local preyLabel = makeLabel("PreyLabel", UDim2.fromOffset(220, 36), UDim2.fromOffset(10, 52), 26, screenGui)
	preyLabel.TextXAlignment = Enum.TextXAlignment.Left
	preyLabel.TextColor3 = SCORE_COLOR
	preyLabel.Visible = false
	return preyLabel
end

-- 結果の画面の「てん: 123 / ベスト: 200」の文字
local function formatResult(score: number, best: number, newBest: boolean): string
	local bestText = if newBest then TEXT_NEW_BEST else TEXT_BEST .. tostring(best)
	return TEXT_SCORE .. tostring(score) .. " / " .. bestText
end

-- 秒を「分:秒」の文字にする
local function formatTime(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

-- 稲刈り機の予告を出しておく長さ(秒)。そのプレイヤーの難易度の「稲刈り機が入るまでの待ち」
-- (Config.HarvesterEntryDelaySeconds + 難易度の HarvesterEntryDelayBonus。最小 Config.HarvesterEntryDelayMinSeconds。サーバーの Sweep と同じ計算)に、
-- Config.HarvesterWarningExtraSeconds を足した長さ。難易度は、Player の Attribute "Difficulty" から読む(なければ Config.DefaultDifficulty)
local function getWarningSeconds(): number
	local attribute = Players.LocalPlayer:GetAttribute(DIFFICULTY_ATTRIBUTE)
	local name = Config.DefaultDifficulty
	if typeof(attribute) == "string" and Config.Difficulties[attribute] ~= nil then
		name = attribute
	end
	local params = Config.Difficulties[name]
	local bonus = if params ~= nil and typeof(params.HarvesterEntryDelayBonus) == "number" then params.HarvesterEntryDelayBonus else 0
	local entryDelay = math.max(Config.HarvesterEntryDelaySeconds + bonus, Config.HarvesterEntryDelayMinSeconds)
	return entryDelay + Config.HarvesterWarningExtraSeconds
end

-- 稲刈り機の予告を、getWarningSeconds の長さだけ出す。連続で呼ばれたら、最後の呼び出しから数える
local warningToken = 0
local function showHarvesterWarning(warningLabel: TextLabel)
	warningToken += 1
	local myToken = warningToken
	warningLabel.Visible = true
	task.delay(getWarningSeconds(), function()
		if myToken == warningToken then
			warningLabel.Visible = false
		end
	end)
end

-- 予告を隠す(新しいラウンドが始まったときなど)
local function hideHarvesterWarning(warningLabel: TextLabel)
	warningToken += 1 -- 待っている隠す処理を無効にする
	warningLabel.Visible = false
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

	local timeLabel, stageLabel, overlay, messageLabel, button, warningLabel, topPanel, menuButton = buildGui()
	topPanel.Visible = false -- 最初の RoundState が届くまで、残り時間は出さない
	local harvesterStageName = Config.StageNames[Config.HarvesterActiveStage] -- 出穂の段階の名前
	local warned = false -- このラウンドで、予告を出したか

	-- 点数(仕様書 012)。ScoreState が見つからなくても、ほかの画面は動かす
	local scoreLabel, resultLabel = buildScoreLabels()
	local preyLabel = buildPreyLabel()
	local latestScore = 0
	local latestBest = 0
	local latestNewBest = false
	local currentState = STATE_MENU -- 最初の RoundState が届くまでは、メニューと同じ扱い(点数を出さない)

	local function refreshScore()
		if scoreLabel then
			scoreLabel.Text = TEXT_SCORE .. tostring(latestScore)
			scoreLabel.Visible = (currentState == "Playing")
		end
		if resultLabel then
			resultLabel.Text = formatResult(latestScore, latestBest, latestNewBest)
		end
	end

	-- 農家さんのとき、遊んでいる間だけ、「のこり: N ひき」を出す(Attribute が数字のときだけ)
	local function refreshPrey()
		if preyLabel == nil then
			return
		end
		local remaining = Players.LocalPlayer:GetAttribute(PREY_REMAINING_ATTRIBUTE)
		if typeof(remaining) == "number" then
			preyLabel.Text = string.format(TEXT_PREY_REMAINING, math.max(0, math.floor(remaining)))
		end
		preyLabel.Visible = (currentState == "Playing" and getRole() == ROLE_FARMER and typeof(remaining) == "number")
	end
	Players.LocalPlayer:GetAttributeChangedSignal(PREY_REMAINING_ATTRIBUTE):Connect(refreshPrey)
	Players.LocalPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(refreshPrey)

	task.spawn(function()
		local found = ReplicatedStorage:WaitForChild(Config.ScoreStateRemoteName, REMOTE_WAIT_SECONDS)
		if not found or not found:IsA("RemoteEvent") then
			warn(`[GuiController] {Config.ScoreStateRemoteName} が見つかりません。点数は表示されません。`)
			return
		end
		found.OnClientEvent:Connect(function(score: unknown, best: unknown, newBest: unknown, _eaten: unknown)
			if typeof(score) ~= "number" or typeof(best) ~= "number" or typeof(newBest) ~= "boolean" then
				return
			end
			latestScore = score
			latestBest = best
			latestNewBest = newBest
			refreshScore()
		end)
	end)

	button.Activated:Connect(function()
		restartRemote:FireServer() -- お願いを送るだけ。やり直すかはサーバーが決める
	end)

	-- 「メニューへ」(仕様書 015)。MenuRequest が見つからなくても、ほかの画面は動かす
	local menuFound = ReplicatedStorage:WaitForChild(Config.MenuRequestRemoteName, REMOTE_WAIT_SECONDS)
	if menuFound and menuFound:IsA("RemoteEvent") then
		local menuRemote = menuFound
		menuButton.Activated:Connect(function()
			menuRemote:FireServer() -- お願いを送るだけ。戻れるかはサーバーが決める
		end)
	else
		warn(`[GuiController] {Config.MenuRequestRemoteName} が見つかりません。「メニューへ」は使えません。`)
		menuButton.Visible = false
	end

	stateRemote.OnClientEvent:Connect(function(state: unknown, stageName: unknown, remaining: unknown)
		if typeof(state) ~= "string" or typeof(stageName) ~= "string" or typeof(remaining) ~= "number" then
			return
		end
		currentState = state
		refreshScore() -- 点数の表示を、状態に合わせる(Playing 中だけ左上に出す)
		refreshPrey() -- 「のこり」も、状態とやくわりに合わせる(農家さんで Playing 中だけ)
		topPanel.Visible = (state ~= STATE_MENU) -- メニューの間は、残り時間と段階の名前を出さない
		timeLabel.Text = formatTime(remaining)
		stageLabel.Text = stageName
		-- 段階の名前が「出穂」に変わったとき、1ラウンドに1回だけ予告を出す。別の段階に戻れば(新しいラウンド)また出せる。
		-- 状態が Playing でなくなったら(捕まった・クリアした)、予告はすぐ隠す
		if state ~= "Playing" then
			hideHarvesterWarning(warningLabel)
		end
		if stageName == harvesterStageName then
			-- 稲刈り機が出るのは、ザリガニのときだけ(農家さんのときは、出ないので、予告も出さない)
			if state == "Playing" and not warned and getRole() == ROLE_CRAYFISH then
				warned = true
				showHarvesterWarning(warningLabel)
			end
		else
			warned = false
			hideHarvesterWarning(warningLabel)
		end
		if state == "Caught" or state == "Cleared" then
			messageLabel.Text = getResultText(getRole(), state)
			overlay.Visible = true
		else
			overlay.Visible = false
		end
	end)
end

return GuiController
