# ============================================================================
# platinum_transpiler.jl  (v3.2 : デバッグ修正版)
#   使い方:
#     1. DSL → MQL5    : julia platinum_transpiler.jl strategy.platinum
#     2. DLL の生成     : julia -e 'include("platinum_transpiler.jl"); ...' (下記参照)
#
# [修正履歴 v3.1 → v3.2]
#   Bug 1: using Statistics (mean) が missing → 追加
#   Bug 2: PlatinumEngine内の using .Finance → using Main.Finance に修正
#   Bug 3: path_dependent_mc が未実装 (return なし) → 完全実装
#   Bug 4: expr.args[3] != nothing → !isnothing() に修正
#   Bug 5: els != "" → !isempty(els) に修正
#   Bug 6: @capture パターンの ::Type アノテーション → 正しい形式に修正
#   Bug 7: logic = :() → :(begin end) に修正
# ============================================================================

# ---------- ① 内部実装モジュール (Finance) ----------
module Finance
    using Distributions: cdf, Normal
    using Random
    using Statistics: mean   # [Bug 1修正] mean() が未importだったため全MCが実行時エラーになっていた

    nom(x) = cdf(Normal(), x)

    function call_price(S, K, r, σ, T)
        d1 = (log(S/K) + (r + 0.5*σ^2)*T) / (σ*sqrt(T))
        d2 = d1 - σ*sqrt(T)
        return S * nom(d1) - K * exp(-r*T) * nom(d2)
    end

    function put_price(S, K, r, σ, T)
        return call_price(S, K, r, σ, T) - S + K*exp(-r*T)
    end

    function delta(S, K, r, σ, T, is_call)
        d1 = (log(S/K) + (r + 0.5*σ^2)*T) / (σ*sqrt(T))
        return is_call ? nom(d1) : nom(d1) - 1.0
    end

    # ★ eruVolatility
    function eruVolatility(S, K, r, T, method)
        if method == 0
            σ_hist = 0.18
            σ_imp  = 0.22
            return (σ_hist + σ_imp) / 2.0
        elseif method == 1
            return 0.20
        else
            error("Invalid method for eruVolatility")
        end
    end

    # ---------- ★ 内部用：標準モンテカルロエンジン ----------
    function mc_engine(S0, K, r, σ, T, steps, sims, payoff_fn::Function)
        dt = T / steps
        drift = (r - 0.5*σ^2) * dt
        vol_dt = σ * sqrt(dt)
        payoffs = zeros(sims)
        for i in 1:sims
            S = S0
            for _ in 1:steps
                S *= exp(drift + vol_dt * randn())
            end
            payoffs[i] = payoff_fn(S)
        end
        return exp(-r * T) * mean(payoffs)
    end

    # ---------- ★ 経路依存型MC ----------
    # [Bug 3修正] 未実装のスケルトンだった → payoff_fn が経路全体を受け取る形で完全実装
    #   payoff_fn(path::Vector{Float64}) -> Float64
    function path_dependent_mc(S0, r, σ, T, steps, sims, payoff_fn::Function)
        dt = T / steps
        drift = (r - 0.5*σ^2) * dt
        vol_dt = σ * sqrt(dt)
        payoffs = zeros(sims)
        for i in 1:sims
            path = Vector{Float64}(undef, steps + 1)
            path[1] = S0
            for j in 1:steps
                path[j+1] = path[j] * exp(drift + vol_dt * randn())
            end
            payoffs[i] = payoff_fn(path)
        end
        return exp(-r * T) * mean(payoffs)
    end

    """
        eru_price(S, K, r, σ, T, steps, sims, option_type, param1, param2)

    あらゆるエキゾチック・オプションの理論価格を計算する。
    - `option_type`: "call", "put", "asian_call_arith", "asian_call_geom",
                    "barrier_uo_call", "barrier_do_put",
                    "lookback_call_float", "lookback_put_float"
    - `param1`, `param2`: オプションタイプに応じた追加パラメータ
    """
    function eru_price(S, K, r, σ, T, steps, sims, option_type::String, param1=0.0, param2=0.0)
        dt = T / steps
        drift = (r - 0.5*σ^2) * dt
        vol_dt = σ * sqrt(dt)

        if option_type == "call"
            return mc_engine(S, K, r, σ, T, steps, sims, (ST) -> max(ST - K, 0.0))

        elseif option_type == "put"
            return mc_engine(S, K, r, σ, T, steps, sims, (ST) -> max(K - ST, 0.0))

        elseif option_type == "asian_call_arith"
            # [Bug 3修正] path_dependent_mc を活用
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                avg = mean(path[2:end])   # S0 を除いた算術平均
                max(avg - K, 0.0)
            end)

        elseif option_type == "asian_call_geom"
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                log_avg = mean(log.(path[2:end]))
                max(exp(log_avg) - K, 0.0)
            end)

        elseif option_type == "barrier_uo_call"
            B = param1   # アップアウト・バリア
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                knocked_out = any(s -> s >= B, path)
                knocked_out ? 0.0 : max(path[end] - K, 0.0)
            end)

        elseif option_type == "barrier_do_put"
            B = param1   # ダウンアウト・バリア
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                knocked_out = any(s -> s <= B, path)
                knocked_out ? 0.0 : max(K - path[end], 0.0)
            end)

        elseif option_type == "lookback_call_float"
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                max(path[end] - minimum(path), 0.0)
            end)

        elseif option_type == "lookback_put_float"
            return path_dependent_mc(S, r, σ, T, steps, sims, (path) -> begin
                max(maximum(path) - path[end], 0.0)
            end)

        else
            error("Unsupported option type: $option_type")
        end
    end
end

# ---------- ② DLL用 @ccallable エクスポートモジュール ----------
module PlatinumEngine
    using Base: @ccallable
    using Main.Finance   # [Bug 2修正] using .Finance → using Main.Finance
                         # Finance と PlatinumEngine は同レベルのトップレベルモジュールのため
                         # .Finance (親モジュール内サブモジュールの記法) は UndefVarError になる

    Base.@ccallable function call_price(S::Cdouble, K::Cdouble, r::Cdouble, sigma::Cdouble, T::Cdouble)::Cdouble
        return Finance.call_price(S, K, r, sigma, T)
    end

    Base.@ccallable function delta(S::Cdouble, K::Cdouble, r::Cdouble, sigma::Cdouble, T::Cdouble, is_call::Cint)::Cdouble
        return Finance.delta(S, K, r, sigma, T, Bool(is_call))
    end

    Base.@ccallable function eruVolatility(S::Cdouble, K::Cdouble, r::Cdouble, T::Cdouble, method::Cint)::Cdouble
        return Finance.eruVolatility(S, K, r, T, method)
    end

    Base.@ccallable function eru_price(S::Cdouble, K::Cdouble, r::Cdouble, sigma::Cdouble, T::Cdouble,
                                       steps::Cint, sims::Cint, option_type::Cstring,
                                       param1::Cdouble, param2::Cdouble)::Cdouble
        return Finance.eru_price(S, K, r, sigma, T, steps, sims, unsafe_string(option_type), param1, param2)
    end
end

# ---------- ③ DSL トランスパイラ ----------
using MacroTools: @capture

mutable struct Strategy
    name::String
    symbol::String
    timeframe::Int
    params::Dict{String, Any}
    logic::Expr
end

function parse_strategy(expr)
    name     = "MyEA"
    symbol   = "EURUSD"
    tf       = 15
    params   = Dict{String, Any}()
    logic    = :(begin end)   # [Bug 7修正] :() は Expr(:tuple) を生成するため不正
                               # 空ブロックは :(begin end) が正しい

    for stmt in expr.args
        # [Bug 6修正] @capture パターンの ::Type アノテーションは MacroTools では
        # 型マッチではなくリテラルとして解釈されるため誤動作する
        # 正しくは引数形式 @capture(stmt, strategy(s_)) か変数チェックを別途行う
        if @capture(stmt, strategy(s_))
            name = string(s_)
        elseif @capture(stmt, symbol(sym_))
            symbol = string(sym_)
        elseif @capture(stmt, timeframe(tf_))
            tf = Int(tf_)
        elseif @capture(stmt, var_ = val_)
            params[string(var_)] = val_
        else
            logic = stmt
        end
    end
    Strategy(name, symbol, tf, params, logic)
end

function translate_expr(expr, indent=0)
    if expr isa Expr
        if expr.head == :call
            fname = string(expr.args[1])
            args  = expr.args[2:end]
            return "$fname($(join(translate_expr.(args, indent), ", ")))"

        elseif expr.head == :if
            cond = translate_expr(expr.args[1])
            body = translate_expr(expr.args[2])
            # [Bug 4修正] != nothing → !isnothing() で同一性チェックを明示
            # [Bug 5修正] els != "" → !isempty(els) に変更
            if length(expr.args) >= 3 && !isnothing(expr.args[3])
                els = translate_expr(expr.args[3])
                return "if($cond) {\n$body\n}$((!isempty(els)) ? " else {\n$els\n}" : "")"
            else
                return "if($cond) {\n$body\n}"
            end
        else
            return string(expr)
        end

    elseif expr isa Symbol
        sym = string(expr)
        if     sym == "close"   return "iClose(_Symbol, 0, 0)"
        elseif sym == "open"    return "iOpen(_Symbol, 0, 0)"
        elseif sym == "high"    return "iHigh(_Symbol, 0, 0)"
        elseif sym == "low"     return "iLow(_Symbol, 0, 0)"
        elseif sym == "volume"  return "iVolume(_Symbol, 0, 0)"
        else return sym
        end
    else
        return string(expr)
    end
end

function generate_mql5(strat::Strategy)
    lib = """
#import "PlatinumEngine.dll"
double call_price(double S, double K, double r, double sigma, double T);
double delta(double S, double K, double r, double sigma, double T, int is_call);
double eruVolatility(double S, double K, double r, double T, int method);
double eru_price(double S, double K, double r, double sigma, double T,
                 int steps, int sims, string option_type,
                 double param1, double param2);
#import

//+------------------------------------------------------------------+
//| Expert: $(strat.name)  Symbol: $(strat.symbol)  TF: $(strat.timeframe)
//+------------------------------------------------------------------+
int OnInit() { return(INIT_SUCCEEDED); }
void OnTick() {
$(translate_expr(strat.logic, 1))
}
"""
    return lib
end
