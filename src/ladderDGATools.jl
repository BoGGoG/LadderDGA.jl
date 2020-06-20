#TODO: kList must be template parameter for dimensions
#TODO: nw and niv grid as parameters? 
#TODO: define GF type that knows about which dimension stores which variable

@everywhere @inline @fastmath GF_from_Σ(n::Int64, β::Float64, μ::Float64, ϵₖ::T, Σ::Complex{T}) where T =
                    1/((π/β)*(2*n + 1)*1im + μ - ϵₖ - Σ)
@everywhere @inline @fastmath w_from_Σ(n::Int64, β::Float64, μ::Float64, Σ::Complex{Float64}) =
                    ((π/β)*(2*n + 1)*1im + μ - Σ)

@inline @inbounds function G_fft(ind::Int64, Σ::Array{Complex{Float64},1}, 
                                 ϵkIntGrid::Base.Generator, β::Float64, μ::Float64)
    Σν = get_symm_f(Σ,ind)
    Gν  = map(ϵk -> GF_from_Σ(ind, β, μ, ϵk, Σν), ϵkIntGrid)
    return fft!(Gν)
end

#TODO: get rid of kInt, remember symmetry G(k')G(k'+q) so 2*LQ-2 = kInt
function calc_bubble_fft(Σ::Array{Complex{Float64},1}, ϵkIntGrid, redGridSize,
                              mP::ModelParameters, sP::SimulationParameters)

    Gνω = [G_fft(ind, Σ, ϵkIntGrid, mP.β, mP.μ) for ind in (-sP.n_iω):(sP.n_iν+sP.n_iω)]
    Gν  = (G_fft(ind, Σ, Iterators.reverse(ϵkIntGrid), mP.β, mP.μ) for ind in 0:(sP.n_iν-1))
    Gν  = -mP.β .* Gν ./ (sP.Nk^mP.D)

    res = Array{Complex{Float64}}(undef, 2*sP.n_iω+1, redGridSize, sP.n_iν)
    @inbounds for (νi,Gνi) in enumerate(Gν)
        @inbounds for ωi in 1:2*sP.n_iω+1
            @inbounds res[ωi,:,νi] = reverse(reduce_kGrid(cut_mirror(ifft(Gνi  .* Gνω[νi-1+ωi]))))
        end
    end
    @inbounds res = cat(conj.(res[end:-1:1,:,end:-1:1]),res, dims=3)
    return res
end


"""
Solve χ = χ₀ - 1/β² χ₀ Γ χ
    ⇔ (1 + 1/β² χ₀ Γ) χ = χ₀
    ⇔      (χ⁻¹ - χ₀⁻¹) = 1/β² Γ
    with indices: χ[ω, q] = χ₀[]
    TODO: use 4.123 with B.6+B.7 instead of inversion
"""
function calc_χ_trilex(Γsp::Array{T,3}, Γch::Array{T,3}, bubble::Array{T,3},
                              modelParams::ModelParameters, simParams::SimulationParameters) where T <: Number
    Nω = floor(Int64,size(bubble, 1)/2)
    Nq = size(bubble, 2)
    Nν = floor(Int64,size(bubble, 3)/2)
    χsp = SharedArray{eltype(bubble)}(2*Nω+1, Nq)    # ωₙ x q (summed over νₙ)
    γsp = SharedArray{eltype(bubble)}(2*Nω+1, Nq, 2*Nν)
    χch = SharedArray{eltype(bubble)}(2*Nω+1, Nq)    # ωₙ x q (summed over νₙ)
    γch = SharedArray{eltype(bubble)}(2*Nω+1, Nq, 2*Nν)

    W = nothing
    if simParams.tail_corrected
        νmin = Int(floor((Nν)*2/4))
        νmax = Int(floor(Nν))
        W = build_weights(νmin, νmax, [0,1,2,3])
    end
    UnitM = Matrix{eltype(Γsp)}(I, size(Γsp[1,:,:])...)
    for (ωi,ωₙ) in enumerate((-Nω):Nω)
        ΓspView = view(Γsp,ωi,:,:)
        ΓchView = view(Γch,ωi,:,:)
        for qi in 1:Nq
            bubbleD = Diagonal(bubble[ωi, qi, :])
            # input: vars: bubble, gamma, U, tc, beta ; functions: sum_freq ; out: χ, γ 

            @inbounds A_sp = bubbleD * ΓspView + UnitM 
            χ_full_sp = A_sp\bubbleD
            @inbounds χsp[ωi, qi] = sum_freq(χ_full_sp, [1,2], simParams.tail_corrected, modelParams.β, weights=W)[1,1]
            @inbounds γsp[ωi, qi, :] .= modelParams.β .* sum_freq(χ_full_sp, [2], simParams.tail_corrected, modelParams.β, weights=W)[:,1] ./ (1.0 + modelParams.U * χsp[ωi, qi])

            @inbounds A_ch = bubbleD * ΓchView + UnitM
            χ_full_ch = A_ch\bubbleD
            @inbounds χch[ωi, qi] = sum_freq(χ_full_ch, [1,2], simParams.tail_corrected, modelParams.β, weights=W)[1,1]
            @inbounds γch[ωi, qi, :] .= modelParams.β .* sum_freq(χ_full_ch, [2], simParams.tail_corrected, modelParams.β, weights=W)[:,1] ./  (1.0 - modelParams.U * χch[ωi, qi])
        end
    end
    return χsp, χch, γsp, γch
end

function calc_DΓA_Σ_fft(χsp, χch, γsp, γch, bubble, Σ_loc, FUpDo, qMultiplicity, qGrid, qIndices, modelParams::ModelParameters, simParams::SimulationParameters; full_input = false)
    Nω = floor(Int64,size(bubble,1)/2)
    Nν = floor(Int64,size(bubble,3)/2)
    kIndices, kGrid  = gen_kGrid(simParams.Nk, modelParams.D; min = 0, max = π, include_min=true)
    ϵkGrid   = squareLattice_ekGrid(kGrid)
    Σνω_list = [get_symm_f(Σ_loc,n) for n in -Nω:(Nω + Nν - 1)]
    Gνω_list = [map(ϵk -> GF_from_Σ(n, modelParams.β, modelParams.μ, ϵk, Σνω_list[ni]), ϵkGrid) 
                for (ni,n) in enumerate(-Nω:(Nω + Nν - 1))]

    Σ_ladder = zeros(eltype(χch), Nν, length(collect(kGrid)))
    tmp1 = []
    tmp2 = []

    #println("TODO: expand before loop")
    for (νi,νₙ) in enumerate(0:Nν-1)
        for (ωi,ωₙ) in enumerate(-Nω:Nω)
            Kνωq = (1.5 .* γsp[ωi, :, νi+Nν] .* (1 .+ modelParams.U*χsp[ωi, :]) .-
                   0.5 .* γch[ωi, :, νi+Nν].* (1 .- modelParams.U*χch[ωi, :]) .- 1.5 .+ 0.5) .+
                   sum([bubble[ωi,:,vpi] .* FUpDo[ωi,νi+Nν,vpi] for vpi = 1:size(bubble,3)])

            Σνω = get_symm_f(Σ_loc,ωₙ + νₙ)
            Gνω = map(ϵk -> GF_from_Σ(ωₙ + νₙ, modelParams.β, modelParams.μ, ϵk, Σνω), ekGrid)
            # = Gνω_list[νₙ + ωₙ + Nω + 1]
            Gνω_ft = fft(Gνω[:])
            if !full_input
                Kνωq = expand_mirror(expand_kGrid(collect(qIndices), Kνωq))#) 
                if νi == 2 && ωi == 2
                    tmp1 = Kνωq
                    tmp2 = Gνω
                end
                #Kνωq = cat(Kνωq[:], zeros(length(Gνω[:])-length(Kνωq)), dims=1)
            else
                Kνωq = reshape(Kνωq, (simParams.Nk,simParams.Nk))
                if νi == 2 && ωi == 2
                    tmp1 = Kνωq
                    tmp2 = Gνω
                end
            end
            #println("1: ", νi, " ", ωi, " ", real(Kνωq))
            #println(size(Kνωq))
            Kνωq = fft(Kνωq[end:-1:1])
            Σ_ladder[νi, :] = (ifft(Kνωq .* Gνω_ft))[1:end]
        end
    end
    Σ_ladder = modelParams.U .* Σ_ladder ./ (modelParams.β * (simParams.Nk^modelParams.D))
    return Σ_ladder, tmp1, tmp2
end

function calc_DΓA_Σ_fft_2(χsp, χch, γsp, γch, bubble, Σ_loc, FUpDo, qMult, qGrid, 
                          modelParams::ModelParameters, simParams::SimulationParameters; full_input = false)
    println(stderr,"TODO: compressed fft not implemented yet")
end



function calc_DΓA_Σ(χsp, χch, γsp, γch, 
                             bubble, Σ_loc, FUpDo, qMult, qGrid, qInd,
                             modelParams::ModelParameters, simParams::SimulationParameters)
    _, kGrid         = reduce_kGrid.(collect.(gen_kGrid(simParams.Nk, modelParams.D; min = 0, max = π, include_min = true)))
    kList = collect(kGrid)
    Nω = floor(Int64,size(bubble,1)/2)
    Nq = size(bubble,2)
    Nν = floor(Int64,size(bubble,3)/2)
    ϵkqList = gen_squareLattice_full_ekq_grid(kList, collect(qGrid))
    multFac =  if (modelParams.D == 2) 8.0 else 48.0 end # 6 for permutation 8 for mirror
    tmp1 = []

    #println("s0: ", Nq)
    #println("s1: ", length(kList))
    #println("s2: ", size(ϵkqList,3))
    tmp2 = zeros(Complex{Float64}, Nq,length(kList),size(ϵkqList,3))
    Σ_ladder = zeros(eltype(χch), Nν, length(kList))
    for (νi,νₙ) in enumerate(0:Nν-1)
        for (ωi,ωₙ) in enumerate((-simParams.n_iω):simParams.n_iω)
            for qi in 1:Nq
                qiNorm = qMult[qi]/((2*(Int(simParams.Nk/2)))^(modelParams.D)*multFac)#8*(Nq-1)^(modelParams.D)
            #qiNorm = qMult[qi]/((2*(Nq-1))^2*8)#/(4.0*8.0)
                Σν = get_symm_f(Σ_loc,ωₙ + νₙ)
                tmp = (1.5 * γsp[ωi, qi, νi+Nν]*(1 + modelParams.U*χsp[ωi, qi]) -
                       0.5 * γch[ωi, qi, νi+Nν]*(1 - modelParams.U*χch[ωi, qi])-1.5+0.5) +
                       sum(bubble[ωi, qi, :] .* FUpDo[ωi, νi+Nν, :])

                if νi == 2 && ωi == 2
                    push!(tmp1, tmp)
                end
                for ki in 1:length(kList)
                    for perm in 1:size(ϵkqList,3)
                        Gνω = GF_from_Σ(ωₙ + νₙ, modelParams.β, modelParams.μ, ϵkqList[ki,qi,perm], Σν) 
                        if νi == 2 && ωi == 2 && ki == 2
                            #println(qi, ", ", ki, ", ", perm, ": ", tmp)
                            tmp2[ki,qi,perm] = Gνω
                        end
                        Σ_ladder[νi, ki] += tmp*Gνω*qiNorm*modelParams.U/modelParams.β
                    end
                end
            end
        end
    end
    return conj.(sdata(Σ_ladder)), tmp1, tmp2
end
