using SymbolicIndexingInterface

struct FakeIntegrator{P}
    p::P
end

SymbolicIndexingInterface.symbolic_container(fp::FakeIntegrator) = fp.sys
SymbolicIndexingInterface.parameter_values(fp::FakeIntegrator) = fp.p

sys = SymbolCache([:x, :y, :z], [:a, :b], [:t])
p = [1.0, 2.0]
fi = FakeIntegrator(copy(p))
for (i, sym) in [(1, :a), (2, :b), ([1, 2], [:a, :b]), ((1, 2), (:a, :b))]
    get = getp(sys, sym)
    set! = setp(sys, sym)
    true_value = i isa Tuple ? getindex.((p,), i) : p[i]
    @test get(fi) == true_value
    set!(fi, 0.5 .* i)
    @test get(fi) == 0.5 .* i
    set!(fi, true_value)
end
