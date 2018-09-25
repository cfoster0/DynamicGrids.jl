using Mux

"""
A basic Mux.jl webserver, serving identical pages to BlinkOutput
"""
@Frames mutable struct MuxServer{F} <: AbstractWebOutput{T}
    port::Int
end


"""
    MuxServer(frames, model, args...; fps=25, port=8080)
Builds a MuxServer and serves the standard web interface for model
simulations at the chosen port. 

### Arguments
- `frames::AbstractArray`: vector of matrices.
- `model::Models`: tuple of models wrapped in Models().
- `args`: any additional arguments to be passed to the model rule

### Keyword arguments
- `fps`: frames per second
- `showmax_fps`: maximum displayed frames per second
- `port`: port number to reach the server at
"""
MuxServer(frames::T, model, args...; port=8080, kwargs...) where T <: AbstractVector = begin
    server = MuxServer(frames, port)
    store = false
    function muxapp(req)
        WebInterface(deepcopy(server.frames), deepcopy(model), args...; kwargs...).page
    end
    webio_serve(page("/", req -> muxapp(req)), port)
    server
end
