# iTex engine → VSCode / texlab / latexmk integration

The `itex` CLI (`cli/`) emits `PDF` + `.synctex.gz` and accepts latexmk-style flags, so the same
engine that backs the native app also backs any editor that drives an external build tool
(docs/04 §4.5). No extension fork required — config only. Tectonic proved this exact path.

## Build the CLI
```sh
cd cli && swift build -c release
# binary: cli/.build/release/itex  — put it on PATH, e.g.
ln -sf "$PWD/.build/release/itex" /usr/local/bin/itex
itex --selfcheck       # sanity
```

## 1. VS Code — LaTeX Workshop
Add to `settings.json` (verified against LaTeX Workshop's `package.json` schema — a tool is
`{name, command, args?, env?, cwd?}`, a recipe references tool *names*):
see `latex-workshop.settings.jsonc`. Then pick the **iTex** recipe. Forward/inverse search work
because the build emits `.synctex.gz` — the single highest-leverage requirement.

## 2. Any latexmk-based editor — drop-in via `.latexmkrc`
`itex` already speaks latexmk-ish flags, but if a tool insists on invoking `latexmk`, point
latexmk's engine at `itex` with `latexmkrc` (copy to your project as `.latexmkrc`).

## 3. texlab (Neovim / Emacs / Sublime / Helix)
texlab runs an external build command on `textDocument/build`. Point it at `itex`:
see `texlab.toml` (or the equivalent LSP `settings.build` block).

## Flags `itex` honors
| flag | effect |
|---|---|
| `--engine xelatex\|pdflatex\|lualatex` / `-pdf` / `-pdfxe` / `-pdflua` | engine select |
| `--draft` | fast preview: skip image decode/embed (docs/03 §3.4) |
| `--downscale-preview` | compile against downscaled image copies (docs/03 §3.6) |
| `-outdir=DIR` / `-outdir DIR` | output directory |
| `-synctex=1`, `-interaction=...`, `-file-line-error`, … | accepted & ignored (recipe-compat) |

The `.tex` file is the only non-`-` argument; every other `-flag` is ignored, so existing
latexmk recipes slot in unchanged.
