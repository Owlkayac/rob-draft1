--!strict
-- ザリガニの操作(移動と、泥に潜る)をサーバーで管理する部品。仕様書 001。
-- 「潜っているか」などの状態は、すべてサーバーが持つ。
-- クライアントは「潜りたい/やめたい」とお願いするだけ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)
local SetupService = require(script.Parent.SetupService)

-- ザリガニの見た目を入れておくフォルダの名前(CrayfishModel と同じ名前)
local VISUAL_FOLDER_NAME = "CrayfishVisual"

-- 見た目の部品は ServerStorage/Modules にある(Rojo の対応は default.project.json)
local modulesFolder = ServerStorage:WaitForChild("Modules", 10)
assert(modulesFolder, "[CrayfishService] ServerStorage/Modules が見つかりません")
local crayfishModelScript = modulesFolder:WaitForChild("CrayfishModel", 10)
assert(crayfishModelScript, "[CrayfishService] CrayfishModel が見つかりません")
local CrayfishModel = require(crayfishModelScript :: ModuleScript)

-- プレイヤー1人ぶんの状態
type PlayerState = {
	Diving: boolean, -- 潜っているか
	DiveToken: number, -- 古いタイマーを無効にするための番号
	SplashToken: number, -- 水しぶきの古いタイマーを無効にするための番号
	CooldownUntil: number, -- この時刻(os.clock)まで潜れない
	LastRequestAt: number, -- 最後に要求を受け付けた時刻(os.clock)
	Alive: boolean, -- 生きているか(仕様書002・003であとで使う)
	OriginalTransparency: { [BasePart]: number }, -- 潜る前の透明度(浮上で戻す)
	Jetting: boolean, -- ジェットを噴射中か(仕様書 013)
	JetToken: number, -- 噴射の古いタイマーを無効にするための番号
	JetReadyAt: number, -- この時刻(os.clock)から、ジェットを使える
	LastJetRequestAt: number, -- 最後にジェットを発動した時刻(os.clock)
}

local CrayfishService = {}

-- Player をキーにした状態の表(将来、複数人でも動くように)
local states: { [Player]: PlayerState } = {}

local function newState(): PlayerState
	return {
		Diving = false,
		DiveToken = 0,
		SplashToken = 0,
		CooldownUntil = -math.huge,
		LastRequestAt = -math.huge,
		Alive = true,
		OriginalTransparency = {},
		Jetting = false,
		JetToken = 0,
		JetReadyAt = -math.huge,
		LastJetRequestAt = -math.huge,
	}
end

-- 農家さんのやくわり(仕様書 016)か。農家さんは、潜る・ジェット・ザリガニの見た目を使わない
local function isFarmerRole(player: Player): boolean
	return SetupService.GetRole(player) == "Farmer"
end

-- 農家さんのラウンド中か(やくわりが農家さんで、フェーズが Playing)。
-- メニューにいる間は、前に選んだやくわりが残っていても、これまでどおり(ザリガニの見た目・動けない)
local function isFarmerRound(player: Player): boolean
	return isFarmerRole(player) and SetupService.GetPhase(player) == "Playing"
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- 潜るときに透明度を変える対象の BasePart を集める。
-- CrayfishVisual があれば、その中の Part だけ(人型は隠してあるので触らない。あとから読み込まれる服・帽子にも影響しない)。
-- CrayfishVisual がない(Attach が失敗した)ときは、潜る見た目がなくならないよう、
-- HumanoidRootPart 以外のすべての BasePart を対象にする
local function getBodyParts(character: Model): { BasePart }
	local parts: { BasePart } = {}
	local visual = character:FindFirstChild(VISUAL_FOLDER_NAME)
	local searchRoot: Instance = if visual then visual else character
	for _, descendant in searchRoot:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- 元の透明度に戻す。消えた Part(作り直しで捨てられた古い見た目など)は飛ばす
local function restoreTransparency(state: PlayerState, character: Model?)
	for part, original in state.OriginalTransparency do
		if part.Parent and character and part:IsDescendantOf(character) then
			part.Transparency = original
		end
	end
	state.OriginalTransparency = {}
end

-- まだ記録していない Part の透明度を記録して、潜っている見た目にする(潜る瞬間と、潜り中の作り直しで使う)
local function applyDiveLook(state: PlayerState, character: Model)
	for _, part in getBodyParts(character) do
		if state.OriginalTransparency[part] == nil then
			state.OriginalTransparency[part] = part.Transparency
			-- もともと透明なパーツが見えてしまわないよう、濃いほうを使う
			part.Transparency = math.max(part.Transparency, Config.DiveTransparency)
		end
	end
end

-- キャラクターの水しぶきの粒子(CrayfishModel でつけた SplashEmitter)を探す。なければ nil
local function findSplashEmitter(character: Model?): ParticleEmitter?
	if not character then
		return nil
	end
	local visual = character:FindFirstChild(VISUAL_FOLDER_NAME)
	if not visual then
		return nil
	end
	local found = visual:FindFirstChild("SplashEmitter", true)
	if found and found:IsA("ParticleEmitter") then
		return found
	end
	return nil
end

-- 水しぶきを止める。古いタイマーも無効にする(やり直し・生まれ直し・死亡で、true のまま残らないように)
local function stopSplash(state: PlayerState, character: Model?)
	state.SplashToken += 1
	local emitter = findSplashEmitter(character)
	if emitter then
		emitter.Enabled = false
	end
end

-- 水しぶきを短く出す:Enabled を true にして、Config.SplashBurstSeconds 後に false へ戻す。
-- (サーバーで Emit() を呼んでも他の端末には見えないので、Enabled を切り替える)
-- 続けて呼ばれたら、古いタイマーは番号で無効になり、新しいタイマーだけが止める
local function burstSplash(state: PlayerState, character: Model?)
	local emitter = findSplashEmitter(character)
	if not emitter then
		return
	end
	state.SplashToken += 1
	local token = state.SplashToken
	emitter.Enabled = true
	task.delay(Config.SplashBurstSeconds, function()
		if state.SplashToken == token then
			emitter.Enabled = false -- 消えた粒子に書いても、エラーにならない
		end
	end)
end

-- 浮上する(クールダウン開始)
local function surface(player: Player)
	local state = states[player]
	if not state or not state.Diving then
		return
	end
	state.Diving = false
	state.DiveToken += 1 -- 残っているタイマーを無効にする
	state.CooldownUntil = os.clock() + Config.DiveCooldownSeconds

	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = Config.CrayfishWalkSpeed
	end
	restoreTransparency(state, player.Character)
	if player.Character then
		player.Character:SetAttribute("Hidden", false)
	end
	burstSplash(state, player.Character) -- 浮上の水しぶき
end

-- 潜る
local function dive(player: Player, state: PlayerState, character: Model, humanoid: Humanoid)
	state.Diving = true
	state.DiveToken += 1
	local token = state.DiveToken

	humanoid.WalkSpeed = 0
	state.OriginalTransparency = {}
	applyDiveLook(state, character)
	character:SetAttribute("Hidden", true)
	burstSplash(state, character) -- 潜る水しぶき

	-- 上限時間がたったら強制的に浮上する(同じ潜りのときだけ)
	task.delay(Config.DiveMaxSeconds, function()
		local current = states[player]
		if current and current.Diving and current.DiveToken == token then
			surface(player)
		end
	end)
end

-- 潜る状態を、何も起きていない状態に戻す(スポーン時・死亡時)
local function resetDiveState(player: Player)
	local state = states[player]
	if not state then
		return
	end
	state.Diving = false
	state.DiveToken += 1
	state.CooldownUntil = -math.huge
	state.OriginalTransparency = {}
	stopSplash(state, player.Character) -- 水しぶきも止める
end

-- ===== ジェット(仕様書 013) =====

-- キャラクターの噴射の粒子(CrayfishModel でつけた JetEmitter)を探す。なければ nil
local function findJetEmitter(character: Model?): ParticleEmitter?
	if not character then
		return nil
	end
	local visual = character:FindFirstChild(VISUAL_FOLDER_NAME)
	if not visual then
		return nil
	end
	local found = visual:FindFirstChild("JetEmitter", true)
	if found and found:IsA("ParticleEmitter") then
		return found
	end
	return nil
end

-- 噴射の粒子を出す・止める。粒子がなくても(消えていても)エラーにしない
local function setJetEmitter(character: Model?, enabled: boolean)
	local emitter = findJetEmitter(character)
	if emitter then
		emitter.Enabled = enabled
	end
end

-- ジェットのため直しの長さ(秒)。基本の長さに、難易度の倍率(JetCooldownMultiplier。仕様書 015)をかける。
-- 倍率が使えない値(数字でない・0以下・NaN・無限大)なら 1 倍
local function getJetCooldownSeconds(player: Player): number
	local multiplier = SetupService.GetDifficultyParams(player).JetCooldownMultiplier
	if type(multiplier) ~= "number" or multiplier ~= multiplier or multiplier <= 0 or multiplier == math.huge then
		multiplier = 1
	end
	return Config.JetCooldownSeconds * multiplier
end

-- 噴射の終わらせ方
--   "Cooldown": 噴射の時間切れ。ため直しを始める
--   "Reset":    死亡・生まれ直し。ため直しもなくして、すぐ使える状態に戻す
--   "Keep":     つかまった・クリア。噴射だけ止める(ため直しは、始めない・なくさない。生まれ直しでリセットされる)
type JetEndMode = "Cooldown" | "Reset" | "Keep"

-- 噴射を終わらせる。時間切れ・死亡・つかまった・クリア・生まれ直しのすべてで、この関数を使う。
-- 噴射中でなくても、安全に呼べる(その場合、ため直しは始めない)
local function endJet(player: Player, mode: JetEndMode)
	local state = states[player]
	if not state then
		return
	end
	local wasJetting = state.Jetting
	state.Jetting = false
	state.JetToken += 1 -- 残っているタイマーを無効にする

	local character = player.Character
	if wasJetting then
		local humanoid = getHumanoid(player)
		-- 潜っているときは変えない(潜る処理が WalkSpeed = 0 を管理する)
		if humanoid and not state.Diving then
			humanoid.WalkSpeed = Config.CrayfishWalkSpeed
		end
	end
	if character then
		character:SetAttribute("Jetting", false)
	end
	setJetEmitter(character, false)

	if mode == "Cooldown" and wasJetting then
		local cooldown = getJetCooldownSeconds(player)
		state.JetReadyAt = os.clock() + cooldown
		if character then
			character:SetAttribute("JetReadyTime", Workspace:GetServerTimeNow() + cooldown)
		end
	elseif mode == "Reset" then
		state.JetReadyAt = -math.huge
		if character then
			character:SetAttribute("JetReadyTime", 0)
		end
	end
end

-- 噴射を始める(呼ぶ前に、使える条件を確認しておくこと)
local function startJet(player: Player, state: PlayerState, character: Model, humanoid: Humanoid)
	state.Jetting = true
	state.JetToken += 1
	local token = state.JetToken

	humanoid.WalkSpeed = Config.CrayfishWalkSpeed * Config.JetSpeedMultiplier
	character:SetAttribute("Jetting", true)
	setJetEmitter(character, true)

	-- 噴射の時間がたったら終わらせる(同じ噴射のときだけ。番号が違えば、古いタイマーなので何もしない)
	task.delay(Config.JetSeconds, function()
		local current = states[player]
		if current and current.Jetting and current.JetToken == token then
			endJet(player, "Cooldown")
		end
	end)
end

-- ジェットの状態を、何も起きていない状態に戻す(スポーン時・死亡時)
local function resetJetState(player: Player)
	endJet(player, "Reset")
end

-- ジェットのお願いを確認して処理する。値は受け取らない(余分な引数があれば捨てる)。
-- 検証に通らないお願いは、黙って捨てる
local function onJetRequest(player: Player, ...: any)
	local state = states[player] -- (a) 状態があるか
	if not state then
		return
	end
	if select("#", ...) ~= 0 then -- (b) 余分な引数
		return
	end
	if isFarmerRole(player) then -- 農家さんは、ジェットを使わない(仕様書 016)
		return
	end
	local now = os.clock()
	if now - state.LastJetRequestAt < Config.JetRequestMinInterval then -- (c) 連打
		return
	end
	if not state.Alive or state.Diving or state.Jetting then -- (d) 生存・潜っていない・噴射中でない
		return
	end
	if now < state.JetReadyAt then -- (e) ため直し
		return
	end
	local character = player.Character
	local humanoid = getHumanoid(player)
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	-- 受け付けて発動するときだけ時刻を覚える(捨てた要求で更新すると、連打でため直しが終わっても発動できなくなる)
	state.LastJetRequestAt = now
	startJet(player, state, character, humanoid)
end

-- クライアントからのお願いを確認して処理する
local function onDiveRequest(player: Player, wantDive: unknown)
	local state = states[player] -- (a) 状態があるか
	if not state then
		return
	end
	if typeof(wantDive) ~= "boolean" then -- (b) 型
		return
	end
	if isFarmerRole(player) then -- 農家さんは、潜らない(仕様書 016)
		return
	end

	-- 「やめる」は、連打されても害がなく(浮上するとクールダウンが始まる)、
	-- 間隔チェックで捨てると「ちょん押し」で潜りっぱなしになるので、先に処理する
	if not wantDive then
		surface(player)
		return
	end

	local now = os.clock()
	if now - state.LastRequestAt < Config.DiveRequestMinInterval then -- (c) 連打
		return
	end
	if not state.Alive then -- (d) 生存
		return
	end
	state.LastRequestAt = now

	if state.Diving or state.Jetting or now < state.CooldownUntil then -- ジェット中は潜れない(仕様書 013)
		return
	end
	local character = player.Character
	local humanoid = getHumanoid(player)
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	dive(player, state, character, humanoid)
end

-- ザリガニの見た目をつけて、人型の見た目を隠す(仕様書 005)。何回呼んでも安全。
-- Attach が失敗したら、人型を隠さない(プレイヤーが見えなくなるのを防ぐ)
local function applyLook(player: Player, character: Model)
	if isFarmerRound(player) then
		return -- 農家さんのラウンドでは、人型のまま(巨人にするのは FarmerPlayer)
	end
	if not CrayfishModel.Attach(character) then
		WarnOnce.Warn(
			"CrayfishAttachFailed",
			"[CrayfishService] ザリガニの見た目をつけられなかったので、人型を見えるままにします"
		)
		return
	end
	CrayfishModel.HideAvatar(character)
	-- 潜っている最中に見た目が作り直されたら、新しい Part も潜っている見た目にする
	local state = states[player]
	if state and state.Diving then
		applyDiveLook(state, character)
	end
	-- 噴射中に作り直されたら、新しい粒子も出す
	if state and state.Jetting then
		setJetEmitter(character, true)
	end
end

-- キャラクターが生成されたときの準備
local function setupCharacter(player: Player, character: Model)
	resetDiveState(player)
	resetJetState(player)

	-- 新しく生まれ直したら、生きている状態に戻す(つかまった後のやり直しに備える)。
	-- ただし、メニューにいる間は、動けない・潜れない・ジェットできない状態にする(仕様書 015。RoundService も同じ状態にする)
	local inMenu = SetupService.GetPhase(player) == "Menu"
	local state = states[player]
	if state then
		state.Alive = not inMenu
	end

	local found = character:WaitForChild("Humanoid", Config.CharacterWaitSeconds)
	if not found or not found:IsA("Humanoid") then
		warn("[CrayfishService] Humanoid が見つからないので、キャラクターの準備をしません")
		return
	end
	local humanoid = found :: Humanoid
	if isFarmerRound(player) then
		return -- 農家さんのラウンド:歩く速さ・ジャンプ禁止・見た目は FarmerPlayer が決める(仕様書 016)
	end
	humanoid.WalkSpeed = if inMenu then 0 else Config.CrayfishWalkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0 -- ジャンプ禁止
	-- 死んだときに関節(Motor6D)が壊れて、足・はさみ・ひげがばらばらに落ちないようにする(仕様書 010)
	humanoid.BreakJointsOnDeath = false
	character:SetAttribute("Hidden", false)

	applyLook(player, character)

	humanoid.Died:Connect(function()
		resetDiveState(player)
		resetJetState(player)
	end)
end

local function onPlayerAdded(player: Player)
	if states[player] then
		return
	end
	states[player] = newState()
	player.CharacterAdded:Connect(function(character: Model)
		setupCharacter(player, character)
	end)
	-- 服や髪は、あとから付くので、読み込み後にもう一度隠す。
	-- (接続はプレイヤーごとに1回だけ。生まれ直すたびに増やさない)
	player.CharacterAppearanceLoaded:Connect(function(loadedCharacter: Model)
		if player.Character == loadedCharacter then
			applyLook(player, loadedCharacter)
		end
	end)
	if player.Character then
		task.spawn(setupCharacter, player, player.Character)
	end
end

function CrayfishService.Start()
	local remote = Instance.new("RemoteEvent")
	remote.Name = Config.DiveRemoteName
	remote.Parent = ReplicatedStorage
	remote.OnServerEvent:Connect(onDiveRequest)

	local jetRemote = Instance.new("RemoteEvent")
	jetRemote.Name = Config.JetRemoteName
	jetRemote.Parent = ReplicatedStorage
	jetRemote.OnServerEvent:Connect(onJetRequest)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

-- 隠れている(潜っている)か。天敵のスクリプトなどが使う
function CrayfishService.IsHidden(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.Diving
end

-- 生きているかを設定する(仕様書002・003が使う)
function CrayfishService.SetAlive(player: Player, alive: boolean)
	local state = states[player]
	if not state then
		return
	end
	state.Alive = alive
	if not alive then
		surface(player)
		endJet(player, "Keep") -- 噴射中なら止める(ため直しは始めない。生まれ直しでリセットされる)
	end
end

return CrayfishService
