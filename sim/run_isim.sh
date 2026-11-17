#!/bin/bash
# Run the self-checking ISim testbenches of this core.
#
#   sim/run_isim.sh sio            atari_sio_disk (1050 responder)
#   sim/run_isim.sh atr            atari_atr_loader (ATR -> SRAM)
#   sim/run_isim.sh xex            ATR loader + DMA XEX parser (system TB)
#   sim/run_isim.sh video          one 720x576 frame (frame.ppm)
#   sim/run_isim.sh video_compare  two windows A/B (frame_a/b.ppm)
#
# Sources are staged into /tmp/opencode/isim_<name> (ASCII paths; ISim 14.7
# dislikes non-ASCII absolute paths in a .prj).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS=/opt/Xilinx/14.7/ISE_DS/settings64.sh
FUSE=/tmp/opencode/fuse_patched
CMD="${1:-}"

bash "$ROOT/sim/fix_isim_gcc.sh" >/dev/null

run_one() {
	local dir="$1" top="$2"
	cat > "$dir/run.tcl" <<'EOF'
run all
quit
EOF
	echo "== fuse $top"
	if ! bash -c "source '$SETTINGS' >/dev/null 2>&1; cd '$dir'; '$FUSE' -intstyle ise -mt off -prj tb.prj work.$top -o $top" > "$dir/fuse.log" 2>&1; then
		echo "fuse failed:"
		tail -30 "$dir/fuse.log"
		exit 1
	fi
	echo "== run $top"
	bash -c "source '$SETTINGS' >/dev/null 2>&1; cd '$dir'; ./$top -tclbatch run.tcl" | tee "$dir/sim.log"
	grep -q '0 errors' "$dir/sim.log"
}

run_one_plain() {
	local dir="$1" top="$2"
	cat > "$dir/run.tcl" <<'EOF'
run all
quit
EOF
	echo "== fuse $top"
	if ! bash -c "source '$SETTINGS' >/dev/null 2>&1; cd '$dir'; '$FUSE' -intstyle ise -mt off -prj tb.prj work.$top -o $top" > "$dir/fuse.log" 2>&1; then
		echo "fuse failed:"
		tail -30 "$dir/fuse.log"
		exit 1
	fi
	echo "== run $top"
	bash -c "source '$SETTINGS' >/dev/null 2>&1; cd '$dir'; ./$top -tclbatch run.tcl" | tee "$dir/sim.log"
}

case "$CMD" in
	sio)
		D=/tmp/opencode/isim_sio
		rm -rf "$D"; mkdir -p "$D"
		cp "$ROOT/src/rtl/atari_sio_disk.v" "$D/dut_sim.v"
		cp "$ROOT/sim/tb_sio.v" "$D/"
		cat > "$D/tb.prj" <<'EOF'
verilog work "dut_sim.v"
verilog work "tb_sio.v"
EOF
		run_one "$D" tb_sio
		;;
	atr)
		D=/tmp/opencode/isim_atr
		rm -rf "$D"; mkdir -p "$D"
		cp "$ROOT/src/rtl/atari_atr_loader.v" "$D/"
		cp "$ROOT/modules/rtl/mem/kg_async_fifo.v" "$D/"
		cp "$ROOT/sim/tb_atr_loader.v" "$D/"
		cat > "$D/tb.prj" <<'EOF'
verilog work "atari_atr_loader.v"
verilog work "kg_async_fifo.v"
verilog work "tb_atr_loader.v"
EOF
		run_one "$D" tb_atr_loader
		;;
	xex)
		D=/tmp/opencode/isim_xex
		rm -rf "$D"; mkdir -p "$D"
		cp "$ROOT/src/rtl/atari_atr_loader.v" "$ROOT/src/rtl/xex_dma_loader.v" \
		   "$ROOT/src/rtl/xex_boot_stub.v" "$ROOT/src/rtl/xex_prefix_rom.v" \
		   "$ROOT/modules/rtl/mem/kg_async_fifo.v" "$ROOT/sim/tb_xex_system.v" \
		   "$ROOT/sim/pong.hex" "$D/"
		cat > "$D/tb.prj" <<'EOF'
verilog work "atari_atr_loader.v"
verilog work "xex_dma_loader.v"
verilog work "xex_boot_stub.v"
verilog work "xex_prefix_rom.v"
verilog work "kg_async_fifo.v"
verilog work "tb_xex_system.v"
EOF
		run_one "$D" tb_xex_system
		;;
	video)
		D=/tmp/opencode/isim_video
		rm -rf "$D"; mkdir -p "$D"
		cp "$ROOT/src/rtl/atari_video.v" "$ROOT/sim/tb_video_frame.v" "$D/"
		cat > "$D/tb.prj" <<'EOF'
verilog work "atari_video.v"
verilog work "tb_video_frame.v"
EOF
		run_one_plain "$D" tb_video_frame
		echo "frame: $D/frame.ppm"
		;;
	video_compare)
		D=/tmp/opencode/isim_video_compare
		rm -rf "$D"; mkdir -p "$D"
		cp "$ROOT/src/rtl/atari_video.v" "$ROOT/sim/tb_video_compare.v" "$D/"
		cat > "$D/tb.prj" <<'EOF'
verilog work "atari_video.v"
verilog work "tb_video_compare.v"
EOF
		run_one_plain "$D" tb_video_compare
		echo "frames: $D/frame_a.ppm $D/frame_b.ppm"
		;;
	*)
		echo "usage: $0 sio|atr|xex|video|video_compare" >&2
		exit 2
		;;
esac

echo "OK"
