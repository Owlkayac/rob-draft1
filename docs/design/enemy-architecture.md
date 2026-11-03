# 天敵の作り(拡張しやすい設計)の説明書

初心者向けの説明です。仕様書 002 の 8・9・10 に対応します。
ゲームの動きは変えずに、「あとから足しやすい形」に分けたものです。

## 用語

- **ModuleScript(モジュールスクリプト)**: ほかのスクリプトから `require` で呼び出して使う部品のファイル。
- **require**: 別のファイルを読み込んで、中の関数や表を使えるようにする命令。
- **ステートマシン**: 「いまの状態」を1つ持ち、条件で別の状態に切り替えながら動く仕組み。ここでは状態を「行動」と呼ぶ。
- **コンテキスト(ctx)**: 天敵1体の「いまの状態のメモ」。いまの行動、追っている相手、経路などが入っている表。
- **モディファイア(補正)**: 数字に「何倍か」をかける仕組み。季節で速さが変わる、などに使う。
- **経路探索**: 障害物をよけて、目的地までの道すじを計算する Roblox の機能(PathfindingService)。

## 1. 全体の図

```
Main.server.luau
   |  EnemyService.Start()
   v
EnemyService  ...全体の進行役(天敵を出す / ループを回す / やり直し)
   |
   |  毎回の判断(0.2秒ごと)、天敵ごとに:
   |   1. Perception.CheckCatch   捕まえる判定(どの行動の最中でも)
   |   2. Perception.Scan         見回して、見える相手を探す
   |   3. 行動.Update             いまの行動が、次の行動の名前を返す
   |   4. switchBehavior          行動の切り替え(Exit -> Enter)
   v
Enemy/
  Types.luau        型(データの形の約束)
  Stats.luau        数字の計算: 基本の数字 x 補正の積
  WarnOnce.luau     同じ警告を1回だけ出す小さな部品
  Perception.luau   見る・捕まえる
  Movement.luau     歩く(経路探索)
  Behaviors/
    Patrol.luau     見回り
    Chase.luau      追跡
    Search.luau     探す
    Sweep.luau      刈り取り(稲刈り機の動き)
  SweepRoute.luau   稲刈り機の通る道すじの計算
  Definitions/
    Farmer.luau     天敵の種類「農家さん」の定義
    Harvester.luau  天敵の種類「稲刈り機」の定義
```

読み込みの向きは、いつも一方向です(ぐるっと回って読み込む「循環 require」を作らない)。

```
Types / WarnOnce -> Stats -> Perception -> Movement -> Behaviors -> Definitions -> EnemyService
Config -> SweepRoute -> Sweep(Behaviors)、Harvester(Definitions)   ※ SweepRoute は Config だけを読む
```

## 2. 各ファイルの役割

| ファイル | 役割 |
|---|---|
| `Services/EnemyService.luau` | 全体の進行役。定義の一覧から天敵を作り、動きのループを1つ回し、「もう一度」でやり直す。天敵ごとの状態は `slots` の表に持つ(将来、天敵が複数になっても動く)。 |
| `Enemy/Types.luau` | 共有する型。`Context`(状態のメモ)、`Behavior`(行動)、`ModifierFn`(補正)、`Definition`(天敵の定義)。処理は入っていない。 |
| `Enemy/WarnOnce.luau` | `WarnOnce.Warn(見出し, 文)` で、同じ見出しの警告を 1 回だけ出す。毎回の判断で同じエラーが続いても、Output が警告であふれない。 |
| `Enemy/Stats.luau` | `Stats.Get(定義, "数字の名前", 相手)` で、いまの数字を返す。`Stats.RegisterModifier(名前, 関数)` で補正を足す。最初から "RiceGrowth"(稲の成長で発見距離が縮む)が登録されている。 |
| `Enemy/Perception.luau` | 見える・見えないの判定、いちばん近い相手、捕まえる判定。距離は横方向(XZ)だけで測る。 |
| `Enemy/Movement.luau` | 目的地へ歩く。経路を作り直す、作れなければ直接向かう、古い計算結果を捨てる(世代番号)。 |
| `Enemy/Behaviors/*.luau` | 行動1つにつき1ファイル。`Enter`(切り替わった時に1回)、`Update`(毎回。次の行動の名前か nil を返す)、`Exit`(やめる時に1回)。 |
| `Enemy/Definitions/*.luau` | 天敵の種類1つにつき1ファイル。名前、見た目の作り方、足元の高さの補正、基本の数字、使う行動、最初の行動。 |
| `ServerStorage/Modules/FarmerModel.luau` | 農家さんの見た目(モデル)を作る。大きさ(`FarmerScale`)もここで反映し、実際に使った倍率を返す。足元の高さの測り方(`GetFootY`)と置き方(`PlaceAt`)もここ。 |
| `Shared/Config.luau` | 数字の置き場所。コードに数字を直接書かない。 |

捕まえる判定は、行動の中ではなく、EnemyService が毎回の最初に行います。
これで、見回り・追跡・探すのどの最中でも、同じルールで判定されます。

## 3. 新しい天敵の種類を足す手順(サギを例に)

1. **見た目の部品を作る**: `ServerStorage/Modules/HeronModel.luau`。`Create()`(モデルと、実際の倍率を返す)、`GetFootY(model)`(足元の高さ)、`PlaceAt(model, point)`(置いて、足元の高さを補正する)、`ClaimServerOwnership(model)` を、`FarmerModel.luau` をまねて作る。外部の素材を使うときは、先に `assets/CREDITS.md` に記録する。
2. **Config に数字を足す**: 例 `HeronWalkSpeed`、`HeronSightDistance`、`HeronScale` など。
3. **定義を作る**: `Enemy/Definitions/Heron.luau` を `Farmer.luau` のコピーから作り、名前・Create・BaseStats を直す。`Behaviors` には、使う行動だけを書く。`Search` は書かなくてもよい。そのときは、追跡中に相手が潜って、最後に見えた位置に着くと、`Chase` が `Behaviors.Search` の有無を見て、なければ見回り(`Patrol`)に戻る。`Patrol` と `Chase` は必ず書く。
   定義には、次の項目も必要(`Types.Definition` の型どおりに書く)。
   - `GetFootY`: モデルの足元の高さ(ワールドのY)を返す関数。`model:GetBoundingBox()` の底(CFrame の y − size.y/2)で求める。経路探索の始点に使われる。
   - `PlaceAt`: `PlaceAt(model, point)`。モデルを point の横位置に置き、足元が「ゆか上面(`Config.FieldFloorTopY`) + 余裕」になるよう `PivotTo` で補正する関数。出現のときと、「もう一度」の位置戻しのとき、`EnemyService` が呼ぶ。余裕の数字(農家さんは `Config.FarmerSpawnMargin`)は、定義側(`FarmerModel`)が持ち、`EnemyService` は知らない。
   - `OnPlaced`: Workspace に入れた直後に呼ばれる関数。動きの計算をサーバーにする(`SetNetworkOwner(nil)`)など。何もしないなら、空の関数でよい。
   - 大きさを変える種類は、`Create` の中で実際の倍率を `BaseStats` の距離の数字に反映する(`Farmer.luau` の `applyScale` を参照)。
   `BaseStats` の数字の名前は、行動が使うものをそろえる(下の「数字の名前」を見る)。
4. **一覧に登録する**: `EnemyService.luau` の `definitions` に足す。

```lua
-- EnemyService.luau は Services/ にあるので、Enemy フォルダは script.Parent.Enemy
local Heron = require(script.Parent.Enemy.Definitions.Heron)

local definitions: { Types.Definition } = {
	Farmer,
	Heron, -- ここに足す
}
```

   **`require` の注意**: `script.Parent` の数は、ファイルの場所で変わる。`script` は「そのファイル自身」で、`script.Parent` は「ひとつ上のフォルダ」。
   - `Services/EnemyService.luau` から: `script.Parent.Enemy.Types`(Services の中の Enemy)
   - `Services/Enemy/Perception.luau` や `Movement.luau` から: `script.Parent.Types`(同じ Enemy フォルダの中)
   - `Services/Enemy/Behaviors/Chase.luau` や `Definitions/Farmer.luau` から: `script.Parent.Parent.Types`(Behaviors / Definitions の1つ上が Enemy)
   - `Behaviors` から `Services/CrayfishService` を読むなら: `script.Parent.Parent.Parent.CrayfishService`
   ファイルを別のフォルダに移したら、`script.Parent` の数を数え直すこと。
5. Studio で確認する。出現位置は、見回り地点を順にずらして決まる。

数字の名前(`BaseStats` に書くもの): `WalkSpeed`、`ChaseSpeed`、`SightDistance`、`CatchDistance`、`CatchHiddenDistance`、`PatrolArriveDistance`、`WaypointReachDistance`、`AgentRadius`、`AgentHeight`、`LoseSightSeconds`、`SearchSeconds`、`Speed`(稲刈り機の進む速さ)。

注意: 仕様書 002 の 6 に「天敵の複数種類は後で追加する」とあるので、サギを実際に足す前に、仕様書を書くこと。

## 4. 新しい行動を足す手順

例として、「その場で立ち止まって、まわりを見る」行動 `Wait` を考える(例です。まだ作っていません)。

1. `Enemy/Behaviors/Wait.luau` を、`Search.luau` をまねて作る。

```lua
--!strict
local Types = require(script.Parent.Parent.Types)
local Movement = require(script.Parent.Parent.Movement)

local function enter(ctx: Types.Context)
	Movement.Stop(ctx)
end

local function update(ctx: Types.Context, dt: number): string?
	if ctx.Target then
		return "Chase" -- 相手が見えたら追跡へ
	end
	return nil -- 変えない
end

local function exit(ctx: Types.Context)
end

local Wait: Types.Behavior = { Enter = enter, Update = update, Exit = exit }
return Wait
```

2. 天敵の定義の `Behaviors` に足す: `Behaviors = { Patrol = Patrol, ..., Wait = Wait }`。
3. 別の行動の `Update` から、`return "Wait"` で切り替える。

きまり:
- `Update` は、次の行動の名前(文字)を返す。変えないなら `nil`。
- 名前が `Behaviors` の表にないと、警告が出て、最初の行動に戻る。
- 天敵が目で見た結果は `ctx.Target`(いちばん近い見える相手)に入っている。
- 数字は `Stats.Get` で取る。`Config` を直接読まない(補正が効かなくなるため)。
- `Movement.WalkTo` は、経路を待つ間、止まることがある。長い待ちや無限ループを `Update` に書かない。

## 5. 補正(モディファイア)を足す手順(季節を例に)

> **これは例です。季節は、まだ作っていません。** このコードは、ゲームに入っていません。

補正は、「どの数字に、何倍か」の表を返す関数です。いまの数字 = 基本の数字 × すべての補正の積。

```lua
-- (例・まだ使っていない) 冬は、天敵の歩く速さを0.8倍、発見距離を0.7倍にする
local Stats = require(script.Parent.Enemy.Stats)

Stats.RegisterModifier("SeasonWinter", function(info)
	if getCurrentSeason() ~= "Winter" then -- getCurrentSeason は、季節を作るときに作る関数(例)
		return nil -- 冬以外は、何もしない
	end
	return {
		WalkSpeed = 0.8,
		ChaseSpeed = 0.8,
		SightDistance = 0.7,
	}
end)
```

手順:
1. 季節の状態を持つ部品(例: `SeasonService`)を作る(仕様書が先)。
2. その中、または `Main.server.luau` で、`Stats.RegisterModifier` を呼ぶ。
3. 倍率は、季節ごとの数字を `Config` に置く(コードに直書きしない)。

知っておくこと:
- 補正の関数に渡る `info.Definition` は天敵の種類、`info.Player` は狙う相手(いない場合は nil)。種類や相手で、倍率を変えられる。
- 同じ名前で登録し直すと、置き換わる。`Stats.UnregisterModifier(名前)` で外せる。
- 補正の中でエラーが起きても、その補正は 1 倍として扱われる(ゲームは止まらない)。返り値が table でない、倍率が数字でない・0以下・NaN(数字でない値)・無限大のときも、1 倍として扱う。警告(補正の名前と理由)は、同じ内容なら 1 回だけ出る(`WarnOnce`)。
- 農家さんの速さは、行動に「切り替わった時」に読まれる(`Enter`)。稲刈り機の `Speed` は、`Sweep` が毎フレーム読むので、すぐ反映される。追跡の途中で季節が変わっても、次に切り替わるまで速さは変わらない。毎回読みたいときは、行動の `Update` で `Humanoid.WalkSpeed` を設定し直す。
- 発見距離と捕まえる距離は、毎回の判断で読まれるので、すぐ反映される。

## 6. Config の数字の意味と、調整のしかた

| 名前 | いまの値 | 意味 | 調整のしかた |
|---|---|---|---|
| `FarmerScale` | 2.5 | 農家さんの大きさ(標準の人型の何倍か)。見た目と、「距離」の数字(捕まえる距離、着いたとみなす距離、経路探索の体の大きさ)に効く。 | 大きくすると、迫力が出て、捕まえる距離も長くなる。大きくしすぎると、細い道を通れなくなることがある。変えたら、Studio で見た目と、地面にめり込まないかを確かめる。 |
| `FarmerSpeedMultiplier` | 1.0 | 歩く速さ(`FarmerWalkSpeed`、`FarmerChaseSpeed`)にかける倍率。 | 1.0 より大きくすると速くなる。ザリガニの速さは 16 なので、追跡の速さ(15 × 倍率)が 16 を超えると、逃げ切れなくなる。 |
| `FarmerCatchDistance` | 4 | 潜っていないときに捕まる距離(標準サイズ基準)。実際は × `FarmerScale`(いまは 10)。 | 小さくすると、捕まりにくい。 |
| `FarmerCatchHiddenDistance` | 2 | 潜っているときに捕まる距離(標準サイズ基準)。実際は × `FarmerScale`(いまは 5)。 | 0 に近づけると、潜ればほぼ安全。`FarmerCatchDistance` より大きくしないこと(潜るほうが危なくなる)。 |
| `FarmerSightDistance` | 30 | 発見できる距離。大きさの倍率はかけない。稲が育つと縮む(`SightMultipliers`)。 | 大きくすると、遠くから見つかる。 |

ほかの数字(`PatrolArriveDistance`、`WaypointReachDistance`、`PathAgentRadius`、`PathAgentHeight`)も、標準サイズ基準で、`FarmerScale` 倍で使われる。

数字の変えかた: `Config.luau` の値を書き換えて保存し、Studio で再生し直す(ゲームの途中では反映されない。農家さんの基本の数字は、ゲームの開始時と、モデルを作るたび(作り直し)に計算される)。

## 7. 「出番を決める」と「捕まえ方を変える」(稲刈り機が実際の例)

農家さんはずっといて、近づくと捕まえる天敵です。仕様書 006 の**稲刈り機(Harvester)**は、2つの点が違います。
そこで、定義(`Definition`)に、**書いても書かなくてもよい関数**を足せるようにしました。書かなければ、農家さんと同じ動きです。

| 任意の項目 | 意味 | 書かないと |
|---|---|---|
| `IsActive` | 「いま、出番か」を返す関数 | いつも出番(最初から作る) |
| `CheckCatch` | 捕まえる判定を、定義が決める関数 | 距離の判定(`Perception`)を使う |
| `ResetOnCatch` | 捕まえたあと、最初の行動に戻すか(`false` で戻さない) | 戻す |
| `FindBody` / `IsModelUsable` | Humanoid(人型の体)がない天敵のための、体の探し方・使えるかの確認 | 人型を探す・確認する |
| `SkipScan` | `true` で、毎回の「見回し」をしない | 見回す |

### 出番を決める(`IsActive`)
- `IsActive` を書いた天敵は、**最初は作られません**。0.2秒ごとの判断のたびに `IsActive()` を呼び、`true` になったら作り(spawn)、`false` になったらモデルを消します(despawn)。出番でない間は、モデルも判断もありません。
- `IsActive` を持つ種類は、「もう一度」で必ず消え、次の判断で出番があれば、最初から作り直される。
- 動きが最後まで終わった行動は、`ctx.Finished = true` にします。すると `EnemyService` がモデルを消し、出番が終わるまで作り直しません(出番が終わると、次の出番でまた出られます)。
- 稲刈り機の例:

```lua
-- Definitions/Harvester.luau(抜粋)
local function isActive(): boolean
	for _, player in Players:GetPlayers() do
		-- 遊んでいて、稲の段階が「出穂」(Config.HarvesterActiveStage)の人がいれば、出番
		if RoundService.IsPlaying(player) and RoundService.GetStage(player) == Config.HarvesterActiveStage then
			return true
		end
	end
	return false
end
```

### 捕まえ方を変える(`CheckCatch`)
- `CheckCatch(ctx, player, root)` は、遊んでいる人1人ごとに呼ばれ、捕まえるなら `true` を返します。捕まえたときの処理(`RoundService.NotifyCaught`)は `Perception` がやるので、定義は「捕まえるか」だけ答えます。
- 稲刈り機は、機械の向きと位置を考えた長方形(横 `HarvesterWidth`、長さ `HarvesterLength`)に入ったら捕まえます。`model:GetPivot():PointToObjectSpace(位置)` で「機械から見た座標」にすると、横が X、前後が Z になるので、絶対値を比べるだけで判定できます。高さは見ません。**潜っているかも見ない**ので、潜っても逃げられません。

### Humanoid を使わない天敵
- 稲刈り機は Humanoid も経路探索も使わず、`Sweep` 行動が `RunService.Heartbeat`(毎フレームの合図)で、`model:PivotTo(...)` で動かします。行動の `Exit` で、必ず `Disconnect`(つなぎを切る)します。
- そのため、`ctx.Humanoid` は `nil` のことがあります(`Movement` や `Patrol` などは、`nil` なら何もしません)。体の部品の探し方は `FindBody`、使えるかの確認は `IsModelUsable` で定義が決めます。

### 足し方の手順(まとめ)
1. 見た目の部品(`ServerStorage/Modules/HarvesterModel.luau`)と、行動(`Behaviors/Sweep.luau`)を作る。
2. 定義(`Definitions/Harvester.luau`)に、必要な任意の関数を書く。
3. `EnemyService` の `definitions` に足す(農家さんの次)。

