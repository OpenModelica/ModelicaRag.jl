using LinearAlgebra: normalize

# Helper: build a minimal named-tuple chunk compatible with store.jl
function fake_chunk(name; file = "test.mo", line = 1, typ = "model", content = "model $name end $name;")
    (file_path = file, start_line = line, end_line = line + 5,
     symbol_name = name, symbol_type = typ, content = content)
end

@testset "Store — open and empty" begin
    db = Store.open_store(tempname() * ".db")
    @test Store.chunk_count(db) == 0
    @test isempty(Store.get_indexed_mtimes(db))
end

@testset "Store — insert and count" begin
    db  = Store.open_store(tempname() * ".db")
    vec = Float32[1.0, 0.0, 0.0]
    Store.insert_chunk(db, fake_chunk("M"), vec)
    @test Store.chunk_count(db) == 1
end

@testset "Store — cosine similarity: exact match scores 1.0" begin
    db  = Store.open_store(tempname() * ".db")
    vec = normalize(Float32[1.0, 2.0, 3.0])
    Store.insert_chunk(db, fake_chunk("X"), vec)

    results = Store.search_chunks(db, vec, 1)
    @test length(results) == 1
    @test results[1].similarity ≈ 1.0f0 atol = 1e-6
    @test results[1].chunk.symbol_name == "X"
end

@testset "Store — cosine similarity ordering" begin
    db = Store.open_store(tempname() * ".db")

    # Three vectors at known angles from the query [1, 0, 0]
    Store.insert_chunk(db, fake_chunk("A"), Float32[1.0, 0.0, 0.0])  # cos = 1.0
    Store.insert_chunk(db, fake_chunk("B"), Float32[0.0, 1.0, 0.0])  # cos = 0.0
    Store.insert_chunk(db, fake_chunk("C"), Float32[1.0, 1.0, 0.0])  # cos ≈ 0.707

    query   = Float32[1.0, 0.0, 0.0]
    results = Store.search_chunks(db, query, 3)
    ranked  = [r.chunk.symbol_name for r in results]

    @test ranked[1] == "A"
    @test ranked[2] == "C"
    @test ranked[3] == "B"
end

@testset "Store — lookup_symbol (case-insensitive)" begin
    db  = Store.open_store(tempname() * ".db")
    vec = Float32[1.0, 0.0, 0.0]
    Store.insert_chunk(db, fake_chunk("Resistor"), vec)

    @test length(Store.lookup_symbol(db, "Resistor")) == 1
    @test length(Store.lookup_symbol(db, "resistor")) == 1
    @test length(Store.lookup_symbol(db, "RESISTOR")) == 1
    @test isempty(Store.lookup_symbol(db, "Capacitor"))
end

@testset "Store — symbols shadow search chunks for exact and fuzzy lookup" begin
    db  = Store.open_store(tempname() * ".db")
    vec = Float32[1.0, 0.0, 0.0]

    symbol = fake_chunk("Resistor"; line = 10, content = "model Resistor\n  parameter Real R = 1;\nend Resistor;")
    Store.insert_symbol(db, symbol)
    Store.insert_chunk(db, fake_chunk("Resistor"; line = 10, content = "model Resistor"), vec)
    Store.insert_chunk(db, fake_chunk("Resistor"; line = 11, content = "  parameter Real R = 1;"), vec)

    exact_hits = Store.lookup_symbol(db, "Resistor")
    @test length(exact_hits) == 1
    @test exact_hits[1].start_line == 10
    @test exact_hits[1].end_line == 15
    @test exact_hits[1].content == symbol.content

    fuzzy_hits = Store.fuzzy_lookup(db, "sist", 10)
    @test length(fuzzy_hits) == 1
    @test fuzzy_hits[1].content == symbol.content
end

@testset "Store — mtime tracking" begin
    db = Store.open_store(tempname() * ".db")

    Store.set_file_mtime(db, "a.mo", 1000.0)
    Store.set_file_mtime(db, "b.mo", 2000.0)
    mtimes = Store.get_indexed_mtimes(db)

    @test mtimes["a.mo"] == 1000.0
    @test mtimes["b.mo"] == 2000.0

    # Upsert — update existing mtime
    Store.set_file_mtime(db, "a.mo", 9999.0)
    @test Store.get_indexed_mtimes(db)["a.mo"] == 9999.0
end

@testset "Store — delete_file_chunks removes chunks and mtime" begin
    db  = Store.open_store(tempname() * ".db")
    vec = Float32[1.0, 0.0, 0.0]

    Store.insert_chunk(db, fake_chunk("M1"; file = "keep.mo"), vec)
    Store.insert_chunk(db, fake_chunk("M2"; file = "drop.mo"), vec)
    Store.insert_symbol(db, fake_chunk("M1"; file = "keep.mo"))
    Store.insert_symbol(db, fake_chunk("M2"; file = "drop.mo"))
    Store.set_file_mtime(db, "keep.mo", 1.0)
    Store.set_file_mtime(db, "drop.mo", 2.0)

    Store.delete_file_chunks(db, "drop.mo")

    @test Store.chunk_count(db) == 1
    @test !haskey(Store.get_indexed_mtimes(db), "drop.mo")
    @test  haskey(Store.get_indexed_mtimes(db), "keep.mo")

    results = Store.search_chunks(db, vec, 5)
    @test all(r.chunk.symbol_name != "M2" for r in results)
    @test isempty(Store.lookup_symbol(db, "M2"))
    @test length(Store.lookup_symbol(db, "M1")) == 1
end

@testset "Store — clear_store empties everything" begin
    db  = Store.open_store(tempname() * ".db")
    vec = Float32[1.0, 0.0, 0.0]
    Store.insert_chunk(db, fake_chunk("M"), vec)
    Store.set_file_mtime(db, "test.mo", 1.0)

    Store.clear_store(db)

    @test Store.chunk_count(db) == 0
    @test isempty(Store.get_indexed_mtimes(db))
end
