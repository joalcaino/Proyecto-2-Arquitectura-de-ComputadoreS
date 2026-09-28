# Proyecto 2 - Juego de reflejos sobre Pochoco SoC (Nandland Go Board, iCE40 HX1K)
# Basado en el Makefile original de pochoco_soc (Nicolas Villegas, Universidad de los Andes).
#
#   make          sw/game.s -> sw/game.hex -> bitstream game_top.bin
#   make prog     lo anterior y ademas programa la Go Board
#   make hex      solo ensambla: sw/game.s -> sw/game.hex
#   make test     pruebas del assembler
#   make sim      simulacion: prueba de instrucciones + dos partidas completas del juego
#   make sim-post la misma partida sobre el circuito ya sintetizado (unos 7 minutos)
#   make clean
#
# Correr desde la terminal de OSS CAD Suite (environment.ps1 / environment.bat en
# Windows, o "source environment" en Linux): trae yosys, nextpnr, iverilog y python3.

TOP    := game_top
PCF    := goboard.pcf
PYTHON ?= python3
ASM    := asm/pochoasm.py
SRC    := $(wildcard rtl/*.v rtl/espino_core/*.v)

.PHONY: all prog hex test sim sim-post clean

all: $(TOP).bin

# 1) Assembly -> codigo de maquina, con nuestro assembler
hex: sw/game.hex

sw/game.hex: sw/game.s $(ASM)
	$(PYTHON) $(ASM) sw/game.s -o sw/game.hex -l sw/game.lst

# 2) Sintesis. La RAM arranca con el contenido de sw/game.hex ($readmemh en
#    rtl/pochoco_ram.v), por eso un cambio en el juego obliga a sintetizar de nuevo.
$(TOP).json: $(SRC) sw/game.hex
	yosys -q -l yosys.log -p "read_verilog $(SRC); synth_ice40 -top $(TOP) -json $@"

# 3) Place and route. --freq 25 hace fallar el build si no se alcanzan los 25 MHz del reloj.
$(TOP).asc: $(TOP).json $(PCF)
	nextpnr-ice40 --hx1k --package vq100 --freq 25 --json $(TOP).json --pcf $(PCF) --asc $@ -q -l nextpnr.log

# 4) Bitstream
$(TOP).bin: $(TOP).asc
	icepack $(TOP).asc $@

# 5) Programar la placa
prog: $(TOP).bin
	iceprog $(TOP).bin

test:
	$(PYTHON) -m unittest discover -s asm -v

# Simulacion con Icarus Verilog. El juego se ensambla con tiempos cortos para que
# dure segundos; las mismas constantes van al assembler y al testbench.
SIM_CONST := WAIT_CYCLES=20000 TENTH_CYCLES=1000 DEBOUNCE_CYCLES=200 BLINK_CYCLES=2000
# Modelo de simulacion de SB_RAM40_4K (lo usa el banco de registros del core).
# YOSYSHQ_ROOT lo define el script environment de OSS CAD Suite.
CELLS_SIM ?= $(YOSYSHQ_ROOT)/share/yosys/ice40/cells_sim.v

sim: sim/isa_test.hex sim/game_sim.hex
	iverilog -g2012 -o sim/isa.vvp -s isa_tb $(SRC) sim/isa_tb.v $(CELLS_SIM)
	vvp -n sim/isa.vvp
	iverilog -g2012 $(addprefix -D,$(SIM_CONST)) -o sim/game.vvp -s game_tb $(SRC) sim/game_tb.v $(CELLS_SIM)
	vvp -n sim/game.vvp

# Simulacion post-sintesis: el mismo testbench sobre el circuito que genera Yosys,
# hecho de celdas y bloques de RAM de la iCE40. Es lo que se graba en la placa.
sim-post: sim/game_sim.hex
	yosys -q -p "read_verilog $(SRC); chparam -set MemFile \"sim/game_sim.hex\" game_top; synth_ice40 -top game_top; write_verilog -noattr sim/game_top_post.v"
	iverilog -g2012 -DPOST_SYNTH $(addprefix -D,$(SIM_CONST)) -o sim/game_post.vvp -s game_tb sim/game_top_post.v sim/game_tb.v $(CELLS_SIM)
	vvp -n sim/game_post.vvp

sim/isa_test.hex: sim/isa_test.s $(ASM)
	$(PYTHON) $(ASM) sim/isa_test.s -o $@

sim/game_sim.hex: sw/game.s $(ASM)
	$(PYTHON) $(ASM) sw/game.s -o $@ $(addprefix -D,$(SIM_CONST))

# Con python y no con rm, para que funcione igual en la terminal de Windows.
clean:
	$(PYTHON) -c "import glob, os; [os.remove(f) for p in ('*.json', '*.asc', '*.log', '$(TOP).bin', 'sim/*.vvp', 'sim/*.hex', 'sim/game_top_post.v', 'sw/*.lst') for f in glob.glob(p)]"
