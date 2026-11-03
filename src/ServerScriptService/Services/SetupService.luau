--!strict
-- スタートメニューと難易度の「選んだ内容」をサーバーで管理する部品。仕様書 015。
-- プレイヤーごとに、次の3つを持つ(Player をキーにした表。将来、複数人でも動くように):
--   ・フェーズ: "Menu"(メニューを見ている。ゲームは始まっていない)/ "Playing"(ゲームを始めた)
--   ・やくわり(Role): "Crayfish"(ザリガニ)/ "Farmer"(農家さん。仕様書 016)
--   ・なんいど(Difficulty): "Easy" / "Normal" / "Hard"
-- クライアントからのお願い(StartRequest・MenuRequest)を、ここで確認する。
-- この部品は、ほかのサービス(RoundService など)を読み込まない(循環 require を防ぐため)。
--   依頼の向き: RoundService・ScoreService・CrayfishService・Stats などが、この部品を読み込んで呼ぶ。
--   スタートやメニュー戻りで「何かをしたい」部品は、OnStart・OnMenu に関数を登録する。
-- 仕様書 016:選んだ「やくわり」「なんいど」は、Player の Attribute("Role"・"Difficulty")にも入れる。
--   Attribute は「名前つきのメモ」で、クライアントも読める(画面が、やくわりで文言や表示を変えるため)。
--   メニューに戻っても、Role は既定に戻さない(ラウンド中かどうかは、RoundState で分かる)。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

-- フェーズの名前
export type Phase = "Menu" | "Playing"

-- プレイヤー1人ぶんの、選んだ内容
type PlayerSetup = {
	Phase: Phase,
	Role: string,
	Difficulty: string,
	CanReturnToMenu: boolean, -- 結果の画面(つかまった・クリア)で、「メニューへ」を押せる状態か(RoundService が教える)
	LastStartAt: number, -- 最後に「スタート」を受け付けた時刻(os.clock)
	LastMenuAt: number, -- 最後に「メニューへ」を受け付けた時刻(os.clock)
}

local SetupService = {}

-- Player をキーにした表
local setups: { [Player]: PlayerSetup } = {}
-- いちばん新しく「スタート」を押したプレイヤー(一人用の間は、天敵の数字をこの人の難易度に合わせる)
local latestStarter: Player? = nil
local startCallbacks: { (Player) -> () } = {}
local menuCallbacks: { (Player) -> () } = {}
local started = false

-- 選んだ内容を、クライアントが読める Attribute にも入れる
local function publishChoice(player: Player, role: string, difficulty: string)
	player:SetAttribute("Role", role)
	player:SetAttribute("Difficulty", difficulty)
end

local function newSetup(): PlayerSetup
	return {
		Phase = "Menu",
		Role = Config.DefaultRole,
		Difficulty = Config.DefaultDifficulty,
		CanReturnToMenu = false,
		LastStartAt = -math.huge,
		LastMenuAt = -math.huge,
	}
end

-- 難易度の名前から、数字の表を返す。なければ Config.DefaultDifficulty の表、それもなければ空の表
local function lookupParams(difficulty: string): { [string]: number }
	local params = Config.Difficulties[difficulty]
	if params ~= nil then
		return params
	end
	local fallback = Config.Difficulties[Config.DefaultDifficulty]
	if fallback ~= nil then
		return fallback
	end
	return {}
end

-- 登録された関数を、別のスレッドで呼ぶ。1つがエラーでも、ほかは呼ぶ
local function fireCallbacks(callbacks: { (Player) -> () }, player: Player)
	for _, callback in callbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player)
			if not ok then
				warn(`[SetupService] 登録された関数でエラーが出ました: {err}`)
			end
		end)
	end
end

-- 「スタート」のお願いを確認して、受け付ける。検証に通らないお願いは、黙って捨てる
local function onStartRequest(player: Player, role: unknown, difficulty: unknown, ...: unknown)
	local setup = setups[player] -- (a) 状態があるか
	if not setup then
		return
	end
	if select("#", ...) ~= 0 then -- (b) 余分な引数
		return
	end
	if typeof(role) ~= "string" or typeof(difficulty) ~= "string" then -- (c) 型
		return
	end
	if Config.Roles[role] == nil or Config.Difficulties[difficulty] == nil then -- (d) 許される文字列か
		return
	end
	if setup.Phase ~= "Menu" then -- (e) メニューのときだけ
		return
	end
	local now = os.clock()
	if now - setup.LastStartAt < Config.StartRequestMinInterval then -- (f) 連打
		return
	end
	setup.LastStartAt = now

	setup.Role = role
	setup.Difficulty = difficulty
	publishChoice(player, role, difficulty) -- クライアントに先に伝える(RoundState が届く前に、やくわりが分かるように)
	setup.Phase = "Playing"
	setup.CanReturnToMenu = false
	latestStarter = player
	fireCallbacks(startCallbacks, player)
end

-- 「メニューへ」のお願いを確認して、受け付ける。検証に通らないお願いは、黙って捨てる
local function onMenuRequest(player: Player, ...: unknown)
	local setup = setups[player] -- (a) 状態があるか
	if not setup then
		return
	end
	if select("#", ...) ~= 0 then -- (b) 値なしのはず
		return
	end
	if setup.Phase ~= "Playing" or not setup.CanReturnToMenu then -- (c) 結果の画面(終わったあと)のときだけ
		return
	end
	local now = os.clock()
	if now - setup.LastMenuAt < Config.MenuRequestMinInterval then -- (d) 連打
		return
	end
	setup.LastMenuAt = now

	setup.Phase = "Menu"
	setup.CanReturnToMenu = false
	fireCallbacks(menuCallbacks, player)
end

local function onPlayerAdded(player: Player)
	if setups[player] then
		return
	end
	local setup = newSetup()
	setups[player] = setup
	publishChoice(player, setup.Role, setup.Difficulty)
end

local function onPlayerRemoving(player: Player)
	setups[player] = nil
	if latestStarter == player then
		latestStarter = nil
	end
end

function SetupService.Start()
	if started then
		return
	end
	started = true

	local startEvent = Instance.new("RemoteEvent")
	startEvent.Name = Config.StartRequestRemoteName
	startEvent.Parent = ReplicatedStorage
	startEvent.OnServerEvent:Connect(onStartRequest)

	local menuEvent = Instance.new("RemoteEvent")
	menuEvent.Name = Config.MenuRequestRemoteName
	menuEvent.Parent = ReplicatedStorage
	menuEvent.OnServerEvent:Connect(onMenuRequest)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

-- いまのフェーズ。状態がない(まだ入っていない・退出した)ときは "Menu"
function SetupService.GetPhase(player: Player): Phase
	local setup = setups[player]
	if setup == nil then
		return "Menu"
	end
	return setup.Phase
end

-- いまの「やくわり」("Crayfish" か "Farmer")
function SetupService.GetRole(player: Player): string
	local setup = setups[player]
	if setup == nil then
		return Config.DefaultRole
	end
	return setup.Role
end

-- いまの「なんいど」("Easy" か "Normal" か "Hard")
function SetupService.GetDifficulty(player: Player): string
	local setup = setups[player]
	if setup == nil then
		return Config.DefaultDifficulty
	end
	return setup.Difficulty
end

-- このプレイヤーの難易度の数字の表(Config.Difficulties[難易度])。なければ Normal の表
function SetupService.GetDifficultyParams(player: Player): { [string]: number }
	return lookupParams(SetupService.GetDifficulty(player))
end

-- いちばん新しく「スタート」を押したプレイヤーの、難易度の数字の表。誰もいなければ Normal の表
function SetupService.GetLatestDifficultyParams(): { [string]: number }
	local starter = latestStarter
	if starter == nil or setups[starter] == nil then
		return lookupParams(Config.DefaultDifficulty)
	end
	return SetupService.GetDifficultyParams(starter)
end

-- フェーズを変える(RoundService が、準備中のやくわりをメニューに戻すときなどに使う)。
-- "Menu" にすると、「メニューへ」を押せる状態は解除される
function SetupService.SetPhase(player: Player, phase: Phase)
	local setup = setups[player]
	if setup == nil then
		return
	end
	setup.Phase = phase
	if phase == "Menu" then
		setup.CanReturnToMenu = false
	end
end

-- 結果の画面(終わったあと)で「メニューへ」を押せる状態かを、RoundService が教える
function SetupService.SetCanReturnToMenu(player: Player, canReturn: boolean)
	local setup = setups[player]
	if setup == nil then
		return
	end
	setup.CanReturnToMenu = canReturn
end

-- 「スタート」が受け付けられたときに呼ぶ関数を登録する(引数はそのプレイヤー)。
-- 呼ばれたときは、すでにフェーズが "Playing" で、やくわり・なんいども決まっている
function SetupService.OnStart(callback: (Player) -> ())
	table.insert(startCallbacks, callback)
end

-- 「メニューへ」が受け付けられたときに呼ぶ関数を登録する(引数はそのプレイヤー)。
-- 呼ばれたときは、すでにフェーズが "Menu" になっている
function SetupService.OnMenu(callback: (Player) -> ())
	table.insert(menuCallbacks, callback)
end

return SetupService
