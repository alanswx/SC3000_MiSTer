# Verilator simulator for the SC-3000 core. Needs Verilator 5.x and zlib.
#   make            obj_dir/Vsc3000_sim (t80sv, the hardware CPU)
#   make test       regression (tests/run_tests.sh)
#   make clean
RTL  = ../rtl
TOP  = sc3000_sim
EXE  = obj_dir/V$(TOP)

V_SRC = sim.vlt $(TOP).sv \
	$(RTL)/sc3000.sv $(RTL)/omv_keypad.sv $(RTL)/sc3000_keyboard.sv $(RTL)/sc3000_cart.sv $(RTL)/sc3000_detect.sv $(RTL)/sc3000_tape.sv $(RTL)/sc3000_tape_motor.sv $(RTL)/sc3000_tape_rec.sv $(RTL)/sc3000_clocks.sv $(RTL)/sf7000.sv $(RTL)/sf7000_fdc.sv $(RTL)/cv_clock.sv \
	$(RTL)/vdp18v/vdp18_pkg.sv $(RTL)/vdp18v/vdp18_clk_gen.sv $(RTL)/vdp18v/vdp18_core.sv \
	$(RTL)/vdp18v/vdp18_addr_mux.sv $(RTL)/vdp18v/vdp18_col_mux.sv $(RTL)/vdp18v/vdp18_cpuio.sv \
	$(RTL)/vdp18v/vdp18_ctrl.sv $(RTL)/vdp18v/vdp18_hor_vert.sv $(RTL)/vdp18v/vdp18_pattern.sv \
	$(RTL)/vdp18v/vdp18_sprite.sv \
	$(RTL)/t80sv/t80sv_all.sv \
	$(RTL)/jt8255.v \
	$(RTL)/jt89/jt89.v $(RTL)/jt89/jt89_mixer.v $(RTL)/jt89/jt89_noise.v $(RTL)/jt89/jt89_tone.v $(RTL)/jt89/jt89_vol.v

V_FLAGS = --cc --exe --build -j 0 --top-module $(TOP) --no-timing -Wno-fatal -Wno-lint -Wno-style \
	--x-assign fast --x-initial fast --noassert -O3 \
	+incdir+$(RTL)/vdp18v +incdir+$(RTL) \
	-CFLAGS "-O2 -std=c++17" -LDFLAGS "-lz"

all: $(EXE)

$(EXE): $(V_SRC) sim_main.cpp Makefile
	verilator $(V_FLAGS) $(V_SRC) sim_main.cpp

# full-rate build: clk = clk_sys (42.95 MHz), SC3000.sv's clock enables, tape turbo
full: obj_full/V$(TOP)
obj_full/V$(TOP): $(V_SRC) sim_main.cpp Makefile
	verilator $(V_FLAGS) --Mdir obj_full -GFULL=1 -CFLAGS -DSIM_FULL=1 $(V_SRC) sim_main.cpp

# FDC command log ($display) for SF-7000 debugging
fdclog: obj_log/V$(TOP)
obj_log/V$(TOP): $(V_SRC) sim_main.cpp Makefile
	verilator $(V_FLAGS) --Mdir obj_log +define+FDC_LOG $(V_SRC) sim_main.cpp

test: $(EXE) obj_full/V$(TOP) tests/kbd/obj/Vsc3000_keyboard
	./tests/kbd/obj/Vsc3000_keyboard | tail -1 && ./tests/run_tests.sh && ./tests/tape_save_roundtrip.sh

# keyboard unit test (rtl/sc3000_keyboard.sv; GAP = 100 clocks at CLK_HZ 2500)
tests/kbd/obj/Vsc3000_keyboard: $(RTL)/sc3000_keyboard.sv tests/kbd/kbd_tb.cpp
	verilator --cc --exe --build -j 8 -GCLK_HZ=2500 -Wno-fatal $(RTL)/sc3000_keyboard.sv tests/kbd/kbd_tb.cpp -Mdir tests/kbd/obj -o Vsc3000_keyboard

clean:
	rm -rf obj_dir obj_tv80 out
