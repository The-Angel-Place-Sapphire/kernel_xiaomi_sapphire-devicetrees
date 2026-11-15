#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the Redmi Note 13 4G (sapphire / sapphiren, SM6225 "khaje") device
# trees: the base DTBs that go into vendor_boot and the dtbo.img overlays.
#
# This mirrors what Qualcomm's kernel platform build does:
#   1. compile the kernel tree (qcom/) and the "techpack" trees
#      (video/ camera/ wlan/ audio/ graphics/ display/ bt/) with cpp +
#      dtc -@ (same flags as kernel scripts/Makefile.lib),
#   2. merge them like kernel_platform/build/android/merge_dtbs.py does:
#        base DTB   = fdtoverlay(kernel base DTB, techpack base overlays...)
#        board DTBO = fdtoverlaymerge(kernel board overlay, techpack overlays...)
#      The merge plan is spelled out below instead of being derived from the
#      msm-id/board-id intersections, and reproduces the stock layout:
#      khaje.dtb is emitted once per msm-id (518, 586) like merge_dtbs.py,
#      and techpacks are applied in the stock order.
#   3. dtb.img  = concatenation of the base DTBs (vendor_boot "dtb" section)
#      dtbo.img = mkdtboimg.py create, page size 4096, id/rev/custom = 0
#      (same as stock).
#
# Entries for the Qualcomm reference boards (ATP/IDP/QRD/... of the other
# khaje SKUs) are built from reference/*.dts, so that dtb.img/dtbo.img keep
# the same 6 + 47 entries as stock.
#
# Usage: ./build.sh [OUT=dir] ; env overrides: KERNEL_DIR, CAMERA_KERNEL_DIR,
#        DTC, UFDT_APPLY_OVERLAY, FDTOVERLAYMERGE, FDTPUT, MKDTBOIMG
#
# Tools: gcc (cpp), python3, dtc/fdtoverlay/fdtoverlaymerge/fdtput from the
# Qualcomm dtc fork (CLO kernel_platform/external/dtc, branch
# kernel.build.lnx.1.0.r10-rel; fdtoverlaymerge is not in upstream dtc),
# mkdtboimg.py (AOSP system/libufdt/utils/src).
set -euo pipefail

TOP=$(cd "$(dirname "$0")" && pwd)
KERNEL_DIR=${KERNEL_DIR:-$TOP/../kernel_platform/msm-kernel}
CAMERA_KERNEL_DIR=${CAMERA_KERNEL_DIR:-$TOP/../vendor/qcom/opensource/camera-kernel}
QDTC=${QDTC:-}   # dir with the CLO dtc fork tools (dtc, fdtoverlay, fdtoverlaymerge, fdtput)
tool() { if [ -n "$QDTC" ] && [ -x "$QDTC/$1" ]; then echo "$QDTC/$1"; else command -v "$1" || echo "$1"; fi; }
DTC=${DTC:-$(tool dtc)}
# Base DTBs are merged with AOSP libufdt's ufdt_apply_overlay, like the stock
# build: dtc's fdtoverlay inserts the subnodes an overlay adds in REVERSE order,
# and drivers that walk children in order (cam_cpas camera-bus-nodes, kgsl
# pwrlevels, ...) then fail. Build it from platform/system/libufdt:
#   gcc -O2 -o ufdt_apply_overlay -Iinclude -Isysdeps/include -I<dtc>/libfdt #     tests/src/ufdt_overlay_test_app.c tests/src/util.c ufdt_*.c #     sysdeps/libufdt_sysdeps_posix.c <dtc>/libfdt/fdt*.c
FDTOVERLAY=${FDTOVERLAY:-$(tool fdtoverlay)}
FDTGET=${FDTGET:-$(tool fdtget)}
UFDT_APPLY_OVERLAY=${UFDT_APPLY_OVERLAY:-$(command -v ufdt_apply_overlay || echo ufdt_apply_overlay)}
FDTOVERLAYMERGE=${FDTOVERLAYMERGE:-$(tool fdtoverlaymerge)}
FDTPUT=${FDTPUT:-$(tool fdtput)}
MKDTBOIMG=${MKDTBOIMG:-$(command -v mkdtboimg.py || echo mkdtboimg.py)}
OUT=${OUT:-$TOP/out}

DTC_INCLUDE="$KERNEL_DIR/scripts/dtc/include-prefixes"
DTC_FLAGS="-Wno-interrupt_provider -Wno-unit_address_vs_reg \
 -Wno-unit_address_format -Wno-avoid_unnecessary_addr_size -Wno-alias_paths \
 -Wno-graph_child_address -Wno-simple_bus_reg -Wno-unique_unit_address -@"

O=$OUT/obj
M=$OUT/merged
rm -rf "$O" "$M"
mkdir -p "$O" "$M"

# compile <source.dts> : cpp + dtc like the kernel's cmd_dtc; -> $O/<path>.dtb[o]
compile() {
	local src=$TOP/$1 ext out dir
	# overlays (/plugin/) -> .dtbo, except reference/*-dtb.dts which the
	# stock build shipped as a .dtb in vendor_boot (khajep-qrd-overlay)
	if grep -q '^/plugin/;' "$src" && [[ "$1" != *-dtb.dts ]]; then ext=dtbo; else ext=dtb; fi
	out=$O/${1%.dts}.$ext
	dir=$(dirname "$src")
	mkdir -p "$(dirname "$out")"
	gcc -E -nostdinc -I"$DTC_INCLUDE" -I"$dir" -I"$TOP/qcom" \
		-I"$CAMERA_KERNEL_DIR" -undef -D__DTS__ -x assembler-with-cpp \
		-o "$out.pre" "$src"
	# shellcheck disable=SC2086
	"$DTC" -q -O dtb -o "$out" -b 0 -i "$dir" -i "$DTC_INCLUDE" $DTC_FLAGS "$out.pre"
	rm -f "$out.pre"
}

# ------------------------------------------------------------------ compile
SOURCES="qcom/khaje.dts
qcom/khajeg.dts
qcom/khajep.dts
qcom/khajeq.dts
qcom/sapphire-overlay.dts
qcom/sapphiren-overlay.dts
video/khaje-vidc.dts
camera/khaje-camera.dts
wlan/khaje-wlan.dts
audio/khaje-audio.dts
graphics/khaje-gpu.dts
display/khaje-sde.dts
bt/khaje-bt.dts
camera/sapphire-camera-sensor.dts
audio/sapphire-audio-overlay.dts
display/sapphire-sde-display-overlay.dts"
for s in $SOURCES; do compile "$s"; done
if [ -d "$TOP/reference" ]; then
	for s in "$TOP"/reference/*.dts "$TOP"/reference/parts/*.dts; do
		compile "${s#"$TOP"/}"
	done
fi

# ------------------------------------------------------------------ merge
# Base DTBs: the techpack base overlays that match each SoC variant, in the
# order the stock build applied them (recovered from the stock phandle order).
TP_VIDC=$O/video/khaje-vidc.dtbo
TP_CAM=$O/camera/khaje-camera.dtbo
TP_WLAN=$O/wlan/khaje-wlan.dtbo
TP_AUD=$O/audio/khaje-audio.dtbo
TP_GPU=$O/graphics/khaje-gpu.dtbo
TP_SDE=$O/display/khaje-sde.dtbo
TP_BT=$O/bt/khaje-bt.dtbo
# apply_overlays <base.dtb> <out.dtb> <overlay.dtbo>... (in order)
# The tree comes from ufdt_apply_overlay (stock child-node order), but ufdt
# does not carry the overlays' labels into /__symbols__, and the bootloader
# needs them to apply dtbo.img on top: without them ABL stays in fastboot.
# __symbols__ holds node paths (order independent), so the entries the
# overlays add are taken from an fdtoverlay merge of the same inputs.
apply_overlays() {
	local base=$1 out=$2; shift 2
	cp "$base" "$out"
	for ov in "$@"; do
		"$UFDT_APPLY_OVERLAY" "$out" "$ov" "$out.tmp" >/dev/null
		mv "$out.tmp" "$out"
	done
	"$FDTOVERLAY" -i "$base" -o "$out.sym" "$@"
	local have label
	have=$("$FDTGET" -p "$out" /__symbols__)
	for label in $("$FDTGET" -p "$out.sym" /__symbols__); do
		grep -qxF "$label" <<<"$have" ||
			"$FDTPUT" -t s "$out" /__symbols__ "$label" "$("$FDTGET" -t s "$out.sym" /__symbols__ "$label")"
	done
	rm -f "$out.sym"
}
apply_overlays "$O/qcom/khaje.dtb"  "$M/khaje.dtb"  "$TP_VIDC" "$TP_CAM" "$TP_WLAN" "$TP_AUD" "$TP_GPU" "$TP_SDE" "$TP_BT"
apply_overlays "$O/qcom/khajeg.dtb" "$M/khajeg.dtb" "$TP_VIDC" "$TP_WLAN" "$TP_AUD" "$TP_GPU" "$TP_SDE" "$TP_BT"
apply_overlays "$O/qcom/khajep.dtb" "$M/khajep.dtb" "$TP_VIDC" "$TP_GPU"
apply_overlays "$O/qcom/khajeq.dtb" "$M/khajeq.dtb" "$TP_GPU"
# merge_dtbs.py emits khaje (msm-id 518 + 586) once per msm-id
for id in 518 586; do
	cp "$M/khaje.dtb" "$M/khaje-$id.dtb"
	"$FDTPUT" -t i "$M/khaje-$id.dtb" / qcom,msm-id "$id" 65536
done
cp "$O/reference/khajep-qrd-overlay-dtb.dtb" "$M/khajep-qrd-overlay.dtb" 2>/dev/null || true

# sapphire/sapphiren: kernel overlay + camera, audio, display(+touch) techpacks
SAPPHIRE_TECHPACKS="$O/camera/sapphire-camera-sensor.dtbo \
 $O/audio/sapphire-audio-overlay.dtbo $O/display/sapphire-sde-display-overlay.dtbo"
for b in sapphire sapphiren; do
	# shellcheck disable=SC2086
	"$FDTOVERLAYMERGE" -i "$O/qcom/$b-overlay.dtbo" -o "$M/$b.dtbo" \
		$SAPPHIRE_TECHPACKS >/dev/null 2>&1
done

# ------------------------------------------------------------------ images
# Entry order/composition of the stock images: reference/ENTRIES
DTB_LIST=""
DTBO_LIST=""
while read -r kind name tps; do
	case "$kind" in
	dtb)  DTB_LIST="$DTB_LIST $M/$name.dtb" ;;
	dtbo)
		if [ ! -f "$M/$name.dtbo" ]; then
			if [ -n "$tps" ]; then
				ovs=""
				for t in $tps; do ovs="$ovs $O/reference/$t.dtbo"; done
				# shellcheck disable=SC2086
				"$FDTOVERLAYMERGE" -i "$O/reference/$name.dtbo" -o "$M/$name.dtbo" \
					$ovs >/dev/null 2>&1
			else
				cp "$O/reference/$name.dtbo" "$M/$name.dtbo"
			fi
		fi
		DTBO_LIST="$DTBO_LIST $M/$name.dtbo" ;;
	esac
done < <(grep -v '^#' "$TOP/reference/ENTRIES")
# shellcheck disable=SC2086
cat $DTB_LIST > "$OUT/dtb.img"
# shellcheck disable=SC2086
python3 "$MKDTBOIMG" create "$OUT/dtbo.img" --page_size=4096 $DTBO_LIST
echo "build.sh: $OUT/dtb.img ($(echo $DTB_LIST | wc -w) DTBs), $OUT/dtbo.img ($(echo $DTBO_LIST | wc -w) entries)"
