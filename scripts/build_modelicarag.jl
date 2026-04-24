#!/usr/bin/env julia

import Pkg

const PROJECT_DIR = normpath(joinpath(@__DIR__, ".."))
const BUILD_ROOT = joinpath(PROJECT_DIR, "build")
const APP_DIR = joinpath(BUILD_ROOT, "modelicarag-app")
const LAUNCHER_PATH = joinpath(BUILD_ROOT, "modelicarag")
const BUILD_ENV = mktempdir()

try
    Pkg.activate(BUILD_ENV)
    Pkg.add(Pkg.PackageSpec(name = "PackageCompiler", version = "2"))

    @eval using PackageCompiler

    mkpath(BUILD_ROOT)

    PackageCompiler.create_app(
        PROJECT_DIR,
        APP_DIR;
        executables = ["modelicarag" => "julia_main"],
        force = true,
        incremental = false,
    )

    open(LAUNCHER_PATH, "w") do io
        println(io, "#!/usr/bin/env bash")
        println(io, "set -euo pipefail")
        println(io, "SCRIPT_DIR=\"\$(cd -- \"\$(dirname -- \"\${BASH_SOURCE[0]}\")\" && pwd)\"")
        println(io, "exec \"\$SCRIPT_DIR/modelicarag-app/bin/modelicarag\" \"\$@\"")
    end

    chmod(LAUNCHER_PATH, 0o755)

    println("Build complete.")
    println("Executable launcher: " * LAUNCHER_PATH)
    println("App bundle: " * APP_DIR)
finally
    rm(BUILD_ENV; recursive = true, force = true)
end
