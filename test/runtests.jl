using Test
using ModelicaRag
using ModelicaRag: Parser, Store

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures")

include("test_parser.jl")
include("test_store.jl")
include("test_integration.jl")
