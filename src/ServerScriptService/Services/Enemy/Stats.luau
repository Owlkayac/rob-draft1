--!strict
-- 天敵の「いまの数字」を求める部品。
-- いまの数字 = 基本の数字(Definition.BaseStats)× 補正(モディファイア)の積。
-- 補正は Stats.RegisterModifier で登録する。季節などは、補正を1つ登録するだけで足せる。

local Types = require(script.Parent.Types)
local WarnOnce = require(script.Parent.WarnOnce)
local RoundService = require(script.Parent.Parent.RoundService)

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

return Stats
