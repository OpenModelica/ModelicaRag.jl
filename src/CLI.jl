module CLI

using ..Parser
using ..Embedder
using ..Store
using ..MCP
using TOML
using HTTP
using JSON3
using SQLite

export main, index_lib

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

struct Config
    embed_backend::String  # "ollama" or "llama"
    embed_url::String
    embed_model::String    # Ollama model name (ignored for llama backend)
    embed_batch_size::Int
    store_path::String
    codebase_root::String
    codebase_extensions::Vector{String}
    server_exe::String     # path to llama-server binary (llama backend only)
    server_model::String   # path to GGUF model file (llama backend only)
end

function load_config(path::String)::Config
    raw = TOML.parsefile(path)
    e   = get(raw, "embeddings", Dict())
    s   = get(raw, "store",      Dict())
    c   = get(raw, "codebase",   Dict())
    sv  = get(raw, "server",     Dict())
    Config(
        get(e,  "backend",      "llama"),
        get(e,  "url",          "http://localhost:8080"),
        get(e,  "model",        "nomic-embed-text"),
        get(e,  "batch_size",   32),
        get(s,  "path",         "data/index.db"),
        get(c,  "root",         "."),
        get(c,  "extensions",   [".mo"]),
        expanduser(get(sv, "llama_server", "~/llama.cpp/build/bin/llama-server")),
        expanduser(get(sv, "model_path",   "~/llama.cpp/models/Qwen3-Embedding-8B-Q8_0.gguf")),
    )
end

function make_embedder(cfg::Config)
    if cfg.embed_backend == "ollama"
        OllamaEmbedder(cfg.embed_url, cfg.embed_model)
    else
        LlamaEmbedder(cfg.embed_url)
    end
end

# ---------------------------------------------------------------------------
# Server management
# ---------------------------------------------------------------------------

function server_healthy(url::String)::Bool
    try
        resp = HTTP.get(url * "/health"; readtimeout = 2, retry = false)
        get(JSON3.read(resp.body), :status, "") == "ok"
    catch
        false
    end
end

# Start llama-server if it is not already running.
# Returns the Process if we started it (caller must kill on exit), or nothing
# if it was already running.
function ensure_server(cfg::Config)::Union{Base.Process, Nothing}
    server_healthy(cfg.embed_url) && return nothing

    isfile(cfg.server_exe)   || (@error "llama-server not found: $(cfg.server_exe)";   exit(1))
    isfile(cfg.server_model) || (@error "Model file not found: $(cfg.server_model)";    exit(1))

    m    = match(r":(\d+)$", cfg.embed_url)
    port = isnothing(m) ? 8080 : parse(Int, m[1])

    # Log goes to the package root (one level above src/).
    log_path = joinpath(dirname(@__DIR__), "llama-server.log")
    log_file = open(log_path, "a")

    @info "Starting llama-server (model: $(basename(cfg.server_model))) ..."
    cmd  = `$(cfg.server_exe) -m $(cfg.server_model) --port $port
            --embeddings --ctx-size 8192 --parallel 8 --batch-size 512 -ngl 99 --log-disable`
    proc = run(pipeline(cmd; stdout = log_file, stderr = log_file); wait = false)

    for i in 1:60
        sleep(2)
        server_healthy(cfg.embed_url) && (@info "llama-server ready."; return proc)
    end

    kill(proc)
    close(log_file)
    @error "llama-server did not become ready within 120 s. See $log_path"
    exit(1)
end

# ---------------------------------------------------------------------------
# Index command
# ---------------------------------------------------------------------------

function cmd_index(cfg::Config, db::SQLite.DB, embedder;
                   root::String = cfg.codebase_root, force::Bool = false)
    if force
        @info "Force rebuild of $root: clearing chunks for that subtree ..."
        # Only clear chunks that belong to this root, not the whole DB.
        indexed_mtimes = get_indexed_mtimes(db)
        for path in keys(indexed_mtimes)
            startswith(path, root) && delete_file_chunks(db, path)
        end
    end

    exts  = Set(cfg.codebase_extensions)
    files = String[]
    for (dir, dirs, filenames) in walkdir(root)
        filter!(d -> !startswith(d, '.'), dirs)
        for f in filenames
            any(endswith(f, ext) for ext in exts) && push!(files, joinpath(dir, f))
        end
    end

    indexed_mtimes = get_indexed_mtimes(db)
    disk_paths     = Set(files)

    # Remove DB entries for files that have been deleted from this root.
    for path in keys(indexed_mtimes)
        startswith(path, root) && path ∉ disk_paths && delete_file_chunks(db, path)
    end

    to_index = filter(files) do path
        mtime = Float64(stat(path).mtime)
        get(indexed_mtimes, path, -1.0) != mtime
    end

    n_skipped = length(files) - length(to_index)
    @info "$(length(files)) files in $root — $(length(to_index)) changed, $n_skipped unchanged (skipped)"

    isempty(to_index) && (@info "Index is up to date."; return)

    total_chunks = 0
    batch_texts  = String[]
    batch_chunks = Any[]
    batch_paths  = String[]

    function flush_batch()
        isempty(batch_chunks) && return
        vecs = embed_batch(embedder, batch_texts)
        mtimes = [Float64(stat(p).mtime) for p in batch_paths]
        insert_chunks_batch(db, batch_chunks, vecs, batch_paths, mtimes)
        total_chunks += length(batch_chunks)
        empty!(batch_texts); empty!(batch_chunks); empty!(batch_paths)
    end

    for (fi, path) in enumerate(to_index)
        haskey(indexed_mtimes, path) && delete_file_chunks(db, path)

        chunks = parse_file(path)
        isempty(chunks) && (set_file_mtime(db, path, Float64(stat(path).mtime)); continue)

        for chunk in chunks
            text = "$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
            push!(batch_texts,  text)
            push!(batch_chunks, chunk)
            push!(batch_paths,  path)
            length(batch_chunks) >= cfg.embed_batch_size && flush_batch()
        end

        if fi % 20 == 0 || fi == length(to_index)
            @info "  $fi / $(length(to_index)) files  |  $total_chunks new chunks so far"
        end
    end

    flush_batch()
    @info "Done indexing $root. $(chunk_count(db)) total chunks in the index."
end

# Top-level index command: opens server + DB, then delegates to cmd_index.
function cmd_index_toplevel(cfg::Config; force::Bool = false)
    proc = cfg.embed_backend == "llama" ? ensure_server(cfg) : nothing
    proc !== nothing && atexit(() -> (kill(proc); @info "llama-server stopped."))

    embedder = make_embedder(cfg)
    @info "Embedding backend: $(cfg.embed_backend) at $(cfg.embed_url)."

    mkpath(dirname(cfg.store_path))
    db = open_store(cfg.store_path)

    cmd_index(cfg, db, embedder; root = cfg.codebase_root, force)
end

"""
    index_lib(path; config = "config.toml", force = false)

Index a Modelica library at `path` into the configured store.
Uses the embedding backend and database from `config`.
Incremental by default — only re-embeds changed files.
"""
function index_lib(path::String;
                   config::String = joinpath(dirname(@__DIR__), "config.toml"),
                   force::Bool    = false)
    isdir(path)   || error("Not a directory: $path")
    isfile(config) || error("Config not found: $config")

    cfg      = load_config(config)
    proc     = cfg.embed_backend == "llama" ? ensure_server(cfg) : nothing
    proc !== nothing && atexit(() -> (kill(proc); @info "llama-server stopped."))

    mkpath(dirname(cfg.store_path))
    db       = open_store(cfg.store_path)
    embedder = make_embedder(cfg)

    cmd_index(cfg, db, embedder; root = abspath(path), force)
end

# ---------------------------------------------------------------------------
# Serve command
# ---------------------------------------------------------------------------

function cmd_serve(cfg::Config)
    proc = cfg.embed_backend == "llama" ? ensure_server(cfg) : nothing
    proc !== nothing && atexit(() -> (kill(proc); @info "llama-server stopped."))

    mkpath(dirname(cfg.store_path))
    db       = open_store(cfg.store_path)
    n        = chunk_count(db)
    embedder = make_embedder(cfg)

    @info "ModelicaRag MCP server ready  ($n chunks indexed)" stderr = stderr

    search_fn = (query::String, top_k::Int) -> begin
        vec = embed(embedder, query)
        search_chunks(db, vec, top_k)
    end

    lookup_fn = (name::String) -> lookup_symbol(db, name)

    rebuild_fn = (force::Bool) -> begin
        @info "$(force ? "Force rebuilding" : "Incrementally updating") index ..."
        try
            cmd_index(cfg, db, embedder; root = cfg.codebase_root, force)
            n = chunk_count(db)
            "Index $(force ? "rebuilt" : "updated") successfully. $n chunks now indexed."
        catch e
            "Index rebuild failed: $e"
        end
    end

    index_lib_fn = (path::String, force::Bool) -> begin
        isdir(path) || return "Error: not a directory: $path"
        @info "Indexing library at $path (force=$force) ..."
        try
            cmd_index(cfg, db, embedder; root = abspath(path), force)
            n = chunk_count(db)
            "Library indexed successfully. $n total chunks now in the index."
        catch e
            "Index failed: $e"
        end
    end

    serve_mcp(search_fn, lookup_fn, rebuild_fn, index_lib_fn)
end

# ---------------------------------------------------------------------------
# Search command
# ---------------------------------------------------------------------------

function cmd_search(cfg::Config, query::String; top_k::Int = 5)
    proc = cfg.embed_backend == "llama" ? ensure_server(cfg) : nothing
    proc !== nothing && atexit(() -> kill(proc))

    db       = open_store(cfg.store_path)
    embedder = make_embedder(cfg)
    vec      = embed(embedder, query)
    results  = search_chunks(db, vec, top_k)
    if isempty(results)
        println("No results found.")
        return
    end
    for (i, r) in enumerate(results)
        c = r.chunk
        println("── $i  (similarity $(round(r.similarity; digits=3))) ──────────────────")
        println("$(c.symbol_type)  $(c.symbol_name)")
        println("$(c.file_path):$(c.start_line)-$(c.end_line)")
        println()
        println(c.content)
        println()
    end
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function main(args = ARGS)
    isempty(args) && (println(stderr, "Usage: ModelicaRag.main([\"index\"|\"serve\"|\"search\", ...])"); exit(1))

    command     = args[1]
    config_path = "config.toml"
    force       = false
    top_k       = 5
    query_parts = String[]

    i = 2
    while i <= length(args)
        if args[i] in ("--config", "-c") && i + 1 <= length(args)
            config_path = args[i+1]
            i += 2
        elseif args[i] == "--force"
            force = true
            i += 1
        elseif args[i] in ("--top-k", "-k") && i + 1 <= length(args)
            top_k = parse(Int, args[i+1])
            i += 2
        else
            push!(query_parts, args[i])
            i += 1
        end
    end

    # Resolve config relative to the package root (one level above src/).
    if !isabspath(config_path)
        config_path = joinpath(dirname(@__DIR__), config_path)
    end

    isfile(config_path) || (println(stderr, "Config not found: $config_path"); exit(1))
    cfg = load_config(config_path)

    if command == "index"
        cmd_index_toplevel(cfg; force)
    elseif command == "serve"
        cmd_serve(cfg)
    elseif command == "search"
        isempty(query_parts) && (println(stderr, "Usage: ModelicaRag.main([\"search\", \"<query>\", ...])"); exit(1))
        cmd_search(cfg, join(query_parts, " "); top_k)
    else
        println(stderr, "Unknown command: $command  (expected index, serve, or search)")
        exit(1)
    end
end

end # module CLI
