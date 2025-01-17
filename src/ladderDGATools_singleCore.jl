#TODO: combine this with ladderDGATool.jl

function calc_bubble(Gνω::GνqT, Gνω_r::GνqT, kG::KGrid, mP::ModelParameters, sP::SimulationParameters; local_tail=false)
    #TODO: fix the size (BSE_SC inconsistency)
    data = Array{ComplexF64,3}(undef, length(kG.kMult), 2*(sP.n_iν+sP.n_iν_shell), 2*sP.n_iω+1)
    for (ωi,ωn) in enumerate(-sP.n_iω:sP.n_iω)
        νrange = ((-(sP.n_iν+sP.n_iν_shell)):(sP.n_iν+sP.n_iν_shell-1)) .- trunc(Int,sP.shift*ωn/2)
        #TODO: fix the offset (BSE_SC inconsistency)
        for (νi,νn) in enumerate(νrange)
            conv_fft!(kG, view(data,:,νi,ωi), reshape(Gνω[:,νn].parent,gridshape(kG)), reshape(Gνω_r[:,νn+ωn].parent,gridshape(kG)))
            data[:,νi,ωi] .*= -mP.β
        end
    end
    #TODO: not necessary after real fft
    data = _eltype === Float64 ? real.(data) : data

    #TODO: move tail calculation to definition of GF (GF should know about its tail)
    t1, t2 = if local_tail
        convert.(ComplexF64, [mP.U*mP.n/2 - mP.μ]),
        #TODO: move tail to GF struct
        mP.sVk + (mP.U^2)*(mP.n/2)*(1-mP.n/2)
    else
        convert.(ComplexF64, kG.ϵkGrid .+ mP.U*mP.n/2 .- mP.μ),
        (mP.U^2)*(mP.n/2)*(1-mP.n/2)
    end
    return χ₀T(data, kG, t1, t2, mP.β, -sP.n_iω:sP.n_iω, sP.n_iν, Int(sP.shift)) 
end

function calc_χγ(type::Symbol, Γr::ΓT, χ₀::χ₀T, kG::KGrid, mP::ModelParameters, sP::SimulationParameters)
    #TODO: find a way to reduce initialization clutter: move lo,up to sum_helper
    #TODO: χ₀ should know about its tail c2, c3
    s = type === :ch ? -1 : 1
    Nν = 2*sP.n_iν
    Nq  = length(kG.kMult)
    Nω  = size(χ₀.data,ω_axis)
    #TODO: use predifened ranks for Nq,... cleanup definitions
    γ = Array{ComplexF64,3}(undef, Nq, Nν, Nω)
    χ = Array{ComplexF64,2}(undef, Nq, Nω)
    ωi_range = 1:Nω
    νi_range = 1:Nν
    qi_range = 1:Nq

    χ_ω = Array{_eltype, 1}(undef, Nω)
    χννpω = Matrix{_eltype}(undef, Nν, Nν)
    ipiv = Vector{Int}(undef, Nν)
    work = _gen_inv_work_arr(χννpω, ipiv)
    λ_cache = Array{eltype(χννpω),1}(undef, Nν)

    for ωi in ωi_range
        ωn = (ωi - sP.n_iω) - 1
        for qi in qi_range
            χννpω[:,:] = deepcopy(Γr[:,:,ωi])
            for l in νi_range
                χννpω[l,l] += 1.0/χ₀.data[qi,sP.n_iν_shell+l,ωi]
            end
            inv!(χννpω, ipiv, work)
            if typeof(sP.χ_helper) <: BSE_Asym_Helpers
                χ[qi, ωi] = calc_χλ_impr!(λ_cache, type, ωn, χννpω, view(χ₀.data,qi,:,ωi), 
                                           mP.U, mP.β, χ₀.asym[qi,ωi], sP.χ_helper);
                γ[qi, :, ωi] = (1 .- s*λ_cache) ./ (1 .+ s*mP.U .* χ[qi, ωi])
            else
                if typeof(sP.χ_helper) === BSE_SC_Helper
                    improve_χ!(type, ωi, view(χννpω,:,:,ωi), view(χ₀,qi,:,ωi), mP.U, mP.β, sP.χ_helper);
                end
                χ[qi,ωi] = sum(χννpω)/mP.β^2
                for νk in νi_range
                    γ[qi,νk,ωi] = sum(view(χννpω,:,νk))/(χ₀.data[qi,νk,ωi] * (1.0 + s*mP.U * χ[qi,ωi]))
                end
            end
        end
        #TODO: write macro/function for ths "real view" beware of performance hits
        v = _eltype === Float64 ? view(χ,:,ωi) : @view reinterpret(Float64,view(χ,:,ωi))[1:2:end]
        χ_ω[ωi] = kintegrate(kG, v)
    end
    log_q0_χ_check(kG, sP, χ, type)

    return χT(χ), γT(γ)
end

function calc_Σ_ω!(eomf::Function, Σ::AbstractArray{ComplexF64,3}, Kνωq_pre::Array{ComplexF64, 1},
            ωindices::AbstractArray{Int,1},
            χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT,
            Gνω::GνqT, λ₀::AbstractArray{ComplexF64,3}, U::Float64, kG::KGrid, 
            sP::SimulationParameters)
    fill!(Σ, zero(ComplexF64))
    νmax = size(Σ, 2)
    for ωii in 1:length(ωindices)
        ωi = ωindices[ωii]
        ωn = (ωi - sP.n_iω) - 1
        νZero = ν0Index_of_ωIndex(ωi, sP)
        maxn = minimum([size(γ_ch,ν_axis), νZero + size(Σ, 2) - 1])
        # maxn2 = 2*νmax + (sP.shift && ωi < sP.n_iω)*(trunc(Int, (ωi - sP.n_iω - 1)/2)) 
        for (νii,νi) in enumerate(νZero:maxn)
            v = reshape(view(Gνω,:,(νii-1) + ωn), gridshape(kG)...)
            for qi in 1:size(Σ,q_axis)
                Kνωq_pre[qi] = eomf(U, γ_sp[qi,νi,ωi], γ_ch[qi,νi,ωi],
                                   χ_sp[qi,ωi], χ_ch[qi,ωi], λ₀[qi,νi,ωi])
            end
            conv_fft1!(kG, view(Σ,:,νii-1,ωn), Kνωq_pre, v)
        end
    end
end

function calc_Σ(χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT, λ₀::AbstractArray{_eltype,3},
                Gνω::GνqT, kG::KGrid,
                mP::ModelParameters, sP::SimulationParameters; pre_expand=true)
    Σ_hartree = mP.n * mP.U/2.0;
    Nq, Nω = size(χ_sp)
    ωrange::UnitRange{Int} = -sP.n_iω:sP.n_iω
    ωindices::UnitRange{Int} = (sP.dbg_full_eom_omega) ? (1:Nω) : intersect(χ_sp.usable_ω, χ_ch.usable_ω)
    νmax::Int = floor(Int,length(ωindices)/3)

    Kνωq_pre::Vector{ComplexF64} = Vector{ComplexF64}(undef, length(kG.kMult))
    #TODO: implement real fft and make _pre real
    Σ_ladder_ω = OffsetArray(Array{Complex{Float64},3}(undef,Nq, sP.n_iν, length(ωrange)),
                              1:Nq, 0:sP.n_iν-1, ωrange)
    @timeit to "Σ_ω" calc_Σ_ω!(eom, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    res = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β .+ Σ_hartree
    return  res
end

function calc_Σ_parts(χ_sp::χT, γ_sp::γT, χ_ch::χT, γ_ch::γT, λ₀::AbstractArray{_eltype,3},
                Gνω::GνqT, kG::KGrid,
                mP::ModelParameters, sP::SimulationParameters; pre_expand=true)
    Σ_hartree = mP.n * mP.U/2.0;
    Nq, Nω = size(χ_sp)
    ωrange::UnitRange{Int} = -sP.n_iω:sP.n_iω
    ωindices::UnitRange{Int} = (sP.dbg_full_eom_omega) ? (1:Nω) : intersect(χ_sp.usable_ω, χ_ch.usable_ω)
    νmax::Int = floor(Int,length(ωindices)/3)

    Kνωq_pre::Vector{ComplexF64} = Vector{ComplexF64}(undef, length(kG.kMult))
    #TODO: implement real fft and make _pre real
    Σ_ladder_ω = OffsetArray(Array{Complex{Float64},3}(undef,Nq, sP.n_iν, length(ωrange)),
                              1:Nq, 0:sP.n_iν-1, ωrange)
    Σ_ladder = Array{Complex{Float64},3}(undef,Nq, sP.n_iν, 6)
    calc_Σ_ω!(eom_χsp, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,1] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β
    calc_Σ_ω!(eom_γsp, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,2] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β
    calc_Σ_ω!(eom_χch, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,3] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β 
    calc_Σ_ω!(eom_γch, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,4] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β 
    calc_Σ_ω!(eom_rest_01, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,5] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β
    calc_Σ_ω!(eom_rest, Σ_ladder_ω, Kνωq_pre, ωindices, χ_sp, γ_sp, χ_ch, γ_ch, Gνω, λ₀, mP.U, kG, sP)
    Σ_ladder[:,:,6] = dropdims(sum(Σ_ladder_ω, dims=[3]),dims=3) ./ mP.β .+ Σ_hartree

    return  OffsetArray(Σ_ladder, 1:Nq, 0:sP.n_iν-1, 1:6)
end
