// game_tb.v - juega dos partidas completas contra el SoC corriendo game.s y revisa
// cada regla del enunciado mirando solo los pines de la placa (LEDs y displays).
//
// Se ejecuta con:  make sim
// El Makefile ensambla game.s con tiempos cortos (-D WAIT_CYCLES=...) para que la
// simulacion dure segundos, y le pasa los mismos valores a este archivo.
`timescale 1ns/1ps

module game_tb;
  localparam WAIT     = `WAIT_CYCLES;       // fase de 4 LEDs ("3 s")
  localparam TENTH    = `TENTH_CYCLES;      // una decima
  localparam DEBOUNCE = `DEBOUNCE_CYCLES;
  localparam BLINK    = `BLINK_CYCLES;

  reg clk = 1'b0;
  always #20 clk = ~clk;                   // 25 MHz

  reg  [3:0] btn = 4'b0000;
  wire [3:0] led;
  wire [6:0] seg1, seg2;                   // pines {G,F,E,D,C,B,A}, activos en bajo

  game_top dut (
    .i_Clk(clk), .o_LED(led), .i_Switch(btn),
    .o_Segment1_A(seg1[0]), .o_Segment1_B(seg1[1]), .o_Segment1_C(seg1[2]), .o_Segment1_D(seg1[3]),
    .o_Segment1_E(seg1[4]), .o_Segment1_F(seg1[5]), .o_Segment1_G(seg1[6]),
    .o_Segment2_A(seg2[0]), .o_Segment2_B(seg2[1]), .o_Segment2_C(seg2[2]), .o_Segment2_D(seg2[3]),
    .o_Segment2_E(seg2[4]), .o_Segment2_F(seg2[5]), .o_Segment2_G(seg2[6]),
    .i_SPI_SCLK(1'b0), .i_SPI_MOSI(1'b0), .i_SPI_CS_n(1'b1), .o_SPI_MISO()
  );
`ifndef POST_SYNTH   // en el circuito sintetizado la RAM ya trae el programa
  defparam dut.MemFile = "sim/game_sim.hex";
`endif

  `include "sim/seg2hex.vh"

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // Ciclo en que los LEDs tomaron su valor actual: las duraciones se miden desde
  // ahi y no desde que el testbench se pone a mirar.
  integer led_since = 0;
  always @(led) led_since = cyc;

  // --- utilidades -----------------------------------------------------------
  integer fails = 0;
  task check(input ok, input string what);
    if (!ok) begin
      fails = fails + 1;
      $display("  FALLO [ciclo %0d]: %s", cyc, what);
    end
  endtask

  function [7:0] bcd(input integer tenths);  // lo que deben mostrar los displays
    integer v;
    begin
      v = (tenths > 99) ? 99 : tenths;
      bcd = (v / 10) * 16 + (v % 10);
    end
  endfunction

  function integer onehot_index(input [3:0] l);
    case (l)
      4'b0001: onehot_index = 0;
      4'b0010: onehot_index = 1;
      4'b0100: onehot_index = 2;
      4'b1000: onehot_index = 3;
      default: onehot_index = -1;
    endcase
  endfunction

  task wait_led(input [3:0] pattern, input integer timeout);
    integer t0;
    begin
      t0 = cyc;
      while (led !== pattern && cyc - t0 < timeout) @(posedge clk);
      check(led === pattern, $sformatf("se esperaban los LEDs en %b y estan en %b", pattern, led));
    end
  endtask

  task wait_target(output integer idx);
    integer t0;
    begin
      t0 = cyc;
      while (onehot_index(led) < 0 && cyc - t0 < 2 * WAIT) @(posedge clk);
      idx = onehot_index(led);
      check(idx >= 0, "no aparecio el LED objetivo");
    end
  endtask

  // Un boton real rebota: 3 pulsos cortos antes de quedar firme.
  // Se usa <= para que el SoC lea el valor de antes del flanco, sin carrera.
  task press(input integer i);
    integer k;
    begin
      for (k = 0; k < 3; k = k + 1) begin
        btn[i] <= 1'b1; repeat (15) @(posedge clk);
        btn[i] <= 1'b0; repeat (15) @(posedge clk);
      end
      btn[i] <= 1'b1;
    end
  endtask

  task release_btn(input integer i);
    integer k;
    begin
      for (k = 0; k < 3; k = k + 1) begin
        btn[i] <= 1'b0; repeat (15) @(posedge clk);
        btn[i] <= 1'b1; repeat (15) @(posedge clk);
      end
      btn[i] <= 1'b0;
    end
  endtask

  task tap(input integer i);
    begin
      press(i);
      repeat (300) @(posedge clk);
      release_btn(i);
    end
  endtask

  // --- una ronda ----------------------------------------------------------
  // tenths:      tiempo de reaccion, en decimas (se aprieta a mitad de la decima)
  // wrong_first: antes de acertar, aprieta un boton equivocado
  // hold_first:  mantiene un boton apretado durante toda la fase de 4 LEDs
  task play_round(input integer tenths, input integer wrong_first, input integer hold_first,
                  output integer idx);
    integer t_all, t_target, t_release, bad;
    begin
      wait_led(4'b1111, 3 * WAIT);
      t_all = led_since;

      if (hold_first) begin
        press(0);
        while (cyc - t_all < WAIT + 1500) @(posedge clk);
        check(led === 4'b1111, "con un boton apretado el objetivo no debe aparecer");
        check(shown(seg1, seg2) !== 8'hEE, "apretar durante la fase de 4 LEDs no es un error");
        release_btn(0);
        t_release = cyc;
      end

      wait_target(idx);
      t_target = led_since;
      check(t_target - t_all >= WAIT,
            $sformatf("los 4 LEDs duraron %0d ciclos, menos que %0d", t_target - t_all, WAIT));
      if (hold_first)
        check(t_target - t_release >= DEBOUNCE,
              $sformatf("el objetivo aparecio %0d ciclos despues de soltar (< %0d)", t_target - t_release, DEBOUNCE));

      if (wrong_first) begin
        bad = (idx + 1) % 4;
        repeat (TENTH) @(posedge clk);
        press(bad);
        repeat (200) @(posedge clk);
        check(shown(seg1, seg2) === 8'hEE, "boton incorrecto: los displays no muestran EE");
        release_btn(bad);
        $display("  ronda con error: objetivo LED %0d, se apreto %0d -> displays %h, la ronda se repite",
                 idx, bad, shown(seg1, seg2));
        wait_led(4'b1111, 3 * WAIT);          // la ronda parte de nuevo
        t_all = led_since;
        wait_target(idx);
        t_target = led_since;
        check(t_target - t_all >= WAIT, "la ronda repetida no tuvo su fase de 4 LEDs");
      end

      repeat (tenths * TENTH + TENTH / 2 - 1) @(posedge clk);
      press(idx);
      repeat (3000) @(posedge clk);           // tiempo para que el programa divida y muestre
      check(shown(seg1, seg2) === bcd(tenths),
            $sformatf("reaccion de %0d decimas: se esperaba %h y los displays muestran %h",
                      tenths, bcd(tenths), shown(seg1, seg2)));
      release_btn(idx);
    end
  endtask

  // --- el escenario ---------------------------------------------------------
  integer r, idx, sum, t0, differ;
  integer react [0:9];
  integer seq1 [0:9];
  integer seq2 [0:9];

  initial begin
    // 12 y 15 decimas prueban dos digitos; 120 no cabe y debe mostrarse 99 (pero
    // se suma completo al promedio). Suma = 181 -> promedio 18.
    react[0] = 3;   react[1] = 7;  react[2] = 12; react[3] = 5; react[4] = 120;
    react[5] = 1;   react[6] = 15; react[7] = 4;  react[8] = 8; react[9] = 6;

    $display("Arranque");
    wait_led(4'b0101, 4 * BLINK);
    check(shown(seg1, seg2) === 8'h00, "al encender los displays deben mostrar 00");
    wait_led(4'b1010, 2 * BLINK);             // parpadea mientras espera

    $display("Partida 1: 10 rondas, una con boton incorrecto y otra con boton sostenido");
    repeat (1234) @(posedge clk);
    tap(2);
    sum = 0;
    for (r = 0; r < 10; r = r + 1) begin
      play_round(react[r], r == 2, r == 6, idx);
      seq1[r] = idx;
      sum = sum + react[r];
      $display("  ronda %0d: LED %0d, %0d decimas -> displays %h", r + 1, idx, react[r], shown(seg1, seg2));
    end

    // Tras la decima: LEDs apagados, se sigue viendo el ultimo tiempo; despues, el promedio.
    wait_led(4'b0000, 5000);
    check(shown(seg1, seg2) === bcd(react[9]), "tras la ultima ronda debe seguir viendose su tiempo");
    t0 = led_since;
    while (led !== 4'b0101 && led !== 4'b1010 && cyc - t0 < 2 * WAIT) @(posedge clk);
    check(led_since - t0 >= WAIT, "el ultimo tiempo debe verse durante WAIT_CYCLES");
    check(shown(seg1, seg2) === bcd(sum / 10),
          $sformatf("promedio: se esperaba %h y los displays muestran %h", bcd(sum / 10), shown(seg1, seg2)));
    $display("  promedio: %0d / 10 = %0d decimas -> displays %h (LEDs parpadeando: %b)",
             sum, sum / 10, shown(seg1, seg2), led);

    $display("Partida 2: se empieza en otro instante");
    repeat (7777) @(posedge clk);
    tap(1);
    wait_led(4'b1111, 3 * WAIT);
    check(shown(seg1, seg2) === 8'h00, "una partida nueva debe partir con los displays en 00");
    for (r = 0; r < 10; r = r + 1) begin
      play_round(2, 0, 0, idx);
      seq2[r] = idx;
    end
    wait_led(4'b0000, 5000);
    t0 = cyc;
    while (led !== 4'b0101 && led !== 4'b1010 && cyc - t0 < 2 * WAIT) @(posedge clk);
    check(shown(seg1, seg2) === bcd(2), "promedio de la partida 2");

    differ = 0;
    for (r = 0; r < 10; r = r + 1) if (seq1[r] != seq2[r]) differ = differ + 1;
    $display("  LEDs objetivo partida 1: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
             seq1[0], seq1[1], seq1[2], seq1[3], seq1[4], seq1[5], seq1[6], seq1[7], seq1[8], seq1[9]);
    $display("  LEDs objetivo partida 2: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
             seq2[0], seq2[1], seq2[2], seq2[3], seq2[4], seq2[5], seq2[6], seq2[7], seq2[8], seq2[9]);
    check(differ > 0, "las dos partidas tuvieron la misma secuencia de LEDs");

    if (fails == 0) $display("JUEGO: OK - todas las reglas se cumplen");
    else            $fatal(1, "JUEGO: FALLO - %0d revisiones fallaron", fails);
    $finish;
  end

  initial begin
    #(40.0 * 3_000_000);
    $fatal(1, "JUEGO: FALLO - timeout");
  end
endmodule
