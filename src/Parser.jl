module Parser

using MetaModelica
import Absyn
import OMParser

export Chunk, parse_file

struct Chunk
    file_path::String
    start_line::Int
    end_line::Int
    symbol_name::String  # qualified: "Modelica.Electrical.Analog.Basic.Resistor"
    symbol_type::String  # "model", "function", "record", "block", "connector", etc.
    content::String      # raw Modelica source lines
end

const SEARCH_CHUNK_TARGET_LINES  = 48
const SEARCH_CHUNK_OVERLAP_LINES = 8
const SEARCH_CHUNK_MIN_LINES     = 12
const SPLIT_BOUNDARY_RE = r"^\s*(?:equation|initial\s+equation|algorithm|initial\s+algorithm|annotation|public|protected)\b"

# Maps an Absyn.Path to a dot-separated string.
function absyn_path_to_string(p)::String
    @match p begin
        Absyn.IDENT(name)           => name
        Absyn.QUALIFIED(name, rest) => name * "." * absyn_path_to_string(rest)
        Absyn.FULLYQUALIFIED(inner) => absyn_path_to_string(inner)
    end
end

# Maps an Absyn.Restriction to a human-readable symbol_type string.
function restriction_to_string(r)::String
    @match r begin
        Absyn.R_MODEL()           => "model"
        Absyn.R_FUNCTION(__)      => "function"
        Absyn.R_RECORD()          => "record"
        Absyn.R_BLOCK()           => "block"
        Absyn.R_CONNECTOR()       => "connector"
        Absyn.R_EXP_CONNECTOR()   => "connector"
        Absyn.R_TYPE()            => "type"
        Absyn.R_PACKAGE()         => "package"
        Absyn.R_CLASS()           => "class"
        Absyn.R_OPERATOR()        => "operator"
        Absyn.R_OPERATOR_RECORD() => "operator_record"
        Absyn.R_ENUMERATION()     => "enumeration"
        Absyn.R_OPTIMIZATION()    => "optimization"
        _                         => "class"
    end
end

# Returns all direct child Class nodes nested inside a class's body.
# Searches PUBLIC and PROTECTED sections for CLASSDEF element specs.
function collect_nested_classes(cls)
    result = []

    parts_list = @match cls.body begin
        Absyn.PARTS(classParts = cp)    => cp
        Absyn.CLASS_EXTENDS(parts = cp) => cp
        _                               => return result
    end

    for part in parts_list
        elem_items = @match part begin
            Absyn.PUBLIC(contents = c)    => c
            Absyn.PROTECTED(contents = c) => c
            _                             => nothing
        end
        isnothing(elem_items) && continue

        for item in elem_items
            @match item begin
                Absyn.ELEMENTITEM(
                    Absyn.ELEMENT(specification = Absyn.CLASSDEF(class_ = inner))
                ) => push!(result, inner)
                _ => nothing
            end
        end
    end

    result
end

function is_split_boundary(line::AbstractString)::Bool
    stripped = strip(line)
    isempty(stripped) && return true
    occursin(SPLIT_BOUNDARY_RE, stripped)
end

function choose_split_end(lines::AbstractVector{<:AbstractString}, start_idx::Int, target_end::Int,
                          min_end::Int, lookaround::Int)::Int
    n = length(lines)
    hi = min(n, target_end + lookaround)
    lo = max(min_end, target_end - lookaround)

    for idx in target_end:hi
        is_split_boundary(lines[idx]) && return idx
    end
    for idx in target_end:-1:lo
        is_split_boundary(lines[idx]) && return idx
    end

    target_end
end

function search_subchunks(chunk::Chunk;
                          target_lines::Int = SEARCH_CHUNK_TARGET_LINES,
                          overlap_lines::Int = SEARCH_CHUNK_OVERLAP_LINES,
                          min_lines::Int = SEARCH_CHUNK_MIN_LINES)::Vector{Chunk}
    lines = split(chunk.content, '\n')
    n     = length(lines)
    n <= target_lines && return [chunk]

    lookaround = max(2, min(target_lines ÷ 3, overlap_lines + 4))
    pieces     = Chunk[]
    start_idx  = 1

    while start_idx <= n
        target_end = min(n, start_idx + target_lines - 1)
        min_end    = min(n, start_idx + min_lines - 1)
        stop_idx   = if target_end == n || n - target_end < min_lines
            n
        else
            choose_split_end(lines, start_idx, target_end, min_end, lookaround)
        end

        stop_idx = clamp(stop_idx, start_idx, n)
        if stop_idx < n && n - stop_idx < min_lines
            stop_idx = n
        end

        content = join(lines[start_idx:stop_idx], "\n")
        if !isempty(strip(content))
            push!(pieces, Chunk(
                chunk.file_path,
                chunk.start_line + start_idx - 1,
                chunk.start_line + stop_idx - 1,
                chunk.symbol_name,
                chunk.symbol_type,
                content,
            ))
        end

        stop_idx == n && break

        next_start = max(start_idx + 1, stop_idx - overlap_lines + 1)
        next_start <= start_idx && (next_start = stop_idx + 1)
        start_idx = next_start
    end

    isempty(pieces) ? [chunk] : pieces
end

# Parse a Modelica source file and return a vector of Chunks.
# Uses OMParser.jl for accurate AST-based extraction.
# Strategy:
#   - Packages are not emitted as chunks (they can be enormous); we recurse into them.
#   - Every other class kind (model, function, record, block, connector, type, etc.)
#     becomes one chunk containing its full source text.
#   - Qualified names are built from the file's `within` clause plus ancestor package names.
function parse_file(path::String)::Vector{Chunk}
    source = try
        read(path, String)
    catch e
        @warn "Cannot read $path: $e"
        return Chunk[]
    end
    lines = split(source, '\n')  # 1-indexed array of source lines

    program = try
        OMParser.parseFile(path)
    catch e
        @warn "Parse error in $path: $e"
        return Chunk[]
    end

    # The `within` clause tells us the package prefix for top-level classes in this file.
    file_prefix = @match program.within_ begin
        Absyn.WITHIN(path = p) => absyn_path_to_string(p)
        Absyn.TOP()             => ""
    end

    chunks     = Chunk[]
    work_stack = [(cls, file_prefix) for cls in program.classes]

    while !isempty(work_stack)
        cls, prefix = pop!(work_stack)

        # Build the qualified name for this class.
        qname = isempty(prefix) ? cls.name : prefix * "." * cls.name
        rtype = restriction_to_string(cls.restriction)

        # Skip synthetic/built-in nodes — OMParser gives them lineNumberStart = 0.
        cls.info.lineNumberStart == 0 && continue

        # Check if this is a package.
        is_pkg = @match cls.restriction begin
            Absyn.R_PACKAGE() => true
            _                 => false
        end

        # Emit a chunk for non-package classes.
        if !is_pkg
            lo      = max(1, cls.info.lineNumberStart)
            hi      = min(length(lines), cls.info.lineNumberEnd)
            content = lo <= hi ? join(lines[lo:hi], "\n") : ""
            push!(chunks, Chunk(path, lo, hi, qname, rtype, content))
        end

        # Always recurse to discover nested classes (packages for breadth, others for depth).
        for child in collect_nested_classes(cls)
            push!(work_stack, (child, qname))
        end
    end

    chunks
end

end # module Parser
