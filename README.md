# ModelicaRag.jl

Semantic search over Modelica libraries via a local RAG (Retrieval-Augmented Generation) pipeline. Parses Modelica source files using [OMParser.jl](https://github.com/OpenModelica/OMCompiler), embeds each class with a local embedding model, stores the index in SQLite, and exposes search through an [MCP](https://modelcontextprotocol.io) server that Claude Code can query.

## How it works

1. **Parse** — `OMParser.jl` parses each `.mo` file into an Absyn AST. The walker extracts every non-package class (model, function, record, block, connector, type, ...) as a full symbol record with its fully qualified name (e.g. `Modelica.Electrical.Analog.Basic.Resistor`) and source lines.
2. **Embed** — each full symbol is split into smaller line-bounded search subchunks before embedding. Only files that changed since the last run are re-indexed.
3. **Store** — SQLite keeps both the full symbol records for exact lookups and the embedded search subchunks for semantic retrieval. Cosine similarity search is computed in Julia at query time.
4. **Serve** — an MCP stdio server exposes three tools: `search_codebase`, `lookup_symbol`, and `rebuild_index`.

## Requirements

- Julia 1.9+
- OMParser.jl (from the OM.jl monorepo)
- One of:
  - A GitHub personal access token — uses the [GitHub Models](https://github.com/marketplace/models) free embedding API (no local server required)
  - [Ollama](https://ollama.ai) with an embedding model (e.g. `nomic-embed-text`, `mxbai-embed-large`)
  - [llama.cpp](https://github.com/ggerganov/llama.cpp) `llama-server` with a GGUF embedding model

## Installation

```julia
import Pkg

# Develop the OM.jl local dependencies (adjust path as needed)
Pkg.develop(path="/path/to/OM.jl/OMParser.jl")

# Develop this package — runs setup.jl automatically via deps/build.jl
Pkg.develop(path="/path/to/ModelicaRag.jl")
```

`setup.jl` detects Ollama and llama-server on your system and writes a `config.toml`. If the Modelica library path is not found automatically, edit `config.toml` and set `[codebase] root`.

You can also run setup manually at any time (it will not overwrite an existing `config.toml`):

```
julia setup.jl
```

## Configuration

`config.toml` is machine-specific and not tracked by git. Copy the provided example and edit the paths:

```
cp config.toml.example config.toml
```

Then open `config.toml` and fill in the paths for your system. The key fields:

Three backends are supported. Choose one in `config.toml`:

**GitHub Models** (recommended — no local server required):

```toml
[embeddings]
backend    = "github_models"
model      = "text-embedding-3-small"   # or "text-embedding-3-large"
batch_size = 32
```

Set your token in the environment before running. Do not put it in `config.toml`:

```
export GITHUB_TOKEN=github_pat_...
```

GitHub Models is free for all GitHub users: 150 embedding requests/day per token.

**Ollama**:

```toml
[embeddings]
backend    = "ollama"
url        = "http://localhost:11434"
model      = "nomic-embed-text"
batch_size = 32
```

Pull the model first: `ollama pull nomic-embed-text`

**llama-server**:

```toml
[embeddings]
backend    = "llama"
url        = "http://localhost:8080"
batch_size = 32

[server]
llama_server = "/path/to/llama.cpp/build/bin/llama-server"
model_path   = "/path/to/models/some-embedding-model.gguf"
```

Julia starts `llama-server` automatically when this backend is selected.

The remaining fields are the same for all backends:

```toml
[store]
path = "data/index.db"

[codebase]
root       = "/path/to/Modelica/library"
extensions = [".mo"]
```

## Playground

The quickest way to see the tool in action is the included playground script. It indexes the Modelica Standard Library and runs a set of example searches, lookups, and fuzzy queries.

```bash
export GITHUB_TOKEN=github_pat_...
julia --project playground.jl

# or pass the library path explicitly:
julia --project playground.jl /usr/share/openmodelica/libraries/Modelica\ 4.0.0
```

The playground writes its own index to `data/playground.db` (separate from the main index). Subsequent runs are incremental — only changed files are re-embedded, so re-runs are fast. The four semantic searches use four API requests from the free tier (150/day).

If the full Modelica Standard Library is not installed locally, the playground falls back to the repo-local parser fixture in `Models/msl.mo`. The corresponding upstream MSL license is included in `Models/LICENSE`.

**No local installation needed — try it in a Codespace:**

Click "Code > Open with Codespaces" on the repository page. The devcontainer builds a custom image that installs Julia into the container, clones the Modelica Standard Library into `data/msl/`, and runs `Pkg.instantiate()` automatically. `GITHUB_TOKEN` is provided by Codespaces, so the playground works with no extra configuration:

```bash
julia --project playground.jl
```

## Usage

```julia
using ModelicaRag

# Build or update the index (incremental by default)
ModelicaRag.main(["index"])

# Force a full rebuild
ModelicaRag.main(["index", "--force"])

# Search from the REPL
ModelicaRag.main(["search", "thermal resistor", "--top-k", "5"])

# Find symbols by partial name (no embedding cost)
ModelicaRag.main(["fuzzy", "HeatTransfer"])
ModelicaRag.main(["fuzzy", "sin", "--top-k", "20"])

# Start the MCP stdio server
ModelicaRag.main(["serve"])
```

A custom config path can be passed with `--config path/to/config.toml`.

## MCP integration (Claude Code)

Add `.mcp.json` to your Claude Code MCP settings, or symlink the included `.mcp.json` into a project:

```json
{
  "mcpServers": {
    "modelica-rag": {
      "command": "julia",
      "args": [
        "--project=/path/to/ModelicaRag.jl",
        "-e",
        "using ModelicaRag; ModelicaRag.main([\"serve\"])"
      ]
    }
  }
}
```

Once connected, four tools are available:

| Tool | Description |
|------|-------------|
| `search_codebase` | Semantic search over indexed Modelica classes |
| `lookup_symbol` | Exact lookup by qualified name (case-insensitive) |
| `fuzzy_lookup` | Substring match on symbol name — finds all classes whose name contains the pattern |
| `rebuild_index` | Incremental or full index rebuild |

## Project structure

```
ModelicaRag.jl/
├── Project.toml
├── config.toml.example  # template — copy to config.toml and fill in paths
├── setup.jl             # auto-detects backend and library, writes config.toml
├── deps/build.jl        # local dev only: Pkg.develop local copies of OM packages
├── data/             # SQLite index (created on first run)
└── src/
    ├── ModelicaRag.jl   # package entry point
    ├── Parser.jl        # Absyn AST walker
    ├── Embedder.jl      # GitHub Models, Ollama, and llama-server backends
    ├── Store.jl         # SQLite storage and cosine similarity search
    ├── MCP.jl           # MCP stdio server
    └── CLI.jl           # index / serve / search / fuzzy commands
```
