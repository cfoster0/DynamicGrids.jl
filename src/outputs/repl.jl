"A wrapper for [`ArrayOutput`](@ref) that is displayed as asccii blocks in the REPL."
@premix struct X{X} end
@Ok @FPS @Frames @X mutable struct REPLOutput{C} <: AbstractOutput{T} 
    displayoffset::Array{Int}
    color::C
end
REPLOutput{X}(frames::AbstractVector; fps=25, color=:white) where X = begin
    t = time()
    REPLOutput{X,typeof.((frames, fps, t, color))...}(frames, fps, t, [true], [false], [1,1], color)
end


initialize(output::REPLOutput, args...) = begin
    output.displayoffset .= (1, 1)
    # Terminal.enableRawMode()
    @async movedisplay(output)
end

# finalize(output::REPLOutput, args...) = Terminal.disableRawMode()

movedisplay(output) = begin
    while is_ok(output)
        c = Terminal.readKey()
        c == "Up"      && move_y!(output, -1)
        c == "Down"    && move_y!(output, 1)
        c == "Left"    && move_x!(output, -1)
        c == "Right"   && move_x!(output, 1)
        c == "PgUp"    && move_y!(output, -10)
        c == "PgDown"  && move_y!(output, 10)
        c == '\x1b'    && set_ok(output, false)
        c in ["Ctrl-C"]  && set_ok(output, false)
    end
end

move_y!(output, n) = begin
    dispy, dispx = displaysize(Base.STDOUT)
    y, x = size(output[1])
    output.displayoffset[1] = max(0, min(y-dispy, output.displayoffset[1] + 2n))
end
move_x!(output, n) = begin
    dispy, dispx = displaysize(Base.STDOUT)
    y, x = size(output[1])
    output.displayoffset[2] = max(0, min(x-dispx, output.displayoffset[2] + 2n))
end

"""
    show_frame(output::REPLOutput, t)
Extends show_frame from [`ArrayOuput`](@ref) by also printing to the REPL.
"""
show_frame(output::REPLOutput, t) = begin
    try
        Terminal.put([0,0], output.color, replshow(output, t))
    catch err
        set_ok(output, false)
        throw(err)
    end
    delay(output)
    is_ok(output)
end

"""
    Base.show(io::IO, output::REPLOutput)
Print the last frame of a simulation in the REPL.
"""
Base.show(io::IO, output::REPLOutput) = begin
    println(io, typeof(output))
    length(output) == 0 || print(repl_frame(output[end]))
end

replshow(output::REPLOutput{:braile}, t) = replframe(output, t, 4, 2, brailize) 
replshow(output::REPLOutput{:block}, t) = replframe(output, t, 2, 1, blockize) 

function replframe(output, t, ystep, xstep, f)
    frame = output[t]
    # Limit output area to available terminal size.
    dispy, dispx = dispsize = displaysize(Base.STDOUT)
    youtput, xoutput = outputsize = size(frame)
    yoffset, xoffset = output.displayoffset

    yrange = max(1, yoffset):min(youtput-1, ystep * (dispy + yoffset - 1))
    xrange = max(1, xoffset):min(xoutput, xstep * (dispx + xoffset - 1))
    let frame=frame, yrange=yrange, xrange=xrange
        f(frame, 0.5, yrange, xrange)
    end
end
