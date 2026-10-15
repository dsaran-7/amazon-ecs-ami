#!/usr/bin/env bash
# nvidia-tree-prune (Option C, lean build) — once, in the background, after the first boot's commit.
#
# Frees the driver trees this instance will never use: the other tree (unpacked or still compressed) and the
# chosen tree's other kernel-module flavors. The chosen tree stays: its files share disk blocks with the reflink
# copies in /usr, so removing it would free nothing. An instance changing type isn't supported by ECS ("Container
# instance type changes are not supported."; launch new instances instead), so nothing needs the other tree after
# the first boot. Interrupted part-way, it runs again on the next boot until .pruned exists.
set -Eeuo pipefail
NV=/opt/nvidia
STATE=/var/lib/nvidia-optionb
log() { echo "prune: $*"; }

cur=$(readlink -f "$NV/current")
[ -d "$cur" ] || { log "no committed tree; nothing to prune"; exit 0; }
flavor=$(cat "$NV/current/.driver-flavor" 2>/dev/null || echo open)
before=$(du -sm "$NV" | cut -f1)
for t in "$NV"/lts "$NV"/pb; do
  [ "$t" = "$cur" ] && continue
  rm -rf "$t" "$t.tar.zst" "$NV/.unpacking-$(basename "$t")"
done
for f in "$cur"/flavors/*; do
  f=${f%.tar.zst}; [ "$(basename "$f")" = "$flavor" ] && continue
  rm -rf "$f" "$f.tar.zst" "$cur/flavors/.unpacking-$(basename "$f")"
done
touch "$STATE/.pruned"; sync
log "kept $(basename "$cur")/$flavor; /opt/nvidia ${before} MiB -> $(du -sm "$NV" | cut -f1) MiB"
