#!/usr/bin/env bash
set -euo pipefail

# --- Utilities (Helper Functions) ---
log() { echo "[*] $*" >&2; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

extract_and_clean() {
  local zip_in="$1"
  local img_out="$2"
  local base_work="$3"

  local temp_dir
  temp_dir=$(mktemp -d "${base_work}/tmp_extract.XXXXXX")

  log "Processing: $zip_in -> $img_out"

  # Extract payload.bin to temp dir, then delete the OTA zip immediately to reduce peak disk usage
  if ! unzip -o "$zip_in" payload.bin -d "$temp_dir" >/dev/null; then
    rm -rf "$temp_dir"
    die "Failed to extract payload.bin from $zip_in"
  fi
  rm -f "$zip_in"

  # Dump only the odm partition from payload.bin, then delete payload.bin immediately
  if ! payload-dumper-go -p odm -o "$temp_dir" "$temp_dir/payload.bin" >/dev/null; then
    rm -rf "$temp_dir"
    die "Failed to dump odm partition from payload.bin"
  fi
  rm -f "$temp_dir/payload.bin"

  # Find the extracted image within the isolated temp dir
  local extracted
  extracted=$(find "$temp_dir" -maxdepth 1 -name "odm*.img" | head -n 1)

  if [[ -f "$extracted" ]]; then
    mv "$extracted" "$base_work/$img_out"
    log "Created: $base_work/$img_out"
  else
    rm -rf "$temp_dir"
    die "Failed to locate extracted odm.img"
  fi

  rm -rf "$temp_dir"
}

mount_odm() {
  local raw_img_in="$1"
  local mount_point="$2"

  local erofsfuse_bin
  erofsfuse_bin="$(command -v erofsfuse)" || die "erofsfuse not found"

  log "Mounting $raw_img_in to $mount_point"
  mkdir -p "$mount_point"

  if ! "$erofsfuse_bin" "$raw_img_in" "$mount_point"; then
    warn "erofsfuse mount failed for $(basename "$raw_img_in")"
    umount "$mount_point" 2>/dev/null || fusermount -u "$mount_point" 2>/dev/null || true
    rmdir "$mount_point" 2>/dev/null || true
    return 1
  fi

  # Wait briefly for FUSE mount to stabilize
  sleep 0.5
}

unmount_odm() {
  local mount_point="$1"
  if mountpoint -q "$mount_point" 2>/dev/null; then
    log "Unmounting $mount_point"
    umount "$mount_point" || fusermount -u "$mount_point" || warn "Failed to unmount $mount_point"
  fi
}
