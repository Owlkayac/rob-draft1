--!strict
-- 尻尾のジェットの、クライアント側(仕様書 013)。
-- やること:
--   1. Q キー(スマホは画面ボタン「ジェット」)を押したら、サーバーに「ジェットしたい」とお願いする。
--      噴射中・ため直し中は、お願いを送らない(連打で、サーバーの受け付け間隔に引っかからないように)。
--      使えるかどうかの最終的な判断は、サーバーが行う。
--      押した瞬間の「動かしている向き」を覚えておき、噴射が始まったときの向きに使う。
--   2. 噴射中(キャラクターの Attribute Jetting が true の間)は、発動の瞬間の向きに、毎フレーム Humanoid:Move で進ませる。
--   3. 噴射の間、カメラの視野(FieldOfView)を少し広げる(自分の端末だけ)。
--   4. 画面の下に、「ジェット: じゅんびOK」などの小さな表示を出す(0.1秒ごとに更新)。
-- 毎フレームの処理は、噴射中の Move だけ。ほかは、イベントと 0.1秒ごとの更新。
-- 仕様書 016:やくわりが農家さん(Player の Attribute "Role" が "Farmer")のときは、ジェットしないので、
--   画面のボタン・キー・下の表示(JetGui)を出さない(取り外す・隠す)。ザリガニに戻ったら、また出す。サーバーも、農家さんの要求は無視する。
--   スタートメニューの間(RoundState が "Menu")も、同じく、ボタン・キー・表示を出さない(メニューの上に、ボタンが残らないように)。

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local JetController = {}

local ACTION_NAME = "CrayfishJet"
local BUTTON_TITLE = "ジェット"
local RENDER_STEP_NAME = "CrayfishJetMove"
local JETTING_ATTRIBUTE = "Jetting" -- 噴射中、サーバーがキャラクターにつける目印
local READY_TIME_ATTRIBUTE = "JetReadyTime" -- 使えるようになる時刻(サーバー時刻)
local MOVE_INPUT_MIN = 0.1 -- 動かしている向きの水平の大きさが、これより大きければ「動かしている」とみなす
local LOOK_MIN = 0.001 -- 向いている向きの水平の大きさの下限(真上を向いているときの、0 の向きを避ける)
local MIN_POSITIVE = 0.001 -- 割り算の下の数がこれより小さくならないようにする下限
local ROLE_ATTRIBUTE = "Role" -- SetupService が Player につける「やくわり」
local ROLE_FARMER = "Farmer"
local STATE_MENU = "Menu" -- スタートメニューの間(RoundState)

-- 画面の表示(文言・色・大きさ・位置)
local GUI_NAME = "JetGui"
local TEXT_READY = "ジェット: じゅんびOK"
local TEXT_ACTIVE = "ジェット: ふんしゃ中!"
local TEXT_WAIT_FORMAT = "ジェット: あと %.1f びょう"
local COLOR_READY = Color3.fromRGB(150, 230, 255)
local COLOR_ACTIVE = Color3.fromRGB(255, 255, 255)
local COLOR_WAIT = Color3.fromRGB(190, 190, 190)
local GUI_TEXT_SIZE = 22
local GUI_SIZE = UDim2.fromOffset(240, 32)
local GUI_POSITION = UDim2.new(0.62, 0, 1, -16) -- 画面の下。中央より少し右
local GUI_ANCHOR = Vector2.new(0.5, 1)

local started = false
local characterConnection: RBXScriptConnection? = nil -- 今のキャラクターの Jetting を見るつなぎ
local jetActive = false -- いま噴射の動きをしているか
local moveBound = false -- BindToRenderStep をしているか
local moveDirection = Vector3.zero -- 噴射の向き(発動の瞬間に決める。水平で、長さ 1)
local moveHumanoid: Humanoid? = nil
local fovTween: Tween? = nil
local fovBase: number? = nil -- 噴射の直前の視野(戻す先)
local pressedDirection: Vector3? = nil -- 押した瞬間の、動かしている向き(水平で長さ 1)。止まっていたら nil。噴射が終わったら消す
local actionBound = false -- いま操作(キー・ボタン)を取り付けているか
local inMenuState = true -- いまスタートメニューの間か(最初の知らせが届くまでは、メニューと同じ扱い)
local jetScreenGui: ScreenGui? = nil -- 画面の下の表示を入れている ScreenGui
local refreshBindingHook: (() -> ())? = nil -- 操作の取り付け・取り外しをやり直す関数(Start が入れる。メニューの出入りで呼ぶ)

-- いまのやくわりが農家さんか
local function isFarmerRole(): boolean
	return Players.LocalPlayer:GetAttribute(ROLE_ATTRIBUTE) == ROLE_FARMER
end

-- 画面の下の表示を出すか隠すか:メニューの間と、農家さんのときは隠す
local function refreshGuiEnabled()
	local screenGui = jetScreenGui
	if screenGui ~= nil then
		screenGui.Enabled = (not inMenuState) and (not isFarmerRole())
	end
end

-- メニューの出入りや、やくわりの変化のあと、操作(キー・ボタン)と表示を、いまの状態に合わせ直す。
-- 操作の関数がまだ用意できていなければ(Start の途中)、表示だけ合わせる
local function refreshAll()
	local hook = refreshBindingHook
	if hook ~= nil then
		hook()
	else
		refreshGuiEnabled()
	end
end

-- 水平の成分だけを取り出して、長さ 1 にする。大きさが minLength 以下なら nil
local function horizontalUnit(vector: Vector3, minLength: number): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude > minLength then
		return flat.Unit
	end
	return nil
end

-- 噴射の向きを決める。押した瞬間に覚えた向きがあればそれ、なければザリガニが向いている向き。決められなければ nil
local function chooseDirection(pressed: Vector3?, root: BasePart?): Vector3?
	if pressed then
		local moving = horizontalUnit(pressed, MOVE_INPUT_MIN)
		if moving then
			return moving
		end
	end
	if root then
		return horizontalUnit(root.CFrame.LookVector, LOOK_MIN)
	end
	return nil
end

-- 押した瞬間の、動かしている向きを覚える。止まっていたら nil(噴射の始まりに、向いている向きを使う)
local function rememberPressedDirection(character: Model?)
	pressedDirection = nil
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pressedDirection = horizontalUnit(humanoid.MoveDirection, MOVE_INPUT_MIN)
	end
end

-- 毎フレーム:ふだんの操作の入力のあとに、噴射の向きで上書きする
local function onMoveStep()
	local humanoid = moveHumanoid
	if humanoid == nil or humanoid.Parent == nil then
		-- キャラクターが消えた。自分で外す(エラーにしない)
		if moveBound then
			moveBound = false
			RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		end
		return
	end
	humanoid:Move(moveDirection, false) -- false = カメラの向きではなく、世界の向きで進む
end

local function stopMove()
	moveHumanoid = nil
	if moveBound then
		moveBound = false
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end
end

local function startMove(humanoid: Humanoid, direction: Vector3)
	stopMove() -- 同じ名前を二重に登録しないように
	moveDirection = direction
	moveHumanoid = humanoid
	moveBound = true
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Input.Value + 1, onMoveStep)
end

-- 視野を target へ、seconds かけて変える。古い Tween は、新しいものを作る前に止める
local function tweenFov(camera: Camera, target: number, seconds: number, onDone: (() -> ())?)
	local old = fovTween
	if old then
		old:Cancel()
	end
	local tween = TweenService:Create(camera, TweenInfo.new(math.max(seconds, 0)), { FieldOfView = target })
	fovTween = tween
	tween.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if playbackState == Enum.PlaybackState.Completed and fovTween == tween then
			fovTween = nil
			if onDone then
				onDone()
			end
		end
	end)
	tween:Play()
end

-- 噴射の始まり:視野を広げる。元の値は、まだ戻していなければ前の値を使う(連続しても狂わない)
local function widenFov()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local base = fovBase
	if base == nil then
		base = camera.FieldOfView
		fovBase = base
	end
	tweenFov(camera, (base :: number) + Config.JetFovAdd, Config.JetFovInSeconds, nil)
end

-- 噴射の終わり:視野を元に戻す
local function restoreFov()
	local base = fovBase
	local camera = Workspace.CurrentCamera
	if base == nil or camera == nil then
		return
	end
	tweenFov(camera, base, Config.JetFovOutSeconds, function()
		fovBase = nil -- 戻し終わった。次の噴射で、また今の値を覚える
	end)
end

-- ため直し中か(使えるようになる時刻が、まだ先か)
local function isCoolingDown(character: Model?): boolean
	if character == nil then
		return false
	end
	local readyTime = character:GetAttribute(READY_TIME_ATTRIBUTE)
	if typeof(readyTime) ~= "number" then
		return false
	end
	return (readyTime :: number) > Workspace:GetServerTimeNow()
end

-- Jetting が true になった:向きを決めて、進ませ始める。視野も広げる
local function onJetStart(character: Model)
	jetActive = true
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local rootFound = character:FindFirstChild("HumanoidRootPart")
		local root = if rootFound and rootFound:IsA("BasePart") then rootFound else nil
		local direction = chooseDirection(pressedDirection, root)
		if direction then
			startMove(humanoid, direction)
		end
	end
	widenFov()
end

-- Jetting が false になった(または、キャラクターが入れ替わった):進ませるのをやめて、視野を戻す
local function onJetEnd()
	jetActive = false
	pressedDirection = nil -- 古い向きが、次の噴射に残らないように
	stopMove()
	restoreFov()
end

-- Jetting の変化を見る。実際に変わったときだけ処理する
local function onJettingChanged(character: Model)
	local value = character:GetAttribute(JETTING_ATTRIBUTE) == true
	if value == jetActive then
		return
	end
	if value then
		onJetStart(character)
	else
		onJetEnd()
	end
end

-- キャラクターができたら、Jetting を見張る。生まれ直すたびに、古いつなぎを切って、つなぎ直す
local function watchCharacter(character: Model)
	local old = characterConnection
	characterConnection = nil
	if old then
		old:Disconnect()
	end
	if jetActive then
		onJetEnd() -- 前のキャラクターが噴射中のまま消えた。動きと視野を片づける
	end
	characterConnection = character:GetAttributeChangedSignal(JETTING_ATTRIBUTE):Connect(function()
		onJettingChanged(character)
	end)
	onJettingChanged(character) -- すでに true だった場合に備える
end

-- 画面の小さな表示を作る。TextLabel を返す
local function buildGui(): TextLabel
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false -- 生まれ直しても画面を消さない

	local label = Instance.new("TextLabel")
	label.Name = "JetLabel"
	label.AnchorPoint = GUI_ANCHOR
	label.Position = GUI_POSITION
	label.Size = GUI_SIZE
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = GUI_TEXT_SIZE
	label.TextColor3 = COLOR_READY
	label.TextStrokeTransparency = 0.5
	label.Text = TEXT_READY
	label.Parent = screenGui

	screenGui.Parent = playerGui
	return label
end

-- 文字と色を、変わったときだけ代入する(毎回代入すると、無駄に画面が更新される)
local function setLabel(label: TextLabel, text: string, color: Color3)
	if label.Text ~= text then
		label.Text = text
	end
	if label.TextColor3 ~= color then
		label.TextColor3 = color
	end
end

-- 表示の文字と色を決める。character が nil のときは、何も変えず、前の表示を保つ
local function updateLabel(label: TextLabel, character: Model?)
	if character == nil then
		return
	end
	if character:GetAttribute(JETTING_ATTRIBUTE) == true then
		setLabel(label, TEXT_ACTIVE, COLOR_ACTIVE)
		return
	end
	local readyTime = character:GetAttribute(READY_TIME_ATTRIBUTE)
	local remaining = 0
	if typeof(readyTime) == "number" then
		remaining = (readyTime :: number) - Workspace:GetServerTimeNow()
	end
	if remaining > 0 then
		setLabel(label, string.format(TEXT_WAIT_FORMAT, remaining), COLOR_WAIT)
	else
		setLabel(label, TEXT_READY, COLOR_READY)
	end
end

-- スタートメニューの間(RoundState が "Menu"。仕様書 015)は、画面の下の表示を隠す。
-- 最初の知らせが届くまでは隠しておく。RoundState が見つからないときは、これまでどおり出す(農家さんのときは、隠したまま)
local function watchMenuState()
	refreshAll()
	local found = ReplicatedStorage:WaitForChild(Config.RoundStateRemoteName, Config.JetWaitSeconds)
	if not found or not found:IsA("RemoteEvent") then
		inMenuState = false
		refreshAll()
		return
	end
	found.OnClientEvent:Connect(function(state: unknown, _stageName: unknown, _remaining: unknown)
		if typeof(state) ~= "string" then
			return
		end
		inMenuState = (state == STATE_MENU)
		refreshAll() -- メニューに入ったら、操作を取り外す。出たら、やくわりに合わせて、また取り付ける
	end)
end

-- 0.1秒ごとに表示を更新するループを始める
local function startLabelLoop(label: TextLabel)
	task.spawn(function()
		while label.Parent ~= nil do
			updateLabel(label, Players.LocalPlayer.Character)
			task.wait(math.max(Config.JetGuiUpdateSeconds, MIN_POSITIVE))
		end
	end)
end

function JetController.Start()
	if started then
		return -- 二重に起動しない
	end
	started = true

	local found = ReplicatedStorage:WaitForChild(Config.JetRemoteName, Config.JetWaitSeconds)
	if not found or not found:IsA("RemoteEvent") then
		warn(`[JetController] {Config.JetRemoteName} が見つかりません。ジェットは使えません。`)
		return
	end
	local remote = found

	-- 押した瞬間に、値なしでお願いを送る。使えるかどうかは、サーバーが決める
	local function handle(_actionName: string, inputState: Enum.UserInputState, _input: InputObject)
		if inputState == Enum.UserInputState.Begin then
			local character = Players.LocalPlayer.Character
			if jetActive or isCoolingDown(character) then
				return Enum.ContextActionResult.Sink -- 使えないときは送らない(サーバーも、最終的に確かめる)
			end
			rememberPressedDirection(character)
			remote:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end
	-- やくわりに合わせて、操作(キー・画面のボタン)を取り付ける・取り外す(二重に取り付けない)
	local function refreshBinding()
		local shouldBind = (not isFarmerRole()) and (not inMenuState) -- 農家さんのときと、メニューの間は、取り付けない
		if shouldBind ~= actionBound then
			actionBound = shouldBind
			if shouldBind then
				ContextActionService:BindAction(ACTION_NAME, handle, true, Enum.KeyCode.Q)
				ContextActionService:SetTitle(ACTION_NAME, BUTTON_TITLE)
			else
				ContextActionService:UnbindAction(ACTION_NAME) -- 画面のボタンも消える
			end
		end
		refreshGuiEnabled()
	end
	refreshBindingHook = refreshBinding
	refreshBinding()
	Players.LocalPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(refreshBinding)

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(watchCharacter)
	local existing = player.Character
	if existing then
		watchCharacter(existing)
	end

	local label = buildGui()
	startLabelLoop(label)
	local screenGui = label.Parent
	if screenGui ~= nil and screenGui:IsA("ScreenGui") then
		jetScreenGui = screenGui
		task.spawn(watchMenuState)
	end
end

return JetController
