module ModelicaRag

include("Parser.jl")
include("Embedder.jl")
include("Store.jl")
include("MCP.jl")
include("CLI.jl")

using .CLI: main
export main, julia_main

function julia_main()::Cint
    try
        main()
        return 0
    catch err
        Base.invokelatest(Base.display_error, stderr, err, catch_backtrace())
        return 1
    end
end

end
