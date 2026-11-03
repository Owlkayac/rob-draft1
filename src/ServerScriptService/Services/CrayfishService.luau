--!strict
-- ザリガニの操作(移動と、泥に潜る)をサーバーで管理する部品。仕様書 001。
-- 「潜っているか」などの状態は、すべてサーバーが持つ。
-- クライアントは「潜りたい/やめたい」とお願いするだけ。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

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

-- HumanoidRootPart 以外の、体の BasePart を集める
local function getBodyParts(character: Model): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- 元の透明度に戻す
local function restoreTransparency(state: PlayerState)
	for part, original in state.OriginalTransparency do
		if part.Parent then
			part.Transparency = original
		end
	end
	state.OriginalTransparency = {}
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
	restoreTransparency(state)
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
	for _, part in getBodyParts(character) do
		state.OriginalTransparency[part] = part.Transparency
		-- もともと透明なパーツ(見えない装飾品など)が見えてしまわないよう、濃いほうを使う
		part.Transparency = math.max(part.Transparency, Config.DiveTransparency)
	end
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

-- 仮の見た目:体を赤くする
local function paintBody(character: Model)
	for _, part in getBodyParts(character) do
		part.Color = Config.CrayfishColor
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

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = Config.CrayfishWalkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0 -- ジャンプ禁止
	character:SetAttribute("Hidden", false)

	paintBody(character)

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
	-- 服や髪は、あとから付くので、読み込み後にもう一度塗る。
	-- (接続はプレイヤーごとに1回だけ。生まれ直すたびに増やさない)
	player.CharacterAppearanceLoaded:Connect(function(loadedCharacter: Model)
		if player.Character == loadedCharacter then
			paintBody(loadedCharacter)
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
