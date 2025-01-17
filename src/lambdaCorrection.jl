include("lambdaCorrection_aux.jl")
include("lambdaCorrection_clean.jl")
include("lambdaCorrection_singleCore.jl")

function calc_λsp_rhs_usable(imp_density::Float64, χ_sp::χT, χ_ch::χT, kG::KGrid, mP::ModelParameters, sP::SimulationParameters, λ_rhs = :native)
    usable_ω = intersect(χ_sp.usable_ω, χ_ch.usable_ω)

    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[usable_ω] .* π ./ mP.β
    χch_ω = kintegrate(kG, χ_ch[:,usable_ω], 1)[1,:]
    #TODO: this should use sum_freq instead of naiive sum()
    χch_sum = real(sum(subtract_tail(χch_ω, mP.Ekin_DMFT, iωn)))/mP.β - mP.Ekin_DMFT*mP.β/12

    @info "λsp correction infos:"
    rhs = if (( (typeof(sP.χ_helper) != Nothing) && λ_rhs == :native) || λ_rhs == :fixed)
        @info "  ↳ using n/2 * (1 - n/2) - Σ χch as rhs"
        mP.n * (1 - mP.n/2) - χch_sum
    else
        @info "  ↳ using χupup_DMFT - Σ χch as rhs"
        2*imp_density - χch_sum
    end

    @info """  ↳ Found usable intervals for non-local susceptibility of length 
                 ↳ sp: $(χ_sp.usable_ω), length: $(length(χ_sp.usable_ω))
                 ↳ ch: $(χ_ch.usable_ω), length: $(length(χ_ch.usable_ω))
                 ↳ total: $(usable_ω), length: $(length(usable_ω))
               ↳ χch sum = $(χch_sum), rhs = $(rhs)"""
    return rhs, usable_ω
end

#TODO: refactor code repetition
function f_c1(λ::Float64, kMult::Vector{Float64}, χ::Matrix{Float64}, 
        tail::Vector{Float64})::Float64
    res = 0.0
    resi = 0.0
    norm = sum(kMult)
    for (i,ωi) in enumerate(tail)
        resi = 0.0
        for (ki,km) in enumerate(kMult)
            resi += χ_λ(χ[ki,i],λ) * km
        end
        res += resi/norm - ωi
    end
    return res
end

function df_c1(λ::Float64, kMult::Vector{Float64}, χ::Matrix{Float64}, 
        tail::Vector{Float64})::Float64
    res = 0.0
    resi = 0.0
    norm = sum(kMult)
    for (i,ωi) in enumerate(tail)
        resi = 0.0
        for (ki,km) in enumerate(kMult)
            resi += dχ_λ(χ[ki,i],λ) * km
        end
        res += resi/norm - ωi
    end
    return res
end

function calc_λsp_correction(χ_in::AbstractArray, usable_ω::AbstractArray{Int64},
                            EKin::Float64, rhs::Float64, kG::KGrid, 
                            mP::ModelParameters, sP::SimulationParameters)
    χr::Matrix{Float64}    = real.(χ_in[:,usable_ω])
    iωn = (1im .* 2 .* (-sP.n_iω:sP.n_iω)[usable_ω] .* π ./ mP.β)
    iωn[findfirst(x->x ≈ 0, iωn)] = Inf
    χ_tail::Vector{Float64} = real.(EKin ./ (iωn.^2))

    f_c1_int(λint::Float64)::Float64 = f_c1(λint, kG.kMult, χr, χ_tail)/mP.β - EKin*mP.β/12 - rhs
    df_c1_int(λint::Float64)::Float64 = df_c1(λint, kG.kMult, χr, χ_tail)/mP.β - EKin*mP.β/12 - rhs

    λsp = newton_right(f_c1_int, df_c1_int, get_λ_min(χr))
    return λsp
end

function cond_both_int_par!(F::Vector{Float64}, λ::Vector{Float64}, νωi_part, νω_range::Array{NTuple{4,Int}},
        χsp::χT, χch::χT, γsp::γT, γch::γT, χsp_bak::χT, χch_bak::χT,
        remote_results::Vector{Future},Σ_ladder::Array{ComplexF64,2}, 
        G_corr::Matrix{ComplexF64},νGrid::UnitRange{Int},χ_tail::Vector{ComplexF64},Σ_hartree::Float64,
        E_pot_tail::Matrix{ComplexF64},E_pot_tail_inv::Vector{Float64},Gνω::GνqT,
        λ₀::Array{ComplexF64,3}, kG::KGrid, mP::ModelParameters, workerpool::AbstractWorkerPool, trafo::Function)::Nothing
    λi::Vector{Float64} = trafo(λ)
    χ_λ!(χsp, χsp_bak, λi[1])
    χ_λ!(χch, χch_bak, λi[2])
    k_norm::Int = Nk(kG)

    ### Untroll start
    
    n_iν = size(Σ_ladder, 2)
    # distribute
    # workers = collect(workerpool.workers)
    # for (i,ind) in enumerate(νωi_part)
    #     ωi = sort(unique(map(x->x[1],νω_range[ind])))
    #     remote_results[i] = remotecall(update_χ, workers[i], :sp, χsp[:,ωi])
    #     remote_results[i] = remotecall(update_χ, workers[i], :ch, χch[:,ωi])
    #     remote_results[i] = remotecall(calc_Σ_eom_par, workers[i], n_iν, mP.U)
    # end
    for (i,ind) in enumerate(νωi_part)
        ωi = sort(unique(map(x->x[1],νω_range[ind])))
        ωind_map::Dict{Int,Int} = Dict(zip(ωi, 1:length(ωi)))
        remote_results[i] = remotecall(calc_Σ_eom, workerpool, νω_range[ind], ωind_map, n_iν, χsp[:,ωi],
                                       χch[:,ωi], γsp[:,:,ωi], γch[:,:,ωi], Gνω, λ₀[:,:,ωi], mP.U, kG)
    end

    # collect results
    fill!(Σ_ladder, Σ_hartree .* mP.β)
    for i in 1:length(remote_results)
        data_i = fetch(remote_results[i])
        Σ_ladder[:,:] += data_i
    end
    Σ_ladder = Σ_ladder ./ mP.β
    ### Untroll end

    lhs_c1 = 0.0
    lhs_c2 = 0.0
    #TODO: sum can be done on each worker
    for (ωi,t) in enumerate(χ_tail)
        tmp1 = 0.0
        tmp2 = 0.0
        for (qi,km) in enumerate(kG.kMult)
            tmp1 += 0.5 * real(χch[qi,ωi] .+ χsp[qi,ωi]) * km
            tmp2 += 0.5 * real(χch[qi,ωi] .- χsp[qi,ωi]) * km
        end
        lhs_c1 += tmp1/k_norm - t
        lhs_c2 += tmp2/k_norm
    end

    lhs_c1 = lhs_c1/mP.β - mP.Ekin_DMFT*mP.β/12
    lhs_c2 = lhs_c2/mP.β

    #TODO: the next two lines are expensive
    G_corr[:] = G_from_Σ(Σ_ladder, kG.ϵkGrid, νGrid, mP);
    E_pot = EPot1(kG, G_corr, Σ_ladder, E_pot_tail, E_pot_tail_inv, mP.β)


    rhs_c1 = mP.n/2 * (1 - mP.n/2)
    rhs_c2 = E_pot/mP.U - (mP.n/2) * (mP.n/2)
    F[1] = lhs_c1 - rhs_c1
    F[2] = lhs_c2 - rhs_c2
    return nothing
end

#TODO: this is manually unrolled...
# after optimization, revert to:
# calc_Σ, correct Σ, calc G(Σ), calc E
function extended_λ_par(χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT,
            Gνω::GνqT, λ₀::Array{ComplexF64,3}, x₀::Vector{Float64},
            kG::KGrid, mP::ModelParameters, sP::SimulationParameters, workerpool::AbstractWorkerPool;
            νmax::Int = -1, iterations::Int=20, ftol::Float64=1e-6)
        # --- prepare auxiliary vars ---
    @info "Using DMFT GF for second condition in new lambda correction"

        # general definitions
        #
    Nq, Nν, Nω = size(γ_sp)
    EKin::Float64 = mP.Ekin_DMFT
    ωindices::UnitRange{Int} = (sP.dbg_full_eom_omega) ? (1:size(χ_ch,2)) : intersect(χ_sp.usable_ω, χ_ch.usable_ω)
    νmax::Int = νmax < 0 ? min(sP.n_iν,floor(Int,3*length(ωindices)/8)) : νmax
    νGrid::UnitRange{Int} = 0:(νmax-1)
    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[ωindices] .* π ./ mP.β
    iωn[findfirst(x->x ≈ 0, iωn)] = Inf
    χ_tail::Vector{ComplexF64} = EKin ./ (iωn.^2)
    k_norm::Int = Nk(kG)

    # EoM optimization related definitions
    Σ_ladder::Array{ComplexF64,2} = Array{ComplexF64,2}(undef, Nq, νmax)
    νω_range::Array{NTuple{4,Int}} = Array{NTuple{4,Int}}[]
    for (ωi,ωn) in enumerate(-sP.n_iω:sP.n_iω)
        νZero = ν0Index_of_ωIndex(ωi, sP)
        maxn = min(size(γ_ch,ν_axis), νZero + νmax - 1)
        for (νii,νi) in enumerate(νZero:maxn)
                push!(νω_range, (ωi, ωn, νi, νii))
        end
    end
    νωi_part = par_partition(νω_range, length(workerpool))
    remote_results = Vector{Future}(undef, length(νωi_part))

    # preallications
    χsp_tmp::χT = deepcopy(χ_sp)
    χch_tmp::χT = deepcopy(χ_ch)
    G_corr::Matrix{ComplexF64} = Matrix{ComplexF64}(undef, Nq, νmax)

    # Therodynamics preallocations
    Σ_hartree::Float64 = mP.n * mP.U/2.0;
    E_pot_tail_c = [zeros(size(kG.ϵkGrid)),
            (mP.U^2 * 0.5 * mP.n * (1-0.5*mP.n) .+ Σ_hartree .* (kG.ϵkGrid .+ Σ_hartree .- mP.μ))]
    tail = [1 ./ (iν_array(mP.β, νGrid) .^ n) for n in 1:length(E_pot_tail_c)]
    E_pot_tail::Matrix{ComplexF64} = sum(E_pot_tail_c[i] .* transpose(tail[i]) for i in 1:length(tail))
    E_pot_tail_inv::Vector{Float64} = sum((mP.β/2)  .* [Σ_hartree .* ones(size(kG.ϵkGrid)), (-mP.β/2) .* E_pot_tail_c[2]])

    rhs_c1 = mP.n/2 * (1 - mP.n/2)
    λsp_min = get_λ_min(real.(χsp_tmp.data))
    λch_min = get_λ_min(real.(χch_tmp.data))
    λsp_max = 50.0#sum(kintegrate(kG,χ_λ(real.(χch_tmp.data), λch_min + 1e-8), 1)) / mP.β - rhs_c1
    λch_max = 1000.0#sum(kintegrate(kG,χ_λ(real.(χsp_tmp.data), λsp_min + 1e-8), 1)) / mP.β - rhs_c1
    @info "λsp ∈ [$λsp_min, $λsp_max], λch ∈ [$λch_min, $λch_max]"

    #trafo(x) = [((λsp_max - λsp_min)/2)*(tanh(x[1])+1) + λsp_min, ((λch_max-λch_min)/2)*(tanh(x[2])+1) + λch_min]
    trafo(x) = x
    
    cond_both!(F::Vector{Float64}, λ::Vector{Float64})::Nothing = 
        cond_both_int_par!(F, λ, νωi_part, νω_range,
        χ_sp, χ_ch, γ_sp, γ_ch, χsp_tmp, χch_tmp,  remote_results,Σ_ladder,
        G_corr, νGrid, χ_tail, Σ_hartree, E_pot_tail, E_pot_tail_inv, Gνω, λ₀, kG, mP, workerpool, trafo)
    
    println("λ search interval: $(trafo([-Inf, -Inf])) to $(trafo([Inf, Inf]))")

    
    # TODO: test this for a lot of data before refactor of code
    
    δ   = 1.0 # safety from first pole. decrese this if no roots are found
    λs_sp = λsp_min + abs.(λsp_min/10.0)
    λs_ch = λch_min + abs.(λch_min/10.0)
    λmin = [λsp_min, λch_min]
    λs = x₀
    all(x₀ .< λmin) && @warn "starting point $x₀ is not compatible with λmin $λmin !"
    λnew = nlsolve(cond_both!, λs, ftol=ftol, iterations=iterations)
    λnew.zero = trafo(λnew.zero)
    println(λnew)
    χ_sp.data = deepcopy(χsp_tmp.data)
    χ_ch.data = deepcopy(χch_tmp.data)
    return λnew, ""
end
    

function λ_correction(type::Symbol, imp_density::Float64,
            χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT,
            Gνω::GνqT, λ₀::Array{ComplexF64,3}, kG::KGrid,
            mP::ModelParameters, sP::SimulationParameters;
            workerpool::AbstractWorkerPool=default_worker_pool(),init_sp=nothing, init_spch=nothing, parallel=false, x₀::Vector{Float64}=[0.0,0.0])
    res = if type == :sp
        rhs,usable_ω_λc = calc_λsp_rhs_usable(imp_density, χ_sp, χ_ch, kG, mP, sP)
        @timeit to "λsp" λsp = calc_λsp_correction(real.(χ_sp.data), usable_ω_λc, mP.Ekin_DMFT, rhs, kG, mP, sP)
        λsp
    elseif type == :sp_ch
        @timeit to "λspch 2" λ_spch, dbg_string = if parallel
                extended_λ_par(χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, x₀, kG, mP, sP, workerpool)
            else
                extended_λ(χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, x₀, kG, mP, sP)
        end
        @warn "extended λ correction dbg string: " dbg_string
        λ_spch
    else
        error("unrecognized λ correction type: $type")
    end
    return res
end

function λ_correction!(type::Symbol, imp_density, F, Σ_loc_pos, Σ_ladderLoc,
                       χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT,
                      χ₀::χ₀T, Gνω::GνqT, kG::KGrid,
                      mP::ModelParameters, sP::SimulationParameters; init_sp=nothing, init_spch=nothing)

    λ = λ_correction(type, imp_density, F, Σ_loc_pos, Σ_ladderLoc, χ_sp, γ_sp, χ_ch, γ_ch,
                  χ₀, Gνω, kG, mP, sP; init_sp=init_sp, init_spch=init_spch)
    res = if type == :sp
        χ_λ!(χ_sp, λ)
    elseif type == :sp_ch
        χ_λ!(χ_sp, λ[1])
        χ_λ!(χ_ch, λ[2])
    end
end
