--!strict
-- 音のID(素材の番号)を安全に扱う部品。サーバーとクライアントの両方が使う。(仕様書 011)
-- ID は Config.SoundIds に入れる。空なら「音なし」。形が正しくなければ、警告を1回だけ出して「音なし」にする。

local Config = require(script.Parent.Config)

local SoundUtil = {}

local ID_PREFIX = "rbxassetid://"
local DEFAULT_VOLUME = 0.5 -- Config.SoundVolumes にない種類の音量

local warned: { [string]: boolean } = {} -- 警告を出した音の名前(同じ名前は1回だけ)

-- ID の形が正しいか。「rbxassetid://」のあとが、数字だけ(1文字以上)のときだけ true
function SoundUtil.IsValidId(id: any): boolean
	if typeof(id) ~= "string" then
		return false
	end
	local idString = id :: string
	if string.sub(idString, 1, #ID_PREFIX) ~= ID_PREFIX then
		return false
	end
	local digits = string.sub(idString, #ID_PREFIX + 1)
	return string.match(digits, "^%d+$") ~= nil
end

-- 音の名前(Ambient など)から、使ってよい ID を返す。空・形が正しくない・未登録なら nil
function SoundUtil.GetId(name: string): string?
	local id = Config.SoundIds[name]
	if id == nil or id == "" then
		return nil -- 空は「鳴らさない」。警告も出さない
	end
	if not SoundUtil.IsValidId(id) then
		if not warned[name] then
			warned[name] = true
			warn(`[SoundUtil] {name} の ID の形が正しくありません(rbxassetid://数字 の形にしてください)。この音は鳴らしません。`)
		end
		return nil
	end
	return id
end

-- 音の名前から、音量(0〜1)を返す。Config になければ 0.5
function SoundUtil.GetVolume(name: string): number
	local volume = Config.SoundVolumes[name]
	if typeof(volume) ~= "number" then
		return DEFAULT_VOLUME
	end
	return math.clamp(volume, 0, 1)
end

return SoundUtil
