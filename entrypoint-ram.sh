#!/bin/bash
set -e

echo "=========================================================="
echo "    Strata gfx1030 Auto-RAM Booster Entrypoint v4 (v0.2.9)"
echo "=========================================================="

RAM_DIR="/dev/shm/gguf"
mkdir -p "$RAM_DIR"

# 1. Clean up legacy or broken files in /dev/shm root if they exist
for old_f in /dev/shm/*-00002-of-*.gguf; do
  if [ -f "$old_f" ]; then
    fname=$(basename "$old_f")
    target="$RAM_DIR/$fname"
    if [ ! -f "$target" ]; then
      echo "[Auto-RAM] Migrating existing cache from $old_f to $target (0 sec)..."
      mv "$old_f" "$target"
    else
      echo "[Auto-RAM] Removing stale legacy file $old_f..."
      rm -f "$old_f"
    fi
  fi
done

SHM_AVAIL_KB=$(df -k /dev/shm | tail -1 | awk '{print $4}')
echo "[Auto-RAM] /dev/shm available space: $((SHM_AVAIL_KB / 1024 / 1024)) GB"

# 2. Process all GGUF split files from /gguf or /data/gguf
for src_dir in /gguf /data/gguf; do
  [ -d "$src_dir" ] || continue
  for f in "$src_dir"/*-of-*.gguf; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    target="$RAM_DIR/$fname"

    if echo "$fname" | grep -q -- "-00002-of-"; then
      # Shard 2 (PLE Table): Copy to RAM disk
      SRC_SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
      if [ -f "$target" ] && [ ! -L "$target" ]; then
        RAM_SIZE=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target" 2>/dev/null || echo 0)
        if [ "$SRC_SIZE" -eq "$RAM_SIZE" ] && [ "$SRC_SIZE" -gt 0 ]; then
          echo "[Auto-RAM] PLE Shard ($fname) already cached in RAM."
          continue
        else
          echo "[Auto-RAM] Corrupted or partial cache detected. Cleaning up..."
          rm -f "$target"
        fi
      fi
      echo "[Auto-RAM] Caching PLE Shard ($fname, $((SRC_SIZE / 1024 / 1024)) MB) to RAM..."
      echo "[Auto-RAM] Copying from storage (takes ~1-2 mins)..."
      cp "$f" "$target"
      echo "[Auto-RAM] PLE Shard caching complete!"
    else
      # Shard 1 & others: Symlink to save RAM (0 bytes consumed)
      if [ ! -e "$target" ]; then
        echo "[Auto-RAM] Symlinking $fname -> $target (0 MB RAM used)"
        ln -sf "$f" "$target"
      fi
    fi
  done
done

# 3. Ensure draft_vocab.bin exists in /data/mtp/rt so STRATA_MTP_STAGE0=1 can place the drafter on Stage 0 GPU
if [ -d "/data/mtp/rt" ] && [ -f "/opt/strata/data/draft_vocab.bin" ] && [ ! -f "/data/mtp/rt/draft_vocab.bin" ]; then
  echo "[Auto-RAM] Copying draft_vocab.bin to /data/mtp/rt/ for Stage 0 MTP acceleration..."
  cp -f "/opt/strata/data/draft_vocab.bin" "/data/mtp/rt/draft_vocab.bin"
fi

# 4. Safely update config files (paths, sampling, and v0.2.9 gfx1030 optimizations)
/opt/strata/.venv/bin/python - <<'PYEOF'
import glob, json, os, pathlib

default_env = {
    "STRATA_ROCBLAS_TUNING": "/opt/strata/tools/hip",
    "STRATA_HIP_PROMPT_F16": "1",
    "STRATA_SH_STREAM": "1",
    "STRATA_DENSE_MMQ": "1",
    "STRATA_SELECT_SIMT": "1",
    "STRATA_PLE_COMPACT": "1",
    "STRATA_HC_PERSIST": "1",
    "STRATA_MTP_STAGE0": "1",
    "STRATA_EXPDEC": "1",
    "STRATA_QSA_ROWS": "1",
    "STRATA_SPEC_PROB": "1",
    "STRATA_SPEC_PROB_GATE": "top",
}

default_sampling = {
    "temperature": 0.8,
    "top_p": 0.95,
    "top_k": 20,
    "presence_penalty": 0.6,
}

for pattern in ("/data/config/strata-*.json", "/opt/strata/strata-*.json"):
    for path_str in glob.glob(pattern):
        p = pathlib.Path(path_str)
        if not p.is_file() or p.is_symlink():
            continue
        try:
            cfg = json.loads(p.read_text(encoding="utf-8-sig"))
        except Exception as e:
            print(f"[Auto-RAM] Warning: skipping invalid JSON {p}: {e}")
            continue
        changed = False
        args = cfg.get("args", [])
        for i, arg in enumerate(args):
            if isinstance(arg, str) and arg.endswith(".gguf"):
                for prefix in ("/gguf/", "/data/gguf/", "/dev/shm/"):
                    if arg.startswith(prefix) and not arg.startswith("/dev/shm/gguf/"):
                        args[i] = "/dev/shm/gguf/" + os.path.basename(arg)
                        changed = True
        if "sampling" not in cfg:
            cfg["sampling"] = default_sampling
            changed = True
        env = cfg.setdefault("env", {})
        for k, v in default_env.items():
            if k not in env:
                env[k] = v
                changed = True
        if changed:
            p.write_text(json.dumps(cfg, indent=1), encoding="utf-8")
            print(f"[Auto-RAM] Updated {p} with RAM paths, sampling defaults, and v0.2.9 gfx1030 switches.")
PYEOF

echo "=========================================================="
echo "Launching Strata Engine v0.2.9 with Unified RAM Shard Directory..."
echo "=========================================================="

exec ./docker-entrypoint.sh "$@"
