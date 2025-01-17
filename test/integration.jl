using DynamicGrids, DimensionalData, Test, Dates, Unitful, 
      KernelAbstractions, FileIO, FixedPointNumbers, Colors

# life glider sims

# Test all cycled variants of the array
cyclei!(arrays) = begin
    for A in arrays
        v = A[1, :]
        @inbounds copyto!(A, CartesianIndices((1:size(A, 1)-1, 1:size(A, 2))),
                          A, CartesianIndices((2:size(A, 1), 1:size(A, 2))))
        A[end, :] = v
    end
end

cyclej!(arrays) = begin
    for A in arrays
        v = A[:, 1]
        @inbounds copyto!(A, CartesianIndices((1:size(A, 1), 1:size(A, 2)-1)),
                          A, CartesianIndices((1:size(A, 1), 2:size(A, 2))))
        A[:, end] = v 
    end
end

test6_7 = (
    init =  Bool[
             0 0 0 0 0 0 0
             0 0 0 0 1 1 1
             0 0 0 0 0 0 1
             0 0 0 0 0 1 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
            ],
    test2 = Bool[
             0 0 0 0 0 1 0
             0 0 0 0 0 1 1
             0 0 0 0 1 0 1
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
            ],
    test3 = Bool[
             0 0 0 0 0 1 1
             0 0 0 0 1 0 1
             0 0 0 0 0 0 1
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
            ],
    test4 = Bool[
             0 0 0 0 0 1 1
             1 0 0 0 0 0 1
             0 0 0 0 0 1 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
            ],
    test5 = Bool[
             1 0 0 0 0 1 1
             1 0 0 0 0 0 0
             0 0 0 0 0 0 1
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
            ],
    test7 = Bool[
             1 0 0 0 0 1 0
             1 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             0 0 0 0 0 0 0
             1 0 0 0 0 0 1
            ]
)

test5_6 = (
    init =  Bool[
             0 0 0 0 0 0
             0 0 0 1 1 1
             0 0 0 0 0 1
             0 0 0 0 1 0
             0 0 0 0 0 0
            ],
    test2 = Bool[
             0 0 0 0 1 0
             0 0 0 0 1 1
             0 0 0 1 0 1
             0 0 0 0 0 0
             0 0 0 0 0 0
            ],
    test3 = Bool[
             0 0 0 0 1 1
             0 0 0 1 0 1
             0 0 0 0 0 1
             0 0 0 0 0 0
             0 0 0 0 0 0
            ],
    test4 = Bool[
             0 0 0 0 1 1
             1 0 0 0 0 1
             0 0 0 0 1 0
             0 0 0 0 0 0
             0 0 0 0 0 0
            ],
    test5 = Bool[
             1 0 0 0 1 1
             1 0 0 0 0 0
             0 0 0 0 0 1
             0 0 0 0 0 0
             0 0 0 0 0 0
            ],
    test7 = Bool[
             1 0 0 0 1 0
             1 0 0 0 0 0
             0 0 0 0 0 0
             0 0 0 0 0 0
             1 0 0 0 0 1
            ]
)

@testset "Life simulation with Wrap" begin
    # Test on two sizes to test half blocks on both axes
    # Loop over shifing init arrays to make sure they all work
    for test in (test5_6, test6_7), i in 1:size(test[:init], 1)
        for j in 1:size(test[:init], 2)
            for proc in (SingleCPU(), ThreadedCPU(), CPUGPU()), opt in (NoOpt(), SparseOpt())
                @testset "$(nameof(typeof(proc))) $(nameof(typeof(opt))) results match glider behaviour" begin
                    bufs = (zeros(Int, 3, 3), zeros(Int, 3, 3))
                    rule = Life(neighborhood=Moore{1}(bufs))
                    ruleset = Ruleset(;
                        rules=(Life(),),
                        timestep=Day(2),
                        boundary=Wrap(),
                        proc=proc,
                        opt=opt,
                    )
                    output = ArrayOutput(test[:init], tspan=Date(2001, 1, 1):Day(2):Date(2001, 1, 14))
                    sim!(output, ruleset)
                    @test output[2] == test[:test2]
                    @test output[3] == test[:test3]
                    @test output[4] == test[:test4]
                    @test output[5] == test[:test5]
                    @test output[7] == test[:test7]
                end
            end
            cyclej!(test)
        end
        cyclei!(test)
    end
end

@testset "Life simulation with Remove boudary and replicates" begin
    init_ =     Bool[
                 0 0 0 0 0 0 0
                 0 0 0 0 1 1 1
                 0 0 0 0 0 0 1
                 0 0 0 0 0 1 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]
    test2_rem = Bool[
                 0 0 0 0 0 1 0
                 0 0 0 0 0 1 1
                 0 0 0 0 1 0 1
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]
    test3_rem = Bool[
                 0 0 0 0 0 1 1
                 0 0 0 0 1 0 1
                 0 0 0 0 0 0 1
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]
    test4_rem = Bool[
                 0 0 0 0 0 1 1
                 0 0 0 0 0 0 1
                 0 0 0 0 0 1 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]
    test5_rem = Bool[
                 0 0 0 0 0 1 1
                 0 0 0 0 0 0 1
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]
    test7_rem = Bool[
                 0 0 0 0 0 1 1
                 0 0 0 0 0 1 1
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                 0 0 0 0 0 0 0
                ]

    rule = Life{:a,:a}(neighborhood=Moore(1))

    @testset "Wrong timestep throws an error" begin
        rs = Ruleset(rule; timestep=Day(2), boundary=Remove(), opt=NoOpt())
        output = ArrayOutput((a=init_,); tspan=1:7)
        @test_throws ArgumentError sim!(output, rs; tspan=Date(2001, 1, 1):Month(1):Date(2001, 3, 1))
    end

    @testset "Results match glider behaviour" begin
        output = ArrayOutput((a=init_,); tspan=1:7)
        for proc in (SingleCPU(), ThreadedCPU(), CPUGPU()), opt in (NoOpt(), SparseOpt())
            sim!(output, rule; boundary=Remove(), proc=proc, opt=opt)
            @test output[2][:a] == test2_rem
            @test output[3][:a] == test3_rem
            @test output[4][:a] == test4_rem
            @test output[5][:a] == test5_rem
            @test output[7][:a] == test7_rem
        end
    end

    @testset "Combinatoric comparisons in a larger Life sim" begin
        rule = Life(neighborhood=Moore(1))
        init = rand(Bool, 100, 100)
        mask = ones(Bool, size(init)...)
        mask[1:50, 1:50] .= false  
        wrap_rs_ref = Ruleset(rule; boundary=Wrap())
        remove_rs_ref = Ruleset(rule; boundary=Remove())
        wrap_output_ref = ArrayOutput(init; tspan=1:100, mask=mask)
        remove_output_ref = ArrayOutput(init; tspan=1:100, mask=mask)
        sim!(remove_output_ref, remove_rs_ref)
        sim!(wrap_output_ref, wrap_rs_ref)
        for proc in (SingleCPU(), ThreadedCPU(), CPUGPU()),
            opt in (NoOpt(), SparseOpt())
            @testset "$(nameof(typeof(opt))) $(nameof(typeof(proc)))" begin
                @testset "Wrap" begin
                    wrap_rs = Ruleset(rule; boundary=Wrap(), proc=proc, opt=opt)
                    wrap_output = ArrayOutput(init; tspan=1:100, mask=mask)
                    sim!(wrap_output, wrap_rs)
                    @test wrap_output_ref[2] == wrap_output[2]
                    wrap_output_ref[2] .- wrap_output[2]
                    @test wrap_output_ref[3] == wrap_output[3]
                    @test wrap_output_ref[10] == wrap_output[10]
                    @test wrap_output_ref[100] == wrap_output[100]
                end
                @testset "Remove" begin
                    remove_rs = Ruleset(rule; boundary=Remove(), proc=proc, opt=opt)
                    remove_output = ArrayOutput(init; tspan=1:100, mask=mask)
                    sim!(remove_output, remove_rs);
                    @test remove_output_ref[2] == remove_output[2]
                    @test remove_output_ref[3] == remove_output[3]
                    remove_output_ref[3] .- remove_output[3] |> sum
                    @test remove_output_ref[10] == remove_output[10]
                    @test remove_output_ref[100] == remove_output[100]
                end
            end
        end
    end
end

@testset "sim! with other outputs" begin
    for proc in (SingleCPU(), ThreadedCPU(), CPUGPU()), opt in (NoOpt(), SparseOpt())
        @testset "$(nameof(typeof(opt))) $(nameof(typeof(proc)))" begin
            @testset "Transformed output" begin
                ruleset = Ruleset(Life();
                    timestep=Month(1),
                    boundary=Wrap(),
                    proc=proc,
                    opt=opt,
                )
                tspan_ = Date(2010, 4):Month(1):Date(2010, 7)
                output = TransformedOutput(sum, test6_7[:init]; tspan=tspan_)
                sim!(output, ruleset)
                @test output[1] == sum(test6_7[:init])
                @test output[2] == sum(test6_7[:test2])
                @test output[3] == sum(test6_7[:test3])
                @test output[4] == sum(test6_7[:test4])
            end
            @testset "REPLOutput block works, in Unitful.jl seconds" begin
                ruleset = Ruleset(;
                    rules=(Life(),),
                    timestep=5u"s",
                    boundary=Wrap(),
                    proc=proc,
                    opt=opt,
                )
                output = REPLOutput(test6_7[:init]; 
                    tspan=0u"s":5u"s":6u"s", style=Block(), fps=1000, store=true
                )
                @test DynamicGrids.isstored(output) == true
                sim!(output, ruleset)
                resume!(output, ruleset; tstop=30u"s")
                @test output[Ti(5u"s")] == test6_7[:test2]
                @test output[Ti(10u"s")] == test6_7[:test3]
                @test output[Ti(20u"s")] == test6_7[:test5]
                @test output[Ti(30u"s")] == test6_7[:test7]
            end
            @testset "REPLOutput braile works, in Months" begin
                ruleset = Ruleset(Life();
                    timestep=Month(1),
                    boundary=Wrap(),
                    proc=proc,
                    opt=opt,
                )
                tspan_ = Date(2010, 4):Month(1):Date(2010, 7)
                output = REPLOutput(test6_7[:init]; tspan=tspan_, style=Braile(), fps=1000, store=false)
                sim!(output, ruleset)
                @test output[Ti(Date(2010, 7))] == test6_7[:test4]
                @test DynamicGrids.tspan(output) == Date(2010, 4):Month(1):Date(2010, 7)
                resume!(output, ruleset; tstop=Date(2010, 10))
                @test DynamicGrids.tspan(output) == Date(2010, 4):Month(1):Date(2010, 10)
                @test output[1] == test6_7[:test7]
            end
        end
    end
end

@testset "GifOutput saves" begin
    @testset "Image generator" begin
        ruleset = Ruleset(;
            rules=(Life(),),
            boundary=Wrap(),
            timestep=5u"s",
            opt=NoOpt(),
        )
        output = GifOutput(test6_7[:init]; 
            filename="test_gifoutput.gif", text=nothing,
            tspan=0u"s":5u"s":30u"s", fps=10, store=true,
        )
        @test output.imageconfig.imagegen isa Image
        @test output.imageconfig.textconfig == nothing
        @test DynamicGrids.isstored(output) == true
        sim!(output, ruleset)
        @test output[Ti(5u"s")] == test6_7[:test2]
        @test output[Ti(10u"s")] == test6_7[:test3]
        @test output[Ti(20u"s")] == test6_7[:test5]
        @test output[Ti(30u"s")] == test6_7[:test7]
        gif = load("test_gifoutput.gif")
        @test gif == RGB.(output.gif)
        rm("test_gifoutput.gif")
    end
    @testset "Layout" begin
        zeroed = test6_7[:init]
        ruleset = Ruleset(Life{:a}(); boundary=Wrap())
        output = GifOutput((a=test6_7[:init], b=zeroed); 
            filename="test_gifoutput2.gif", text=nothing,               
            tspan=0u"s":5u"s":30u"s", fps=10, store=true
        )
        @test DynamicGrids.isstored(output) == true
        @test output.imageconfig.imagegen isa Layout
        @test output.imageconfig.textconfig == nothing
        sim!(output, ruleset)
        @test all(map(==, output[Ti(5u"s")], (a=test6_7[:test2], b=zeroed)))
        @test all(map(==, output[Ti(10u"s")], (a=test6_7[:test3], b=zeroed)))
        @test all(map(==, output[Ti(20u"s")], (a=test6_7[:test5], b=zeroed)))
        @test all(map(==, output[Ti(30u"s")], (a=test6_7[:test7], b=zeroed)))
        gif = load("test_gifoutput2.gif")
        @test gif == RGB.(output.gif)
        @test gif[:, 1, 7] == RGB{N0f8}.([1.0, 1.0, 0.298, 0.298, 0.298, 1.0])
        rm("test_gifoutput2.gif")
    end
end
