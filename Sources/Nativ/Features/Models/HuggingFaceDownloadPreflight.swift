import Foundation

/// Shared with the subprocess tests so capacity checks run before any transfer.
enum HuggingFaceDownloadPreflight {
    static let script = """
    import json
    print("__NATIV_STAGE__:preparing", flush=True)
    revision = sys.argv[4]
    files = snapshot_download(
        repo_id=sys.argv[1],
        revision=revision,
        cache_dir=sys.argv[2],
        dry_run=True,
        ignore_patterns=ignored_patterns,
    )
    if not files or any(item.file_size is None or item.file_size < 0 for item in files):
        raise RuntimeError("Could not verify the model's download size. Try again.")
    revisions = {item.commit_hash for item in files}
    if len(revisions) != 1 or not next(iter(revisions)):
        raise RuntimeError("Could not verify the model revision. Try again.")
    revision = next(iter(revisions))
    # Most language and audio models have no diffusion components.
    paths = {item.filename: item for item in files}
    if (sys.argv[6:7] == ["image"] or "model_index.json" in paths or "ae.safetensors" in paths
            or any(path.startswith(("transformer/", "transformer-packed-mflux/")) for path in paths)):
        from huggingface_hub import hf_hub_download
        from pathlib import Path
        from tempfile import TemporaryDirectory

        # Use only paths the resolver examines, and bound metadata transfers.
        relevant = sorted(path for path in paths if path.count("/") <= 1
                          and path.endswith((".json", ".safetensors")))
        metadata = {}
        complete = True
        budget = 512 * 1024
        with TemporaryDirectory() as preview:
            for path in relevant:
                basename = path.rsplit("/", 1)[-1]
                if basename not in ("config.json", "model_index.json", "manifest.json",
                                    "adapter_config.json", "mlx_mage_flow.json",
                                    "model.safetensors.index.json", "diffusion_pytorch_model.safetensors.index.json"):
                    continue
                item = paths[path]
                if item.file_size > min(256 * 1024, budget) or path.startswith(("/", ".")) or ".." in path.split("/"):
                    complete = False
                    continue
                budget -= item.file_size
                local = Path(item.local_path) if item.is_cached else None
                if local is None or not local.is_file():
                    local = Path(hf_hub_download(repo_id=sys.argv[1], filename=path, revision=revision,
                                                 cache_dir=sys.argv[2], local_dir=preview))
                with local.open("rb") as metadata_file:
                    raw = metadata_file.read(item.file_size + 1)
                if len(raw) > item.file_size:
                    complete = False
                    continue
                try:
                    value = json.loads(raw)
                except (UnicodeError, ValueError):
                    complete = False
                    continue
                if isinstance(value, dict):
                    metadata[path] = json.dumps(value, separators=(",", ":"))
                else:
                    complete = False
        print("__NATIV_IMAGE_MANIFEST__:" + json.dumps(dict(
            model=sys.argv[1], paths=relevant, metadata=metadata, metadataComplete=complete
        )), flush=True)

    total_bytes = sum(item.file_size for item in files)
    cached_bytes = sum(item.file_size for item in files if not item.will_download)
    remaining_bytes = total_bytes - cached_bytes
    os.makedirs(sys.argv[2], exist_ok=True)
    print(f"__NATIV_RESERVE__:{remaining_bytes}", flush=True)
    approval_line = sys.stdin.readline()
    if not approval_line:
        raise RuntimeError("Download stopped before disk space was reserved.")
    approval = json.loads(approval_line)
    if approval.get("approved") is not True:
        raise RuntimeError(approval.get("error", "Disk space reservation was denied."))
    print(f"__NATIV_PROGRESS__:{cached_bytes}:{total_bytes}", flush=True)
    """
}
