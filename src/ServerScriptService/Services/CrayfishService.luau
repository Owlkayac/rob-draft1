--!strict
-- ザリガニの操作(移動と、泥に潜る)をサーバーで管理する部品。仕様書 001。
-- 「潜っているか」などの状態は、すべてサーバーが持つ。
-- クライアントは「潜りたい/やめたい」とお願いするだけ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local WarnOnce = require(script.Parent.Enemy.WarnOnce)

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
	CooldownUntil: number, -- この時刻(os.clock)まで潜れない
	LastRequestAt: number, -- 最後に要求を受け付けた時刻(os.clock)
	Alive: boolean, -- 生きているか(仕様書002・003であとで使う)
	OriginalTransparency: { [BasePart]: number }, -- 潜る前の透明度(浮上で戻す)
}

local CrayfishService = {}

-- Player をキーにした状態の表(将来、複数人でも動くように)
local states: { [Player]: PlayerState } = {}

local function newState(): PlayerState
	return {
		Diving = false,
		DiveToken = 0,
		CooldownUntil = -math.huge,
		LastRequestAt = -math.huge,
		Alive = true,
		OriginalTransparency = {},
	}
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

	if state.Diving or now < state.CooldownUntil then
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
end

-- キャラクターが生成されたときの準備
local function setupCharacter(player: Player, character: Model)
	resetDiveState(player)

	-- 新しく生まれ直したら、生きている状態に戻す(つかまった後のやり直しに備える)
	local state = states[player]
	if state then
		state.Alive = true
	end

	local found = character:WaitForChild("Humanoid", Config.CharacterWaitSeconds)
	if not found or not found:IsA("Humanoid") then
		warn("[CrayfishService] Humanoid が見つからないので、キャラクターの準備をしません")
		return
	end
	local humanoid = found :: Humanoid
	humanoid.WalkSpeed = Config.CrayfishWalkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0 -- ジャンプ禁止
	character:SetAttribute("Hidden", false)

	applyLook(player, character)

	humanoid.Died:Connect(function()
		resetDiveState(player)
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
	end
end

return CrayfishService
