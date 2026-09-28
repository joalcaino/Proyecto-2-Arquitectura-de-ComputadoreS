// seg2hex.vh - lee los displays como lo haria una persona.
// Recibe los 7 pines {G,F,E,D,C,B,A} (activos en bajo) y devuelve el digito que
// dibujan. Si el dibujo no es un digito valido devuelve x, y la comparacion falla.

function [3:0] seg2hex(input [6:0] pins);
  case (~pins)
    7'b0111111: seg2hex = 4'h0;  7'b0000110: seg2hex = 4'h1;
    7'b1011011: seg2hex = 4'h2;  7'b1001111: seg2hex = 4'h3;
    7'b1100110: seg2hex = 4'h4;  7'b1101101: seg2hex = 4'h5;
    7'b1111101: seg2hex = 4'h6;  7'b0000111: seg2hex = 4'h7;
    7'b1111111: seg2hex = 4'h8;  7'b1101111: seg2hex = 4'h9;
    7'b1110111: seg2hex = 4'hA;  7'b1111100: seg2hex = 4'hB;
    7'b0111001: seg2hex = 4'hC;  7'b1011110: seg2hex = 4'hD;
    7'b1111001: seg2hex = 4'hE;  7'b1110001: seg2hex = 4'hF;
    default:    seg2hex = 4'hx;
  endcase
endfunction

// Los dos displays juntos: izquierdo en los bits 7:4, derecho en 3:0.
function [7:0] shown(input [6:0] left, input [6:0] right);
  shown = {seg2hex(left), seg2hex(right)};
endfunction
