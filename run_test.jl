using Base.GC
using TimerOutputs

using Pkg
Pkg.activate(@__DIR__)

using Distributed
@everywhere using Pkg
@everywhere Pkg.activate(@__DIR__)
using LadderDGA
@everywhere using LadderDGA

cfg_file = "/home/julian/Hamburg/ED_data/asympt_tests/config_14_small.toml"
@timeit LadderDGA.to "input" mP, sP, env, kGridsStr = readConfig(cfg_file);
@timeit LadderDGA.to "setup" Σ_ladderLoc, Σ_loc, imp_density, kG, gLoc_fft, gLoc_rfft, Γsp, Γch, χDMFTsp, χDMFTch, locQ_sp, locQ_ch, χ₀Loc, gImp = setup_LDGA(kGridsStr[1], mP, sP, env);

# ladder quantities
@info "bubble"
@timeit LadderDGA.to "nl bblt par" bubble_par = calc_bubble_par(gLoc_fft, gLoc_rfft, kG, mP, sP);
@timeit LadderDGA.to "nl bblt" bubble = calc_bubble(gLoc_fft, gLoc_rfft, kG, mP, sP);

@timeit LadderDGA.to "λ₀" begin
    Fsp = F_from_χ(χDMFTsp, gImp[1,:], sP, mP.β);
    λ₀ = calc_λ0(bubble, Fsp, locQ_sp, mP, sP)
end

@info "chi"
@timeit LadderDGA.to "nl xsp" nlQ_sp = calc_χγ(:sp, Γsp, bubble, kG, mP, sP);
@timeit LadderDGA.to "nl xsp par" nlQ_sp_par = LadderDGA.calc_χγ_par(:sp, Γsp, bubble, kG, mP, sP);
@info "parallel data agrees with sequential: " all(nlQ_sp_par.γ .≈ nlQ_sp.γ)
@timeit LadderDGA.to "nl xch" nlQ_ch = calc_χγ(:ch, Γch, bubble, kG, mP, sP);

λsp_old = λ_correction(:sp, imp_density, nlQ_sp, nlQ_ch, gLoc_rfft, λ₀, kG, mP, sP)
λsp_new = λ_correction(:sp_ch, imp_density, nlQ_sp, nlQ_ch, gLoc_rfft, λ₀, kG, mP, sP)

@info "Σ"
#@timeit LadderDGA.to "nl Σ" Σ_ladder = calc_Σ(nlQ_sp, nlQ_ch, bubble, gLoc_rfft, FUpDo, kG, mP, sP)
#Σ_ladder = Σ_loc_correction(Σ_ladder, Σ_ladderLoc, Σ_loc);
#G_λ = G_from_Σ(Σ_ladder)
#@timeit LadderDGA.to "nl Σ" Σ_ladder = calc_Σ(nlQ_sp, nlQ_ch, bubble, fft(G_λ), FUpDo, kG, mP, sP)
#Σ_ladder = Σ_loc_correction(Σ_ladder, Σ_ladderLoc, Σ_loc);
