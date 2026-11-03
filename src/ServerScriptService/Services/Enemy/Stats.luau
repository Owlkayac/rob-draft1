--!strict
-- 天敵の「いまの数字」を求める部品。
-- いまの数字 = 基本の数字(Definition.BaseStats)× 補正(モディファイア)の積。
-- 補正は Stats.RegisterModifier で登録する。季節などは、補正を1つ登録するだけで足せる。

local Types = require(script.Parent.Types)
local WarnOnce = require(script.Parent.WarnOnce)
local RoundService = require(script.Parent.Parent.RoundService)
local SetupService = require(script.Parent.Parent.SetupService)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Stats = {}

type ModifierEntry = {
	Name: string,
	Fn: Types.ModifierFn,
}

local modifiers: { ModifierEntry } = {}

-- 補正を登録する。同じ名前がすでにあれば、置き換える
function Stats.RegisterModifier(name: string, fn: Types.ModifierFn)
	for index, entry in modifiers do
		if entry.Name == name then
			modifiers[index] = { Name = name, Fn = fn }
			return
		end
	end
	table.insert(modifiers, { Name = name, Fn = fn })
end

-- 補正を1つ外す(なければ何もしない)
function Stats.UnregisterModifier(name: string)
	for index, entry in modifiers do
		if entry.Name == name then
			table.remove(modifiers, index)
			return
		end
	end
end

-- 補正の名前と理由を、同じ警告は1回だけ出す
local function warnModifier(entryName: string, reason: string)
	WarnOnce.Warn("modifier:" .. entryName .. ":" .. reason, `[Stats] 補正 {entryName}: {reason}。1倍として扱います`)
end

-- 倍率として使える数字か(数字で、NaN・無限大ではなく、0より大きい)
local function isValidMultiplier(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

-- 1つの補正を呼んで、statName にかける倍率を返す。
-- 補正がエラーでも、おかしな値を返しても、1 倍として扱う(ゲームを止めない)
local function multiplierOf(entry: ModifierEntry, info: Types.ModifierInfo, statName: string): number
	local ok, result = pcall(entry.Fn, info)
	if not ok then
		warnModifier(entry.Name, `エラーが起きました: {result}`)
		return 1
	end
	local raw: any = result -- 関数が何を返しても受け取れるように any にして、中身を自分で確かめる
	if raw == nil then
		return 1
	end
	if type(raw) ~= "table" then
		warnModifier(entry.Name, "返り値が table ではありません")
		return 1
	end
	local value = (raw :: { [any]: any })[statName]
	if value == nil then
		return 1 -- この数字には、補正をかけない
	end
	if not isValidMultiplier(value) then
		warnModifier(entry.Name, `{statName} の倍率が使えない値です(数字で、0より大きく、有限である必要があります)`)
		return 1
	end
	return value :: number
end

-- いまの数字を返す。player は狙う相手(補正が使う。なければ nil)
function Stats.Get(definition: Types.Definition, statName: string, player: Player?): number
	local base = definition.BaseStats[statName]
	if base == nil then
		WarnOnce.Warn("stat:" .. definition.Name .. statName, `[Stats] {definition.Name} に基本の数字 {statName} がありません`)
		return 0
	end
	local info: Types.ModifierInfo = { Definition = definition, Player = player }
	local value = base
	for _, entry in modifiers do
		value *= multiplierOf(entry, info, statName)
	end
	return value
end

-- ===== 最初から登録しておく補正 =====

-- 稲の成長による見つかりにくさ(仕様書 003)。発見距離に、段階ごとの倍率をかける
Stats.RegisterModifier("RiceGrowth", function(info: Types.ModifierInfo): Types.StatTable?
	local player = info.Player
	if player == nil then
		return nil
	end
	return { SightDistance = RoundService.GetSightMultiplier(player) }
end)

-- 難易度による補正(仕様書 015)。農家さんの「見つけやすさ・気づく早さ・勘・しつこさ」に、難易度の倍率をかける。
-- 難易度は、狙っているプレイヤー(info.Player)のもの。いなければ(見回りの「勘」など)、
-- いちばん新しく「スタート」を押したプレイヤーのもの。
-- 追跡の速さの上限(ChaseSpeedMax)と、稲刈り機の速さは、公平さのために、変えない(ここでは触らない)。
-- 稲刈り機の「入るまでの待ち」は、倍率ではなく足し算なので、Sweep が SetupService から読む。

-- 難易度の数字の表から、倍率を1つ取り出す。使えない値(数字でない・0以下・NaN・無限大)なら 1
local function getMultiplier(params: { [string]: number }, name: string): number
	local value = params[name]
	if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 1
	end
	return value
end

-- 倍率 multiplier を、基本の数字 base にかけた結果が lowest 未満にならないように、倍率を直す。
-- base が lowest 以下なら、基本の数字より大きくはしない(下限を理由に、強めない)
local function raiseMultiplierToFloor(multiplier: number, base: number?, lowest: number): number
	if base == nil or base <= 0 then
		return multiplier
	end
	return math.max(multiplier, math.min(1, lowest / base))
end

-- 倍率 multiplier を、基本の数字 base にかけた結果が 1 を超えないように、倍率を直す(確率用)
local function capMultiplierToOne(multiplier: number, base: number?): number
	if base == nil or base <= 0 then
		return multiplier
	end
	return math.min(multiplier, math.max(1 / base, 1))
end

Stats.RegisterModifier("Difficulty", function(info: Types.ModifierInfo): Types.StatTable?
	local base = info.Definition.BaseStats
	if base.SightDistance == nil then
		return nil -- 見つける数字を持たない天敵(稲刈り機)は、対象外(毎フレーム読まれるので、早めに戻る)
	end
	local player = info.Player
	local params = if player ~= nil then SetupService.GetDifficultyParams(player) else SetupService.GetLatestDifficultyParams()

	local noticeMultiplier = getMultiplier(params, "FarmerNoticeMultiplier")
	local loseSight = getMultiplier(params, "FarmerLoseSightMultiplier")
	local floorSeconds = Config.DifficultyNoticeFloorSeconds
	return {
		SightDistance = getMultiplier(params, "FarmerSightMultiplier"),
		-- 気づく間(短くしても、最低 DifficultyNoticeFloorSeconds は守る)
		NoticeSecondsMin = raiseMultiplierToFloor(noticeMultiplier, base.NoticeSecondsMin, floorSeconds),
		NoticeSecondsMax = raiseMultiplierToFloor(noticeMultiplier, base.NoticeSecondsMax, floorSeconds),
		HunchChance = capMultiplierToOne(getMultiplier(params, "FarmerHunchMultiplier"), base.HunchChance), -- 確率は 1 を超えない
		LoseSightSecondsMin = loseSight,
		LoseSightSecondsMax = loseSight,
	}
end)

return Stats
