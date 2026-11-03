--!strict
-- 「同じ警告は1回だけ」出すための小さな部品。
-- 毎回の判断(0.2秒ごと)で同じエラーが出ると、画面(Output)が警告でいっぱいになるので、
-- key(警告の見出し)ごとに、最初の1回だけ warn を出す。
-- この部品は、何も読み込まない(循環 require を防ぐため)。

local WarnOnce = {}

local warned: { [string]: boolean } = {} -- 出した警告の記録

-- key が初めてなら、message を warn で出す。2回目からは何もしない
function WarnOnce.Warn(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(message)
end

return WarnOnce
