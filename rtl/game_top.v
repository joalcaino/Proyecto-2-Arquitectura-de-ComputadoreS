// Proyecto 2 - Arquitectura de Computadores 2026-2
// Juego de reflejos sobre Pochoco SoC.
//
// Top-level que se sintetiza y programa en la Nandland Go Board (iCE40 HX1K).
// Solo instancia el SoC y le indica que imagen de memoria cargar al arrancar:
// sw/game.hex, generado por nuestro assembler (asm/pochoasm.py) desde sw/game.s.
// MemFile es parametro solo para que la simulacion post-sintesis (make sim-post)
// pueda cargar la version del juego con tiempos cortos.
// Los nombres de los puertos coinciden con goboard.pcf.

module game_top #(
  parameter MemFile = "sw/game.hex"
) (
  input  wire       i_Clk,        // 25 MHz

  output wire [3:0] o_LED,
  input  wire [3:0] i_Switch,     // boton i corresponde al LED i

  output wire       o_Segment1_A, o_Segment1_B, o_Segment1_C, o_Segment1_D,
  output wire       o_Segment1_E, o_Segment1_F, o_Segment1_G,
  output wire       o_Segment2_A, o_Segment2_B, o_Segment2_C, o_Segment2_D,
  output wire       o_Segment2_E, o_Segment2_F, o_Segment2_G,

  input  wire       i_SPI_SCLK,
  input  wire       i_SPI_MOSI,
  input  wire       i_SPI_CS_n,
  output wire       o_SPI_MISO
);

  pochoco_soc #(.MemFile(MemFile)) u_pochoco (
    .i_Clk        (i_Clk),

    .o_LED        (o_LED),
    .i_Switch     (i_Switch),

    .o_Segment1_A (o_Segment1_A), .o_Segment1_B (o_Segment1_B),
    .o_Segment1_C (o_Segment1_C), .o_Segment1_D (o_Segment1_D),
    .o_Segment1_E (o_Segment1_E), .o_Segment1_F (o_Segment1_F),
    .o_Segment1_G (o_Segment1_G),
    .o_Segment2_A (o_Segment2_A), .o_Segment2_B (o_Segment2_B),
    .o_Segment2_C (o_Segment2_C), .o_Segment2_D (o_Segment2_D),
    .o_Segment2_E (o_Segment2_E), .o_Segment2_F (o_Segment2_F),
    .o_Segment2_G (o_Segment2_G),

    .i_SPI_SCLK   (i_SPI_SCLK),
    .i_SPI_MOSI   (i_SPI_MOSI),
    .i_SPI_CS_n   (i_SPI_CS_n),
    .o_SPI_MISO   (o_SPI_MISO)
  );

endmodule
