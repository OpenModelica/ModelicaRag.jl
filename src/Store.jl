module Store

using SQLite
using SQLite.DBInterface: execute
using LinearAlgebra

export open_store, clear_store, insert_chunk, insert_chunks_batch, search_chunks,
       insert_symbol, lookup_symbol, fuzzy_lookup, chunk_count, get_indexed_mtimes,
       set_file_mtime, delete_file_chunks

const SCHEMA = """
CREATE TABLE IF NOT EXISTS chunks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path   TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,
    symbol_name TEXT    NOT NULL,
    symbol_type TEXT    NOT NULL,
    content     TEXT    NOT NULL
);
CREATE TABLE IF NOT EXISTS symbols (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path   TEXT    NOT NULL,
    start_line  INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,
    symbol_name TEXT    NOT NULL,
    symbol_type TEXT    NOT NULL,
    content     TEXT    NOT NULL
);
CREATE TABLE IF NOT EXISTS embeddings (
    chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
    vector   BLOB    NOT NULL
);
CREATE TABLE IF NOT EXISTS file_meta (
    file_path TEXT    PRIMARY KEY,
    mtime     REAL    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_symbol    ON chunks(symbol_name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_file_path ON chunks(file_path);
CREATE INDEX IF NOT EXISTS idx_symbols_exact ON symbols(symbol_name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_path);
"""

struct ChunkRecord
    id::Int
    file_path::String
    start_line::Int
    end_line::Int
    symbol_name::String
    symbol_type::String
    content::String
end

struct SearchResult
    chunk::ChunkRecord
    similarity::Float32
end

function open_store(path::String)::SQLite.DB
    db = SQLite.DB(path)
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA foreign_keys=ON")
    for stmt in split(SCHEMA, ';')
        s = strip(stmt)
        isempty(s) || SQLite.execute(db, s)
    end
    db
end

function clear_store(db::SQLite.DB)
    SQLite.execute(db, "DELETE FROM embeddings")
    SQLite.execute(db, "DELETE FROM chunks")
    SQLite.execute(db, "DELETE FROM symbols")
    SQLite.execute(db, "DELETE FROM file_meta")
    SQLite.execute(db, "DELETE FROM sqlite_sequence WHERE name IN ('chunks', 'symbols')")
end

function get_indexed_mtimes(db::SQLite.DB)::Dict{String, Float64}
    rows = execute(db, "SELECT file_path, mtime FROM file_meta")
    Dict(row.file_path => row.mtime for row in rows)
end

function set_file_mtime(db::SQLite.DB, path::String, mtime::Float64)
    execute(db,
        "INSERT OR REPLACE INTO file_meta(file_path, mtime) VALUES(?, ?)",
        (path, mtime))
end

function delete_file_chunks(db::SQLite.DB, path::String)
    execute(db, "DELETE FROM chunks WHERE file_path = ?", (path,))
    execute(db, "DELETE FROM symbols WHERE file_path = ?", (path,))
    execute(db, "DELETE FROM file_meta WHERE file_path = ?", (path,))
end

function insert_symbol(db::SQLite.DB, chunk)
    execute(db,
        "INSERT INTO symbols(file_path,start_line,end_line,symbol_name,symbol_type,content) VALUES(?,?,?,?,?,?)",
        (chunk.file_path, chunk.start_line, chunk.end_line,
         chunk.symbol_name, chunk.symbol_type, chunk.content))
end

function insert_chunk(db::SQLite.DB, chunk, vec::Vector{Float32})
    SQLite.transaction(db) do
        execute(db,
            "INSERT INTO chunks(file_path,start_line,end_line,symbol_name,symbol_type,content) VALUES(?,?,?,?,?,?)",
            (chunk.file_path, chunk.start_line, chunk.end_line,
             chunk.symbol_name, chunk.symbol_type, chunk.content))
        id = SQLite.last_insert_rowid(db)
        execute(db,
            "INSERT INTO embeddings(chunk_id,vector) VALUES(?,?)",
            (id, vec_to_blob(vec)))
    end
end

function insert_chunks_batch(db::SQLite.DB, chunks, vecs, paths, mtimes)
    SQLite.transaction(db) do
        for (chunk, vec, path, mtime) in zip(chunks, vecs, paths, mtimes)
            insert_chunk(db, chunk, vec)
            set_file_mtime(db, path, mtime)
        end
    end
end

function search_chunks(db::SQLite.DB, query_vec::Vector{Float32}, top_k::Int = 5)::Vector{SearchResult}
    rows = execute(db, """
        SELECT c.id, c.file_path, c.start_line, c.end_line,
               c.symbol_name, c.symbol_type, c.content, e.vector
        FROM chunks c
        JOIN embeddings e ON c.id = e.chunk_id
    """)

    q_norm = norm(query_vec)
    q_norm == 0 && return SearchResult[]

    results = SearchResult[]
    for row in rows
        vec = blob_to_vec(row.vector)
        v_norm = norm(vec)
        v_norm == 0 && continue
        sim = Float32(dot(query_vec, vec) / (q_norm * v_norm))
        rec = ChunkRecord(row.id, row.file_path, row.start_line, row.end_line,
                          row.symbol_name, row.symbol_type, row.content)
        push!(results, SearchResult(rec, sim))
    end

    sort!(results; by = r -> -r.similarity)
    results[1:min(top_k, length(results))]
end

function lookup_symbol(db::SQLite.DB, name::String)::Vector{ChunkRecord}
    rows = execute(db, """
        SELECT id, file_path, start_line, end_line, symbol_name, symbol_type, content
        FROM (
            SELECT id, file_path, start_line, end_line, symbol_name, symbol_type, content
            FROM symbols
            WHERE symbol_name = ? COLLATE NOCASE
            UNION ALL
            SELECT c.id, c.file_path, c.start_line, c.end_line,
                   c.symbol_name, c.symbol_type, c.content
            FROM chunks c
            WHERE c.symbol_name = ? COLLATE NOCASE
              AND NOT EXISTS (
                  SELECT 1
                  FROM symbols s
                  WHERE lower(s.symbol_name) = lower(c.symbol_name)
                    AND s.file_path = c.file_path
              )
        )
        ORDER BY file_path, start_line
    """, (name, name))
    [ChunkRecord(row.id, row.file_path, row.start_line, row.end_line,
                 row.symbol_name, row.symbol_type, row.content)
     for row in rows]
end

function fuzzy_lookup(db::SQLite.DB, pattern::String, top_k::Int = 10)::Vector{ChunkRecord}
    like_pattern = "%" * replace(pattern, "%" => "\\%", "_" => "\\_") * "%"
    rows = execute(db, """
        SELECT id, file_path, start_line, end_line, symbol_name, symbol_type, content
        FROM (
            SELECT id, file_path, start_line, end_line, symbol_name, symbol_type, content
            FROM symbols
            WHERE symbol_name LIKE ? ESCAPE '\\'
            UNION ALL
            SELECT c.id, c.file_path, c.start_line, c.end_line,
                   c.symbol_name, c.symbol_type, c.content
            FROM chunks c
            WHERE c.symbol_name LIKE ? ESCAPE '\\'
              AND NOT EXISTS (
                  SELECT 1
                  FROM symbols s
                  WHERE lower(s.symbol_name) = lower(c.symbol_name)
                    AND s.file_path = c.file_path
              )
        )
        ORDER BY symbol_name COLLATE NOCASE, file_path, start_line
        LIMIT ?
    """, (like_pattern, like_pattern, top_k))
    [ChunkRecord(row.id, row.file_path, row.start_line, row.end_line,
                 row.symbol_name, row.symbol_type, row.content)
     for row in rows]
end

function chunk_count(db::SQLite.DB)::Int
    first(execute(db, "SELECT COUNT(*) AS n FROM chunks")).n
end

function vec_to_blob(v::Vector{Float32})::Vector{UInt8}
    reinterpret(UInt8, copy(v))
end

function blob_to_vec(blob)::Vector{Float32}
    b = collect(UInt8, blob)
    copy(reinterpret(Float32, b))
end

end # module Store
