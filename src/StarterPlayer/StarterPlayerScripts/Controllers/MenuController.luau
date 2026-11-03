--!strict
-- スタートメニューの画面(仕様書 015)。クライアントが、コードで作る。
-- やること:
--   1. RoundState が "Menu" のとき、メニューを出す。それ以外のときは隠す。
--   2. 「やくわり」と「なんいど」を選ばせて、「スタート」で StartRequest(role, difficulty)をサーバーに送る。
--      送れるのはお願いだけ。受け付けるかどうかは、サーバー(SetupService)が決める。
--   3. ベスト記録(サーバーが BestScores で送る表)から、いま選んでいる組み合わせのベストを出す。
--   4. 最後に選んだ組み合わせを覚えておき、次にメニューが開いたとき、その選択のままにする。
-- 毎フレームの処理はしない(ボタンを押したとき・サーバーから知らせが来たときだけ動く)。
-- 文言・色・大きさは、このファイルの先頭の定数にまとめてある。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local MenuController = {}

-- ===== 設定(文言・色・大きさ) =====
local REMOTE_WAIT_SECONDS = 10
local GUI_NAME = "MenuGui"
local GUI_DISPLAY_ORDER = 10 -- ほかの画面(RoundGui など)より手前に出す
local STATE_MENU = "Menu"
local START_UNLOCK_SECONDS = 5 -- 「スタート」を押したあと、メニューが閉じなければ、また押せるようにするまでの時間(秒)

local TEXT_ROLE_TITLE = "やくわり"
local TEXT_DIFFICULTY_TITLE = "なんいど"
local TEXT_BEST_FORMAT = "ベスト: %d てん"
local TEXT_BEST_NONE = "ベスト: まだなし"
local TEXT_START = "スタート"
local TEXT_STARTING = "はじめます…"
local TEXT_NOT_READY = "じゅんびちゅう" -- まだ遊べない「やくわり」(Config.Roles[...].Ready が false)

local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local DARK_TEXT_COLOR = Color3.fromRGB(40, 30, 10)
local BACKDROP_COLOR = Color3.fromRGB(10, 25, 15)
local PANEL_COLOR = Color3.fromRGB(35, 55, 40)
local TITLE_COLOR = Color3.fromRGB(255, 130, 90) -- ゲーム名(ザリガニの赤っぽい色)
local UNSELECTED_COLOR = Color3.fromRGB(70, 90, 95)
local SELECTED_COLOR = Color3.fromRGB(255, 205, 70) -- 選んでいるボタン(はっきり分かる色)
local START_COLOR = Color3.fromRGB(70, 160, 80)
local DISABLED_COLOR = Color3.fromRGB(110, 110, 110)
local BEST_COLOR = Color3.fromRGB(255, 220, 120)
local HINT_COLOR = Color3.fromRGB(215, 230, 215)
local TEXT_FONT = Enum.Font.GothamBold

local PANEL_SCALE = Vector2.new(0.92, 0.92) -- 画面に対する、パネルの大きさの割合
local PANEL_MAX_SIZE = Vector2.new(560, 640) -- パネルの最大の大きさ(ピクセル)
local PANEL_MIN_SIZE = Vector2.new(260, 260) -- パネルの最小の大きさ(ピクセル)
local CORNER_RADIUS = 12
local BUTTON_GAP = 0.03 -- ボタンの間のすきま(パネルの幅に対する割合)
local BUTTON_MAX_TEXT_SIZE = 34
local LABEL_MAX_TEXT_SIZE = 28
local TITLE_MAX_TEXT_SIZE = 60

-- パネルの中の縦の配置(パネルの高さに対する割合。上から順)
local LAYOUT = {
	Title = { Y = 0.02, H = 0.12 },
	RoleTitle = { Y = 0.15, H = 0.05 },
	RoleButtons = { Y = 0.21, H = 0.14 },
	Hint = { Y = 0.36, H = 0.08 },
	DifficultyTitle = { Y = 0.46, H = 0.05 },
	DifficultyButtons = { Y = 0.52, H = 0.12 },
	Best = { Y = 0.66, H = 0.07 },
	Start = { Y = 0.76, H = 0.18 },
}

-- 画面の部品(作ったあとで入れる)
type MenuUi = {
	Gui: ScreenGui,
	RoleButtons: { [string]: TextButton },
	DifficultyButtons: { [string]: TextButton },
	HintLabel: TextLabel,
	BestLabel: TextLabel,
	StartButton: TextButton,
}

-- ===== 状態(この端末の中だけ) =====
local started = false
local ui: MenuUi? = nil
local startRemote: RemoteEvent? = nil
local selectedRole: string = Config.DefaultRole -- 最後に選んだ「やくわり」(メニューが開き直しても、覚えている)
local selectedDifficulty: string = Config.DefaultDifficulty -- 最後に選んだ「なんいど」
local bests: { [string]: number } = {} -- サーバーから届いたベスト記録の表
local startLocked = false -- 「スタート」を押したあと、メニューが閉じるまで(または時間が来るまで)押せない
local lockToken = 0 -- 古い「また押せるようにする」タイマーを無効にするための番号

-- ===== 小さな道具 =====

-- その「やくわり」が、いま遊べるか(Config.Roles[...].Ready)
local function isRoleReady(role: string): boolean
	local info = Config.Roles[role]
	return info ~= nil and info.Ready
end

-- 角を丸くする
local function addCorner(target: GuiObject)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, CORNER_RADIUS)
	corner.Parent = target
end

-- 文字の大きさの上限をつける(TextScaled で大きくなりすぎないように)
local function addTextLimit(target: GuiObject, maxSize: number)
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize
	limit.Parent = target
end

local function makeLabel(parent: Instance, name: string, text: string, y: number, height: number, maxSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.02, y)
	label.Size = UDim2.fromScale(0.96, height)
	label.Font = TEXT_FONT
	label.TextColor3 = TEXT_COLOR
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	label.Parent = parent
	addTextLimit(label, maxSize)
	return label
end

local function makeButton(parent: Instance, name: string, text: string, position: UDim2, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = UNSELECTED_COLOR
	button.TextColor3 = TEXT_COLOR
	button.Font = TEXT_FONT
	button.TextScaled = true
	button.TextWrapped = true
	button.Text = text
	button.AutoButtonColor = true
	button.Parent = parent
	addCorner(button)
	addTextLimit(button, BUTTON_MAX_TEXT_SIZE)
	return button
end

-- 横に count 個並べるときの、index 番目(1から)のボタンの位置と大きさ(パネルの幅に対する割合)
local function rowSlot(index: number, count: number, y: number, height: number): (UDim2, UDim2)
	local width = (1 - BUTTON_GAP * (count + 1)) / count
	local x = BUTTON_GAP + (index - 1) * (width + BUTTON_GAP)
	return UDim2.fromScale(x, y), UDim2.fromScale(width, height)
end

-- ===== 表示の更新 =====

-- 選んでいるボタンだけ、色を変える
local function paintSelection(buttons: { [string]: TextButton }, selected: string)
	for key, button in buttons do
		local isSelected = (key == selected)
		button.BackgroundColor3 = if isSelected then SELECTED_COLOR else UNSELECTED_COLOR
		button.TextColor3 = if isSelected then DARK_TEXT_COLOR else TEXT_COLOR
	end
end

-- 「スタート」ボタンの見た目(遊べない・押したあと・ふつう)
local function paintStartButton(button: TextButton)
	if not isRoleReady(selectedRole) then
		button.Text = TEXT_NOT_READY
		button.BackgroundColor3 = DISABLED_COLOR
		button.AutoButtonColor = false
	elseif startLocked then
		button.Text = TEXT_STARTING
		button.BackgroundColor3 = DISABLED_COLOR
		button.AutoButtonColor = false
	else
		button.Text = TEXT_START
		button.BackgroundColor3 = START_COLOR
		button.AutoButtonColor = true
	end
end

-- いまの選択に合わせて、画面全体を直す
local function refresh()
	local current = ui
	if current == nil then
		return
	end
	paintSelection(current.RoleButtons, selectedRole)
	paintSelection(current.DifficultyButtons, selectedDifficulty)

	local info = Config.Roles[selectedRole]
	current.HintLabel.Text = if info ~= nil then info.Hint else ""

	local best = bests[selectedRole .. "_" .. selectedDifficulty]
	current.BestLabel.Text = if best ~= nil and best > 0 then string.format(TEXT_BEST_FORMAT, math.floor(best)) else TEXT_BEST_NONE

	paintStartButton(current.StartButton)
end

-- メニューを出す・隠す。隠すときは、「スタート」の押せない状態も解く
local function setMenuVisible(visible: boolean)
	local current = ui
	if current == nil then
		return
	end
	if current.Gui.Enabled == visible then
		return -- すでにその状態(サーバーは Menu を毎秒送ってくるので、何回来ても何もしない)
	end
	if not visible then
		startLocked = false
		lockToken += 1 -- 待っているタイマーを無効にする
	end
	current.Gui.Enabled = visible
	refresh()
end

-- ===== 操作 =====

local function onRolePressed(role: string)
	selectedRole = role
	refresh()
end

local function onDifficultyPressed(difficulty: string)
	selectedDifficulty = difficulty
	refresh()
end

-- 「スタート」:お願いを送るだけ。始められるかは、サーバーが決める
local function onStartPressed()
	local remote = startRemote
	if remote == nil or startLocked or not isRoleReady(selectedRole) then
		return
	end
	startLocked = true
	lockToken += 1
	local myToken = lockToken
	remote:FireServer(selectedRole, selectedDifficulty)
	refresh()
	-- メニューが閉じなかったとき(サーバーが受け付けなかった、など)のために、時間が来たら、また押せるようにする
	task.delay(START_UNLOCK_SECONDS, function()
		if lockToken == myToken then
			startLocked = false
			refresh()
		end
	end)
end

-- ===== 画面を作る =====

local function buildRoleButtons(panel: Frame): { [string]: TextButton }
	local buttons: { [string]: TextButton } = {}
	local count = #Config.RoleOrder
	for index, role in Config.RoleOrder do
		local info = Config.Roles[role]
		if info ~= nil then
			local position, size = rowSlot(index, count, LAYOUT.RoleButtons.Y, LAYOUT.RoleButtons.H)
			local button = makeButton(panel, "Role_" .. role, info.Label, position, size)
			button.Activated:Connect(function()
				onRolePressed(role)
			end)
			buttons[role] = button
		end
	end
	return buttons
end

local function buildDifficultyButtons(panel: Frame): { [string]: TextButton }
	local buttons: { [string]: TextButton } = {}
	local count = #Config.DifficultyOrder
	for index, difficulty in Config.DifficultyOrder do
		local label = Config.DifficultyLabels[difficulty]
		if label ~= nil then
			local position, size = rowSlot(index, count, LAYOUT.DifficultyButtons.Y, LAYOUT.DifficultyButtons.H)
			local button = makeButton(panel, "Difficulty_" .. difficulty, label, position, size)
			button.Activated:Connect(function()
				onDifficultyPressed(difficulty)
			end)
			buttons[difficulty] = button
		end
	end
	return buttons
end

-- 背景とパネルを作る。パネルを返す
local function buildFrame(screenGui: ScreenGui): Frame
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = BACKDROP_COLOR
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(PANEL_SCALE.X, PANEL_SCALE.Y)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.Parent = backdrop
	addCorner(panel)

	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = PANEL_MAX_SIZE
	sizeLimit.MinSize = PANEL_MIN_SIZE
	sizeLimit.Parent = panel
	return panel
end

local function buildUi(): MenuUi
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false -- 生まれ直しても画面を消さない
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = GUI_DISPLAY_ORDER
	screenGui.Enabled = false -- RoundState が "Menu" になるまで出さない

	local panel = buildFrame(screenGui)
	local title = makeLabel(panel, "Title", Config.GameName, LAYOUT.Title.Y, LAYOUT.Title.H, TITLE_MAX_TEXT_SIZE)
	title.TextColor3 = TITLE_COLOR
	makeLabel(panel, "RoleTitle", TEXT_ROLE_TITLE, LAYOUT.RoleTitle.Y, LAYOUT.RoleTitle.H, LABEL_MAX_TEXT_SIZE)
	local roleButtons = buildRoleButtons(panel)
	local hint = makeLabel(panel, "Hint", "", LAYOUT.Hint.Y, LAYOUT.Hint.H, LABEL_MAX_TEXT_SIZE)
	hint.TextColor3 = HINT_COLOR
	makeLabel(panel, "DifficultyTitle", TEXT_DIFFICULTY_TITLE, LAYOUT.DifficultyTitle.Y, LAYOUT.DifficultyTitle.H, LABEL_MAX_TEXT_SIZE)
	local difficultyButtons = buildDifficultyButtons(panel)
	local best = makeLabel(panel, "Best", TEXT_BEST_NONE, LAYOUT.Best.Y, LAYOUT.Best.H, LABEL_MAX_TEXT_SIZE)
	best.TextColor3 = BEST_COLOR

	local startButton = makeButton(
		panel,
		"StartButton",
		TEXT_START,
		UDim2.fromScale(0.15, LAYOUT.Start.Y),
		UDim2.fromScale(0.7, LAYOUT.Start.H)
	)
	startButton.BackgroundColor3 = START_COLOR
	startButton.Activated:Connect(onStartPressed)

	screenGui.Parent = playerGui
	return {
		Gui = screenGui,
		RoleButtons = roleButtons,
		DifficultyButtons = difficultyButtons,
		HintLabel = hint,
		BestLabel = best,
		StartButton = startButton,
	}
end

-- ===== サーバーからの知らせ =====

-- RoundState:"Menu" のときだけメニューを出す。ほかの状態や、知らない値は、隠す(エラーにしない)
local function onRoundState(state: unknown, _stageName: unknown, _remaining: unknown)
	if typeof(state) ~= "string" then
		return
	end
	setMenuVisible(state == STATE_MENU)
end

-- BestScores:ベスト記録の表。形が違うものは捨てる(キーは文字、値は数字だけ受け取る)
local function onBestScores(scores: unknown)
	if typeof(scores) ~= "table" then
		return
	end
	local received: { [string]: number } = {}
	local entries = scores :: any
	for key, value in entries do
		if type(key) == "string" and type(value) == "number" and value == value then
			received[key] = value
		end
	end
	bests = received
	refresh()
end

-- RemoteEvent を待って返す。見つからなければ nil
local function waitForRemote(name: string): RemoteEvent?
	local found = ReplicatedStorage:WaitForChild(name, REMOTE_WAIT_SECONDS)
	if found ~= nil and found:IsA("RemoteEvent") then
		return found
	end
	return nil
end

function MenuController.Start()
	if started then
		return -- 二重に起動しない
	end
	started = true

	ui = buildUi()
	refresh()

	-- ベスト記録は、届くのが遅れてもよい(別のスレッドで待つ)
	task.spawn(function()
		local bestRemote = waitForRemote(Config.BestScoresRemoteName)
		if bestRemote == nil then
			warn(`[MenuController] {Config.BestScoresRemoteName} が見つかりません。ベスト記録は表示されません。`)
			return
		end
		bestRemote.OnClientEvent:Connect(onBestScores)
	end)

	-- 「スタート」のお願いを送る先。見つからなくても、メニューは出す(押しても何も起きない)
	task.spawn(function()
		startRemote = waitForRemote(Config.StartRequestRemoteName)
		if startRemote == nil then
			warn(`[MenuController] {Config.StartRequestRemoteName} が見つかりません。「スタート」は使えません。`)
		end
	end)

	local stateRemote = waitForRemote(Config.RoundStateRemoteName)
	if stateRemote == nil then
		warn(`[MenuController] {Config.RoundStateRemoteName} が見つかりません。メニューは出ません。`)
		return
	end
	stateRemote.OnClientEvent:Connect(onRoundState)
end

return MenuController
