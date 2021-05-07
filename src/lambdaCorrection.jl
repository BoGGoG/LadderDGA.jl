using IntervalArithmetic
using IntervalRootFinding

χ_λ(χ::AbstractArray, λ::Union{Float64,Interval{Float64}}) = map(χi -> 1.0 / ((1.0 / χi) + λ), χ)
χ_λ2(χ, λ) = map(χi -> 1.0 / ((1.0 / χi) + λ), χ)
χ_λ!(χ_λ, χ, λ::Union{Float64,Interval{Float64}}) = (χ_λ = map(χi -> 1.0 / ((1.0 / χi) + λ), χ))
dχ_λ(χ, λ::Union{Float64,Interval{Float64}}) = map(χi -> - ((1.0 / χi) + λ)^(-2), χ)

dΣch_λ_amp(G_plus_νq, γch, dχch_λ, qNorm) = -sum(G_plus_νq .* γch .* dχch_λ)*qNorm
dΣsp_λ_amp(G_plus_νq, γsp, dχsp_λ, qNorm) = -1.5*sum(G_plus_νq .* γsp .* dχsp_λ)*qNorm

function calc_λsp_rhs_usable(impQ_sp::ImpurityQuantities, impQ_ch::ImpurityQuantities, nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, kGrid::T1, mP::ModelParameters, sP::SimulationParameters) where T1 <: ReducedKGrid
    @warn "currently using min(usable_sp, usable_ch) for all calculations. relax this?"
    χch_ω = kintegrate(kGrid, nlQ_ch.χ, dim=2)[:,1]
    usable_ω = intersect(nlQ_sp.usable_ω, nlQ_ch.usable_ω)
    sh = get_sum_helper(usable_ω, sP)
    χch_sum = real(sum_freq(χch_ω[usable_ω], [1], sh, mP.β)[1])
    rhs = ((sP.tc_type != :nothing && sP.λ_rhs == :native) || sP.λ_rhs == :fixed) ? mP.n * (1 - mP.n/2) - χch_sum : real(impQ_ch.χ_loc + impQ_sp.χ_loc - χch_sum)
    #@info "tc:  $(sP.tc_type), rhs =  $rhs , $χch_sum , $(real(impQ_ch.χ_loc)) , $(real(impQ_sp.χ_loc)), $(real(χch_sum))"

    @info """Found usable intervals for non-local susceptibility of length 
          sp: $(nlQ_sp.usable_ω), length: $(length(nlQ_sp.usable_ω))
          ch: $(nlQ_ch.usable_ω), length: $(length(nlQ_ch.usable_ω))
          usable: $(usable_ω), length: $(length(usable_ω))
          rhs: $(rhs)"""

    return rhs, usable_ω
end

function calc_λsp_correction(χ_in::SharedArray{Complex{Float64},2}, usable_ω::AbstractArray{Int64},
                            searchInterval::AbstractArray{Float64,1},
                            rhs::Float64, kGrid::T1, β::Float64, χFillType, sP::SimulationParameters) where T1 <: ReducedKGrid
    res = zeros(eltype(χ_in), size(χ_in)...)
#    usable_ω = 1:size(χ_in,1)
    χr    = real.(χ_in[usable_ω,:])
    sh = get_sum_helper(usable_ω, sP)

    f(λint) = sum_freq(kintegrate(kGrid, χ_λ(χr, λint), dim=2)[:,1], [1], sh, β)[1] - rhs
    df(λint) = sum_freq(kintegrate(kGrid, -χ_λ(χr, λint) .^ 2, dim=2)[:,1], [1], sh, β)[1]
    X = @interval(searchInterval[1],searchInterval[2])
    tol = maximum(1e-10, (1e-5)*abs(searchInterval[2] - searchInterval[1]))
    r = roots(f, df, X, Newton, tol)
    #r2 = find_zeros(f, -0.004, 0.07, verbose=true)
    #@info "Method 2 root:" r2

    if isempty(r)
       @warn "   ---> WARNING: no lambda roots found!!!"
       return 0.0, convert(SharedArray, χ_λ(χr, 0.0))
    else
        λsp = mid(maximum(filter(x->!isempty(x),interval.(r))))
        @info "Found λsp " λsp
        if χFillType == zero_χ_fill
            res[usable_ω,:] =  χ_λ(χ_in[uable_ω,:], λsp) 
        elseif χFillType == lambda_χ_fill
            res =  χ_λ(χ_in, λsp) 
        else
            copy!(res, χsp) 
            res[usable_ω,:] =  χ_λ(χ_in[usable_sp,:], λsp) 
        end
        return λsp, convert(SharedArray,res)
    end
end

function extended_λ(nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, bubble::BubbleT, 
        Gνω::AbstractArray{Complex{Float64},2}, FUpDo::AbstractArray{Complex{Float64},3}, 
        Σ_loc_pos, Σ_ladderLoc,
                     kGrid::ReducedKGrid, 
                     mP::ModelParameters, sP::SimulationParameters)
    # --- prepare auxiliary vars ---
    gridShape = repeat([kGrid.Ns], mP.D)
    transform = reduce_kGrid ∘ ifft_cut_mirror ∘ ifft 
    transformK(x) = fft(expand_kGrid(kGrid.indices, x))
    transformG(x) = reshape(x, gridShape...)

    ωindices = intersect(nlQ_sp.usable_ω, nlQ_ch.usable_ω)
    νGrid = 0:trunc(Int, sP.n_iν-sP.shift*sP.n_iω/2-1)
    Σ_hartree = mP.n * mP.U/2
    norm = mP.β * kGrid.Nk
    E_pot_tail_c = (mP.U^2 * 0.5 * mP.n * (1-0.5*mP.n) .+ Σ_hartree .* (kGrid.ϵkGrid .+ Σ_hartree .- mP.μ))
    E_pot_tail = E_pot_tail_c' ./ (iν_array(mP.β, νGrid) .^ 2)
    E_pot_tail_inv = sum((mP.β/2)  .* [Σ_hartree .* ones(size(kGrid.ϵkGrid)), (-mP.β/2) .* E_pot_tail_c])

    sh_f = get_sum_helper(2*sP.n_iν, sP)
    sh_b = get_sum_helper(ωindices, sP)
    νZero = sP.n_iν
    ωZero = sP.n_iω
    tmp = SharedArray{Complex{Float64},3}(length(ωindices), size(bubble,2), size(bubble,3))
    Σ_ladder_ω = SharedArray{Complex{Float64},3}(length(ωindices), length(kGrid.indices), trunc(Int,length(νGrid)))
    Σ_internal2!(tmp, ωindices, bubble, FUpDo, Naive())

    function cond_both!(F, λ)
        χsp_λ = SharedArray(χ_λ(nlQ_sp.χ, λ[1]))
        χch_λ = SharedArray(χ_λ(nlQ_ch.χ, λ[2]))
        χupdo_ω = SharedArray{eltype(χsp_λ),1}(length(ωindices))
        χupup_ω = SharedArray{eltype(χsp_λ),1}(length(ωindices))
        Σ_internal!(Σ_ladder_ω, ωindices, ωZero, νZero, sP.shift, χsp_λ, χch_λ,
                nlQ_sp.γ, nlQ_ch.γ, Gνω, tmp, mP.U, transformG, transformK, transform)
        Σ_new = permutedims(mP.U .* sum_freq(Σ_ladder_ω, [1], Naive(), 1.0)[1,:,:] ./ norm, [2, 1])
        Σ_corr = Σ_new .- Σ_ladderLoc .+ Σ_loc_pos[1:size(Σ_new,1)]

        t = G_from_Σ(Σ_corr .+ Σ_hartree, kGrid.ϵkGrid, 0:size(Σ_new, 1)-1, mP)
        G_corr = flatten_2D(t);
        E_pot_DGA = calc_E_pot(G_corr, Σ_corr .+ Σ_hartree, E_pot_tail, E_pot_tail_inv, kGrid.kMult, norm)

        for (wi,w) in enumerate(ωindices)
            χupdo_ω[wi] = kintegrate(kGrid, χch_λ[w,:] .- χsp_λ[w,:])
            χupup_ω[wi] = kintegrate(kGrid, χch_λ[w,:] .+ χsp_λ[w,:])
        end
        rhs_c1 = real(sum_freq(χupup_ω, [1], sh_b, mP.β)[1])
        rhs_c2 = mP.U * real(sum_freq(χupdo_ω, [1], sh_b, mP.β)[1])

        lhs_c1 = 2 * mP.n/2 * (1 - mP.n/2)
        F[1] = rhs_c1 - lhs_c1
        F[2] = rhs_c2 + E_pot_DGA 
    end
    return nlsolve(cond_both!, [ 0.1; -0.8]).zero
end

function λsp_correction_search_int(χr::AbstractArray{Float64,2}, kGrid::ReducedKGrid, mP::ModelParameters; init=nothing, init_prct::Float64 = 0.1)
    nh    = ceil(Int64, size(χr,1)/2)
    χ_min    = -minimum(1 ./ χr[nh,:])
    int = if init === nothing
        rval = χ_min > 0 ? χ_min + 1/kGrid.Ns + 1/mP.β : minimum([10*abs(χ_min), χ_min + 10/kGrid.Ns + 10/mP.β]) 
        [χ_min, rval]
    else
        [init - init_prct*init, init + init_prct*init]
    end
    @info "found " χ_min ". Looking for roots in intervall $(int)" 
    return int
end

function λ_correction!(impQ_sp, impQ_ch, FUpDo, Σ_loc_pos, Σ_ladderLoc, nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, 
                      bubble::BubbleT, Gνω::SharedArray{Complex{Float64},2}, 
                      kGrid::ReducedKGrid,
                      mP::ModelParameters, sP::SimulationParameters; init_sp=nothing, init_spch=nothing)
    @info "Computing λsp corrected χsp, using " sP.χFillType " as fill value outside usable ω range."
    rhs,usable_ω_λc = calc_λsp_rhs_usable(impQ_sp, impQ_ch, nlQ_sp, nlQ_ch, kGrid, mP, sP)
    searchInterval_sp = λsp_correction_search_int(real.(nlQ_sp.χ[usable_ω_λc,:]), kGrid, mP, init=init_sp)
    searchInterval_spch = [-Inf, Inf]
    λsp,χsp_λ = calc_λsp_correction(nlQ_sp.χ, usable_ω_λc, searchInterval_sp, rhs, kGrid, mP.β, sP.χFillType, sP)

    #@info "Computing λsp corrected χsp, using " sP.χFillType " as fill value outside usable ω range."
    λ_new = [0.0, 0.0]
    #extended_λ(nlQ_sp, nlQ_ch, bubble, Gνω, FUpDo, Σ_loc_pos, Σ_ladderLoc, kGrid, mP, sP)
    if sP.λc_type == :sp
        nlQ_sp.χ = χsp_λ
        nlQ_sp.λ = λsp
    elseif sP.λc_type == :sp_ch
        nlQ_sp.χ = SharedArray(χ_λ(nlQ_sp.χ, λ[1]))
        nlQ_sp.λ = λ[1]
        nlQ_ch.χ = SharedArray(χ_λ(nlQ_ch.χ, λ[2]))
        nlQ_ch.λ = λ[2]
    end
    @info "new lambda correction: λsp=$(λ_new[1]) and λch=$(λ_new[2])"
    return λsp, λ_new, searchInterval_sp, searchInterval_spch
end
