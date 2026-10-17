/*
 * tt_um_audris123_4_bit_binary_counter  —  Tiny Tapeout, 1x1 tile
 *
 * Measures the duty cycle of a ~1 kHz PWM signal on ui_in[0] and shows
 * it on a VGA monitor (640x480 @ 60 Hz) as large text, e.g.  " 37.5%".
 * Range 0.0 % .. 100.0 %, 0.1 % steps (truncated).
 *
 * Pins
 *   ui_in[0]   PWM input (1 kHz, 0..100 % duty, 3.3 V logic)
 *   uo_out     Tiny VGA PMOD:
 *              uo[0]=R1 uo[1]=G1 uo[2]=B1 uo[3]=VSYNC
 *              uo[4]=R0 uo[5]=G0 uo[6]=B0 uo[7]=HSYNC
 *
 * Clock: 25.175 MHz VGA pixel clock (set clock_hz: 25175000 in info.yaml).
 *        25 MHz also works on practically every monitor.
 *
 * How the percentage is found: count period and high time between two
 * rising edges, then long-divide hi/period in base 10 (x10, subtract
 * until smaller) three times -> tens, ones, tenths digits.
 * 0 % / 100 % (no edges) are caught by a ~1.3 ms timeout.
 */

`default_nettype none

module tt_um_audris123_4_bit_binary_counter (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam CW = 15;        // period counter: 2^15 > 25175 counts per 1 ms
    localparam RW = CW + 4;    // remainder width, holds remainder * 10

    // ==================================================================
    // Input synchronizer + rising-edge detect
    // ==================================================================
    reg [2:0] sync;
    always @(posedge clk) begin
        if (!rst_n) sync <= 3'b000;
        else        sync <= {sync[1:0], ui_in[0]};
    end
    wire pwm  = sync[1];
    wire rise = sync[1] & ~sync[2];

    // ==================================================================
    // Duty-cycle measurement -> 3 decimal digits
    // ==================================================================
    localparam S_WAIT = 2'd0,   // wait for a rising edge
               S_MEAS = 2'd1,   // count one period and its high time
               S_MUL  = 2'd2,   // remainder *= 10
               S_SUB  = 2'd3;   // subtract period until remainder < period

    reg [1:0]    state;
    reg [CW-1:0] per_cnt;       // period length (also the divisor)
    reg [RW-1:0] rem;           // high-time counter, then the remainder
    reg [3:0]    digit;
    reg [7:0]    work;          // tens and ones while computing
    reg [1:0]    pos;           // which digit is being computed

    // shown on screen
    reg          disp_h;        // 1 -> "100.0%"
    reg [3:0]    disp_t, disp_o, disp_f;

    wire [RW-1:0] per_w   = {{(RW-CW){1'b0}}, per_cnt};
    wire          rem_ge  = (rem >= per_w);
    wire [RW-1:0] rem_x10 = {rem[RW-4:0], 3'b000} + {rem[RW-2:0], 1'b0};

    always @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_WAIT;
            per_cnt <= 0;
            rem     <= 0;
            digit   <= 0;
            work    <= 0;
            pos     <= 0;
            disp_h  <= 1'b0;
            disp_t  <= 4'd0;
            disp_o  <= 4'd0;
            disp_f  <= 4'd0;
        end else begin
            case (state)
                S_WAIT: begin
                    if (rise) begin
                        per_cnt <= 1;
                        rem     <= 1;
                        state   <= S_MEAS;
                    end else if (&per_cnt) begin        // no edges: 0 % or 100 %
                        disp_h  <= pwm;
                        disp_t  <= 4'd0;
                        disp_o  <= 4'd0;
                        disp_f  <= 4'd0;
                        per_cnt <= 0;
                    end else begin
                        per_cnt <= per_cnt + 1'b1;
                    end
                end

                S_MEAS: begin
                    if (rise) begin                     // full period measured
                        pos   <= 2'd0;
                        state <= S_MUL;
                    end else if (&per_cnt) begin        // signal stopped toggling
                        disp_h  <= pwm;
                        disp_t  <= 4'd0;
                        disp_o  <= 4'd0;
                        disp_f  <= 4'd0;
                        per_cnt <= 0;
                        state   <= S_WAIT;
                    end else begin
                        per_cnt <= per_cnt + 1'b1;
                        if (pwm) rem <= rem + 1'b1;
                    end
                end

                S_MUL: begin                            // rem < per here, so digit <= 9
                    rem   <= rem_x10;
                    digit <= 4'd0;
                    state <= S_SUB;
                end

                S_SUB: begin
                    if (rem_ge) begin
                        rem   <= rem - per_w;
                        digit <= digit + 1'b1;
                    end else if (pos == 2'd2) begin     // tenths done -> show it
                        disp_h  <= 1'b0;
                        disp_t  <= work[7:4];
                        disp_o  <= work[3:0];
                        disp_f  <= digit;
                        per_cnt <= 0;
                        state   <= S_WAIT;
                    end else begin
                        work  <= {work[3:0], digit};
                        pos   <= pos + 1'b1;
                        state <= S_MUL;
                    end
                end
            endcase
        end
    end

    // ==================================================================
    // VGA timing, 640x480 @ 60 Hz
    // ==================================================================
    reg [9:0] hcnt, vcnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= 0;
            vcnt <= 0;
        end else if (hcnt == 10'd799) begin
            hcnt <= 0;
            vcnt <= (vcnt == 10'd524) ? 10'd0 : vcnt + 1'b1;
        end else begin
            hcnt <= hcnt + 1'b1;
        end
    end

    wire visible = (hcnt < 10'd640) && (vcnt < 10'd480);
    wire hsync   = ~((hcnt >= 10'd656) && (hcnt < 10'd752));
    wire vsync   = ~((vcnt >= 10'd490) && (vcnt < 10'd492));

    // ==================================================================
    // Text: 6 characters, each 64x64 px (5x7 font, 8x scaled)
    // x = 128..511 (columns hcnt[9:6] = 2..7), y = 192..255 (vcnt[9:6] = 3)
    // ==================================================================
    wire [3:0] col     = hcnt[9:6];
    wire [2:0] fx      = hcnt[5:3];
    wire [2:0] fy      = vcnt[5:3];
    wire       in_band = (vcnt[9:6] == 4'd3) && (col >= 4'd2) && (col <= 4'd7);

    // character codes: 0-9 digits, 10 '.', 11 '%', 15 blank
    reg [3:0] code;
    always @(*) begin
        case (col)
            4'd2:    code = disp_h ? 4'd1 : 4'd15;                         // hundreds
            4'd3:    code = (!disp_h && disp_t == 4'd0) ? 4'd15 : disp_t; // tens
            4'd4:    code = disp_o;                                       // ones
            4'd5:    code = 4'd10;                                        // '.'
            4'd6:    code = disp_f;                                       // tenths
            4'd7:    code = 4'd11;                                        // '%'
            default: code = 4'd15;
        endcase
    end

    // 5x7 font, MSB = leftmost pixel, row 0 = top
    function [4:0] glyph;
        input [3:0] c;
        input [2:0] r;
        reg   [34:0] g;
        begin
            case (c)
                4'd0:  g = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                4'd1:  g = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                4'd2:  g = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                4'd3:  g = {5'b11111,5'b00010,5'b00100,5'b00010,5'b00001,5'b10001,5'b01110};
                4'd4:  g = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                4'd5:  g = {5'b11111,5'b10000,5'b11110,5'b00001,5'b00001,5'b10001,5'b01110};
                4'd6:  g = {5'b00110,5'b01000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                4'd7:  g = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                4'd8:  g = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                4'd9:  g = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00010,5'b01100};
                4'd10: g = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b01100,5'b01100};
                4'd11: g = {5'b11000,5'b11001,5'b00010,5'b00100,5'b01000,5'b10011,5'b00011};
                default: g = 35'd0;
            endcase
            case (r)
                3'd0:    glyph = g[34:30];
                3'd1:    glyph = g[29:25];
                3'd2:    glyph = g[24:20];
                3'd3:    glyph = g[19:15];
                3'd4:    glyph = g[14:10];
                3'd5:    glyph = g[9:5];
                3'd6:    glyph = g[4:0];
                default: glyph = 5'd0;
            endcase
        end
    endfunction

    wire [4:0] row_bits = glyph(code, fy);
    wire       text_px  = in_band && (fx < 3'd5) && row_bits[3'd4 - fx];

    // colours: yellow text on dark blue, black outside the visible area
    wire [1:0] r = (visible && text_px) ? 2'b11 : 2'b00;
    wire [1:0] g = (visible && text_px) ? 2'b11 : 2'b00;
    wire [1:0] b = (visible && !text_px) ? 2'b01 : 2'b00;

    // registered outputs -> clean, glitch-free VGA signals
    reg [7:0] vga;
    always @(posedge clk) begin
        if (!rst_n) vga <= 8'b1000_1000;                 // syncs idle high
        else        vga <= {hsync, b[0], g[0], r[0], vsync, b[1], g[1], r[1]};
    end

    assign uo_out  = vga;
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{ena, ui_in[7:1], uio_in, 1'b0};

endmodule
