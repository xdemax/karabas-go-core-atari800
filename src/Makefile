# Command line build of the Atari 800XL core for the Karabas Go.
#
#   make                 bitstream and atari800.kg
#   make go              synthesis, implementation, bitstream, .kg file
#   make go-xst          one step: go-xst (.ngc), go-impl (.bin), go-core (.kg)
#   make go-report       LUTs, slices, block RAMs and the timing result
#   make clean           intermediate files (not the .bin / .kg files)
#
# Inputs: karabas_go.prj (source list, shared modules as "../modules/rtl/..."),
# .xst, .ucf, .ut.  One src/core.json and one atari800.kg.

ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
PART = xc6slx25-ftg256-2
BOARDS = go mini minig

SHELL = /bin/bash
.SHELLFLAGS = -e -o pipefail -c
.NOTPARALLEL:
XIL = source $(ISE_SETTINGS) > /dev/null;

KG = atari800.kg
JSON = core.json
MAKE_CORE = ../tools/make_core.py

MAP_OPT = -logic_opt off -ol high -xe n -xt 0 -register_duplication off -r 4 -global_opt speed -mt 2 -detail -ir off -pr b -power off
PAR_OPT = -ol high -xe n -mt 4

# FAST=1: quicker test builds (skip trce, lower place&route effort)
ifeq ($(FAST),1)
MAP_OPT = -logic_opt off -ol med -xe n -xt 0 -register_duplication off -r 4 -global_opt speed -mt 2 -detail -ir off -pr b -power off
PAR_OPT = -ol std -xe n -mt 4
endif

MAP_LC = off
MAP_T = 2

INCLUDES = $(wildcard rtl/*.vh a8core/*.vh ../modules/rtl/mcu/*.vh)

.PHONY: all clean $(BOARDS) $(BOARDS:=-xst) $(BOARDS:=-impl) $(BOARDS:=-core) $(BOARDS:=-report)

all: $(BOARDS)

define board
SRC_$(1) := $$(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' karabas_$(1).prj)

karabas_$(1).ngc: karabas_$(1).prj karabas_$(1).xst $$(SRC_$(1)) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	$(XIL) xst -intstyle ise -ifn karabas_$(1).xst -ofn karabas_$(1).syr

karabas_$(1).bin: karabas_$(1).ngc karabas_$(1).ucf karabas_$(1).ut
	$(XIL) ngdbuild -intstyle ise -dd _ngo -nt timestamp -uc karabas_$(1).ucf -p $(PART) karabas_$(1).ngc karabas_$(1).ngd
	$(XIL) map -intstyle ise -p $(PART) -w $(MAP_OPT) -lc $(MAP_LC) -t $(MAP_T) -o karabas_$(1)_map.ncd karabas_$(1).ngd karabas_$(1).pcf
	$(XIL) par -w -intstyle ise $(PAR_OPT) karabas_$(1)_map.ncd karabas_$(1).ncd karabas_$(1).pcf
	@if [ "$(FAST)" = "1" ]; then echo "trce skipped (FAST=1)"; else $(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml karabas_$(1).twx karabas_$(1).ncd -o karabas_$(1).twr karabas_$(1).pcf -ucf karabas_$(1).ucf; fi
	$(XIL) bitgen -intstyle ise -f karabas_$(1).ut karabas_$(1).ncd

kg_$(1).stamp: karabas_$(1).bin $(JSON) $$(wildcard roms/*)
	python3 $(MAKE_CORE) $(JSON) $(KG) --boards $(1)
	touch $$@

$(1): kg_$(1).stamp
$(1)-xst: karabas_$(1).ngc
$(1)-impl: karabas_$(1).bin
$(1)-core: kg_$(1).stamp
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs):" karabas_$(1)_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" karabas_$(1).par | sort -u
endef

$(foreach b,$(BOARDS),$(eval $(call board,$(b))))

clean:
	rm -rf xst _ngo _xmsgs xlnx_auto_0_xdb iseconfig
	rm -f $(foreach b,$(BOARDS),$(addprefix karabas_$(b),.ngc .ngd .ngr .syr .lso .bld .pcf .ncd _map.ncd _map.ngm \
		_map.map _map.mrp _map.psr _map.xrpt .par .pad _pad.csv _pad.txt .psr .twr .twx .unroutes .xpi .ptwx .bgn .bit .drc \
		_bitgen.xwbt _summary.xml _usage.xml _xst.xrpt _ngdbuild.xrpt _par.xrpt _guide.ncd))
	rm -f $(BOARDS:%=kg_%.stamp)
