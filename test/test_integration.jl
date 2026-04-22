using LinearAlgebra: normalize

# Integration tests combine the parser and store without a live embedding server.
# Tests that require an embedding server are skipped unless one is reachable.

function embedding_server_available(url)
    try
        resp = ModelicaRag.Embedder.embed(ModelicaRag.Embedder.OllamaEmbedder(url, "nomic-embed-text"), "test")
        !isempty(resp)
    catch
        false
    end
end

function llama_server_available(url)
    try
        resp = ModelicaRag.Embedder.embed(ModelicaRag.Embedder.LlamaEmbedder(url), "test")
        !isempty(resp)
    catch
        false
    end
end

@testset "Integration — parse + store pipeline (synthetic embeddings)" begin
    path   = joinpath(dirname(@__DIR__), "Models", "msl.mo")
    chunks = Parser.parse_file(path)
    @test !isempty(chunks)

    db = Store.open_store(tempname() * ".db")

    # Index a sample of chunks with random unit-norm embeddings (768-dim)
    sample = chunks[1:min(50, length(chunks))]
    for chunk in sample
        vec = normalize(randn(Float32, 768))
        Store.insert_chunk(db, chunk, vec)
        Store.set_file_mtime(db, chunk.file_path, 1.0)
    end

    @test Store.chunk_count(db) == length(sample)

    # Lookup a class that we know is in the sample
    first_name = sample[1].symbol_name
    hits = Store.lookup_symbol(db, first_name)
    @test !isempty(hits)
    @test hits[1].symbol_name == first_name

    # Search returns top_k results
    query   = normalize(randn(Float32, 768))
    results = Store.search_chunks(db, query, 5)
    @test length(results) <= 5
    @test issorted(results; by = r -> -r.similarity)
end

@testset "Integration — incremental indexing skips unchanged files" begin
    path   = joinpath(FIXTURE_DIR, "HelloWorld.mo")
    chunks = Parser.parse_file(path)
    db     = Store.open_store(tempname() * ".db")

    mtime = Float64(stat(path).mtime)

    # First pass: index the file
    for chunk in chunks
        Store.insert_chunk(db, chunk, normalize(randn(Float32, 64)))
    end
    Store.set_file_mtime(db, path, mtime)

    n_after_first = Store.chunk_count(db)
    @test n_after_first == length(chunks)

    # Second pass: mtime unchanged, so nothing should be re-indexed
    indexed = Store.get_indexed_mtimes(db)
    to_reindex = filter(p -> Float64(stat(p).mtime) != get(indexed, p, -1.0), [path])
    @test isempty(to_reindex)
end

if embedding_server_available("http://localhost:11434")
    @testset "Integration — live embedding server (Ollama)" begin
        path     = joinpath(FIXTURE_DIR, "HelloWorld.mo")
        chunks   = Parser.parse_file(path)
        embedder = ModelicaRag.Embedder.OllamaEmbedder("http://localhost:11434", "nomic-embed-text")
        db       = Store.open_store(tempname() * ".db")

        for chunk in chunks
            text = "$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
            vec  = ModelicaRag.Embedder.embed(embedder, text)
            @test !isempty(vec)
            Store.insert_chunk(db, chunk, vec)
        end

        results = Store.search_chunks(db, ModelicaRag.Embedder.embed(embedder, "simple ODE model"), 1)
        @test !isempty(results)
        @test results[1].chunk.symbol_name == "HelloWorld"
    end
else
    @info "Skipping live Ollama test (server not available at http://localhost:11434)"
end

if llama_server_available("http://localhost:8080")
    @testset "Integration — live embedding server (llama-server)" begin
        path     = joinpath(FIXTURE_DIR, "HelloWorld.mo")
        chunks   = Parser.parse_file(path)
        embedder = ModelicaRag.Embedder.LlamaEmbedder("http://localhost:8080")
        db       = Store.open_store(tempname() * ".db")

        for chunk in chunks
            text = "$(chunk.symbol_type) $(chunk.symbol_name)\n$(first(chunk.content, 512))"
            vec  = ModelicaRag.Embedder.embed(embedder, text)
            @test !isempty(vec)
            Store.insert_chunk(db, chunk, vec)
        end

        results = Store.search_chunks(db, ModelicaRag.Embedder.embed(embedder, "simple ODE model"), 1)
        @test !isempty(results)
        @test results[1].chunk.symbol_name == "HelloWorld"
    end
else
    @info "Skipping live llama-server test (server not available at http://localhost:8080)"
end
