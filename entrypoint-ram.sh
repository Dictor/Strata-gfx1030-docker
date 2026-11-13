#!/bin/bash
set -e

echo "=========================================================="
echo "    Strata gfx1030 Auto-RAM Booster Entrypoint v5 (v0.2.13)"
echo "=========================================================="

RAM_DIR="/dev/shm/gguf"
mkdir -p "$RAM_DIR"

PYBIN="/opt/strata/.venv/bin/python"
[ -x "$PYBIN" ] || PYBIN="$(command -v python3 || echo python3)"

SHM_AVAIL_KB=$(df -k /dev/shm | tail -1 | awk '{print $4}')
echo "[Auto-RAM] /dev/shm available space: $((SHM_AVAIL_KB / 1024 / 1024)) GB"

# 1 & 2. Resolve active model config, evict stale /dev/shm GGUF files, and cache/symlink active shards
"$PYBIN" - <<'PYEOF'
import glob, json, os, pathlib, re, shutil

ram_dir = pathlib.Path("/dev/shm/gguf")
ram_dir.mkdir(parents=True, exist_ok=True)
shm_root = pathlib.Path("/dev/shm")
strata_data = pathlib.Path(os.environ.get("STRATA_DATA") or "/data")
src_dirs = [pathlib.Path("/gguf"), pathlib.Path("/data/gguf")]
split_re = re.compile(r"^(.+)-(\d+)-of-(\d+)\.gguf$")


def find_active_config():
    cfg_env = (os.environ.get("CONFIG") or "").strip()
    if cfg_env:
        p = pathlib.Path(cfg_env)
        return p if p.is_file() else None

    model_env = (os.environ.get("MODEL") or "").strip()
    family = (os.environ.get("FAMILY") or "qwen").strip()
    prefix = "" if family == "qwen" else f"{family}-"
    cfg_dir = strata_data / "config"

    if model_env:
        tag = f"{prefix}{model_env.lower()}"
        p = cfg_dir / f"strata-{tag}.json"
        return p if p.is_file() else None

    default_p = cfg_dir / f"strata-{prefix}iq2_xs.json"
    if default_p.is_file():
        return default_p

    candidates = [
        pathlib.Path(s)
        for s in sorted(glob.glob(str(cfg_dir / "strata-*.json")))
        if not s.endswith(".shared-settings.json")
        and pathlib.Path(s).is_file()
        and not pathlib.Path(s).is_symlink()
    ]
    if len(candidates) == 1:
        return candidates[0]
    return None


def safe_unlink(path: pathlib.Path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


active_cfg = find_active_config()
active_basenames = set()
ple_basenames = set()

if active_cfg is not None:
    try:
        cfg_data = json.loads(active_cfg.read_text(encoding="utf-8-sig"))
        args = cfg_data.get("args", [])
        if isinstance(args, list):
            for idx, arg in enumerate(args):
                if isinstance(arg, str) and arg.endswith(".gguf"):
                    b = os.path.basename(arg)
                    active_basenames.add(b)
                    if idx > 0 and args[idx - 1] == "--ple-gguf":
                        ple_basenames.add(b)
                    m = split_re.match(b)
                    if m:
                        stem, total = m.group(1), m.group(3)
                        for sd in src_dirs:
                            if sd.is_dir():
                                for sib in sd.glob(f"{stem}-*-of-{total}.gguf"):
                                    if sib.is_file():
                                        active_basenames.add(sib.name)
    except Exception as e:
        print(f"[Auto-RAM] Warning: failed to parse active config {active_cfg}: {e}")

available_all = {}
available_splits = {}
for sd in src_dirs:
    if not sd.is_dir():
        continue
    for f in sorted(sd.iterdir()):
        if not f.is_file() or not f.name.endswith(".gguf"):
            continue
        available_all.setdefault(f.name, f)
        if "-of-" in f.name:
            available_splits.setdefault(f.name, f)

matched_active = {b: available_all[b] for b in active_basenames if b in available_all}
targets = {}

if matched_active:
    print(f"[Auto-RAM] Active config: {active_cfg} ({len(matched_active)} GGUF file(s) matched)")

    # Remove stale legacy files in /dev/shm root not needed by active config; migrate active ones
    for old_f in sorted(shm_root.glob("*-00002-of-*.gguf")):
        if not old_f.is_file() and not old_f.is_symlink():
            continue
        target = ram_dir / old_f.name
        if old_f.name not in matched_active:
            print(f"[Auto-RAM] Removing inactive legacy cache {old_f} to free RAM...")
            safe_unlink(old_f)
        elif not target.exists():
            print(f"[Auto-RAM] Migrating existing cache from {old_f} to {target} (0 sec)...")
            shutil.move(str(old_f), str(target))
        else:
            print(f"[Auto-RAM] Removing stale legacy file {old_f}...")
            safe_unlink(old_f)

    # Remove any OTHER *.gguf files in /dev/shm/gguf/ NOT referenced by active config
    for existing in sorted(ram_dir.glob("*.gguf")):
        if existing.name not in matched_active:
            print(f"[Auto-RAM] Removing inactive RAM shard/link {existing} to free RAM...")
            safe_unlink(existing)

    targets = matched_active
elif active_cfg is not None and active_basenames:
    print(f"[Auto-RAM] Active config {active_cfg} uses GGUF files outside /gguf and /data/gguf; clearing stale /dev/shm GGUF cache.")
    for old_f in sorted(shm_root.glob("*-00002-of-*.gguf")):
        if old_f.is_file() or old_f.is_symlink():
            safe_unlink(old_f)
    for existing in sorted(ram_dir.glob("*.gguf")):
        safe_unlink(existing)
else:
    print("[Auto-RAM] No active config with .gguf args yet (fresh setup); scanning /gguf and /data/gguf.")

    for old_f in sorted(shm_root.glob("*-00002-of-*.gguf")):
        if not old_f.is_file() and not old_f.is_symlink():
            continue
        target = ram_dir / old_f.name
        if not target.exists():
            print(f"[Auto-RAM] Migrating existing cache from {old_f} to {target} (0 sec)...")
            shutil.move(str(old_f), str(target))
        else:
            print(f"[Auto-RAM] Removing stale legacy file {old_f}...")
            safe_unlink(old_f)

    targets = available_splits

for fname, src_path in sorted(targets.items()):
    target = ram_dir / fname
    is_ram_shard = ("-00002-of-" in fname) or (fname in ple_basenames)

    if is_ram_shard:
        src_size = src_path.stat().st_size
        if target.exists() and not target.is_symlink() and target.is_file():
            ram_size = target.stat().st_size
            if src_size == ram_size and src_size > 0:
                print(f"[Auto-RAM] PLE Shard ({fname}) already cached in RAM.")
                continue
            print(f"[Auto-RAM] Corrupted or partial cache detected for {fname}. Cleaning up...")
            safe_unlink(target)
        elif target.is_symlink():
            safe_unlink(target)
        print(f"[Auto-RAM] Caching PLE Shard ({fname}, {src_size // (1024 * 1024)} MB) to RAM...")
        print("[Auto-RAM] Copying from storage (takes ~1-2 mins)...")
        shutil.copy2(str(src_path), str(target))
        print("[Auto-RAM] PLE Shard caching complete!")
    else:
        if target.is_symlink():
            try:
                if os.readlink(target) == str(src_path):
                    continue
            except OSError:
                pass
            safe_unlink(target)
        elif target.exists():
            safe_unlink(target)
        print(f"[Auto-RAM] Symlinking {fname} -> {target} (0 MB RAM used)")
        target.symlink_to(src_path)
PYEOF

# 3. Ensure draft_vocab.bin exists in /data/mtp/rt so STRATA_MTP_STAGE0=1 can place the drafter on Stage 0 GPU
if [ -d "/data/mtp/rt" ] && [ -f "/opt/strata/data/draft_vocab.bin" ] && [ ! -f "/data/mtp/rt/draft_vocab.bin" ]; then
  echo "[Auto-RAM] Copying draft_vocab.bin to /data/mtp/rt/ for Stage 0 MTP acceleration..."
  cp -f "/opt/strata/data/draft_vocab.bin" "/data/mtp/rt/draft_vocab.bin"
fi

# 4. Safely update config files (paths, sampling, and v0.2.13 gfx1030 optimizations)
"$PYBIN" - <<'PYEOF'
import glob, json, os, pathlib

strata_data = os.environ.get("STRATA_DATA") or "/data"

default_env = {
    "STRATA_ROCBLAS_TUNING": "/opt/strata/tools/hip",
    "STRATA_HIP_PROMPT_F16": "1",
    "STRATA_SH_STREAM": "1",
    "STRATA_DENSE_MMQ": "1",
    "STRATA_SELECT_SIMT": "1",
    "STRATA_PLE_COMPACT": "1",
    "STRATA_HC_PERSIST": "0",
    "STRATA_MTP_STAGE0": "0",
    "STRATA_SPLIT_OVERLAP": "1",
    "STRATA_EXPDEC": "1",
    "STRATA_QSA_ROWS": "1",
    "STRATA_SPEC_PROB": "1",
    "STRATA_SPEC_PROB_GATE": "top",
    "STRATA_PREFILL_WARM": "0",
    "STRATA_ARENA_PIN_GIB": "8",
    "STRATA_NO_ARENA_THP": "1",
    "STRATA_ARENA_LOCK": "0",
}

default_sampling = {
    "temperature": 0.8,
    "top_p": 0.95,
    "top_k": 20,
    "presence_penalty": 0.6,
}

for pattern in (f"{strata_data}/config/strata-*.json", "/opt/strata/strata-*.json"):
    for path_str in glob.glob(pattern):
        p = pathlib.Path(path_str)
        if not p.is_file() or p.is_symlink() or p.name.endswith(".shared-settings.json"):
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
            print(f"[Auto-RAM] Updated {p} with RAM paths, sampling defaults, and v0.2.13 gfx1030 switches.")
PYEOF

echo "=========================================================="
echo "Launching Strata Engine v0.2.13 (0.1.59.1) with Unified RAM Shard Directory..."
echo "=========================================================="

exec ./docker-entrypoint.sh "$@"
