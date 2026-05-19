#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${TMPDIR:-/tmp}/hb-rb-whisper-smoke"

mkdir -p "$out_dir"

pa=()
for dir in "$repo_root"/_build/default/lib/*/ebin; do
  pa+=("-pa" "$dir")
done

erlc "${pa[@]}" -o "$out_dir" "$repo_root/scripts/rb_whisper_smoke.erl"
erl -noshell -pa "$out_dir" "${pa[@]}" -s rb_whisper_smoke main
