/*
 * tt_um_audris123_4_bit_binary_counter  —  Tiny Tapeout, 1x1 tile
 *
 * Measures the duty cycle of a ~1 kHz PWM signal on ui_in[0] and sends
 * the result over UART as a 12-bit value in decimal ASCII:
 *
 *     "0000\r\n" ... "4095\r\n"      (0 = 0 %, 4095 = 100 %)
 *
 * duty = floor(high_time * 4096 / period), clamped to 0..4095.
 * 0 % and 100 % (no edges) are detected by a ~1.6 ms timeout.
 *
 * Pins
 *   ui_in[0]   PWM input (1 kHz, 0..100 % duty)
 *   uo_out[0]  UART TX, 8N1, 115200 baud (at 10 MHz clock)
 *   uo_out[1]  synchronized PWM echo (for scope debugging)
 *
 * Clock: 10 MHz (set clock_hz: 10000000 in info.yaml).
 * At 10 MHz one 1 kHz period = 10000 counts -> 0.01 % resolution.
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

    // ------------------------------------------------------------------
    // Parameters (change together if you change the clock)
    // ------------------------------------------------------------------
    localparam CLK_HZ   = 10_000_000;
    localparam BAUD     = 115_200;
    localparam BAUD_DIV = (CLK_HZ + BAUD/2) / BAUD;   // 87 @ 10 MHz
    localparam BW       = 7;                          // bits for BAUD_DIV
    localparam BAUD_LAST = BAUD_DIV - 1;
    localparam CW       = 14;                         // counter width, 2^14 > CLK_HZ/1000

    // ------------------------------------------------------------------
    // Input synchronizer + rising-edge detect
    // ------------------------------------------------------------------
    reg [2:0] sync;
    always @(posedge clk) begin
        if (!rst_n) sync <= 3'b000;
        else        sync <= {sync[1:0], ui_in[0]};
    end
    wire pwm  = sync[1];
    wire rise = sync[1] & ~sync[2];

    // ------------------------------------------------------------------
    // Main state machine
    // ------------------------------------------------------------------
    localparam S_WAIT = 3'd0,   // wait for first rising edge
               S_MEAS = 3'd1,   // count one full period + high time
               S_DIV  = 3'd2,   // q = hi*4096/per  (12 steps)
               S_BCD  = 3'd3,   // binary -> BCD     (12 steps)
               S_TX   = 3'd4;   // send 4 digits + CR LF

    reg [2:0]    state;
    reg [CW-1:0] per_cnt;   // period counter, later the divisor
    reg [CW-1:0] hi_cnt;    // high-time counter, later the remainder
    reg [11:0]   q;         // 12-bit result
    reg [15:0]   bcd;       // 4 BCD digits
    reg [3:0]    step;      // shared step / character counter

    // UART
    reg [9:0]    tx_sh;     // {stop, data[7:0], start}, sent LSB first
    reg [3:0]    tx_bits;
    reg [BW-1:0] baud_cnt;
    wire         tx_busy = (tx_bits != 4'd0);

    // restoring divider step
    wire [CW:0] rem2    = {hi_cnt, 1'b0};
    wire        rem_ge  = (rem2 >= {1'b0, per_cnt});
    // result < per_cnt, so the low CW bits are enough
    wire [CW-1:0] rem_sub = rem2[CW-1:0] - per_cnt;

    // double-dabble add-3 correction
    function [3:0] add3;
        input [3:0] d;
        add3 = (d >= 4'd5) ? d + 4'd3 : d;
    endfunction
    wire [15:0] bcd_adj = {add3(bcd[15:12]), add3(bcd[11:8]),
                           add3(bcd[7:4]),   add3(bcd[3:0])};

    // character to send
    reg [7:0] ch;
    always @(*) begin
        case (step[2:0])
            3'd0:    ch = {4'h3, bcd[15:12]};   // thousands
            3'd1:    ch = {4'h3, bcd[11:8]};    // hundreds
            3'd2:    ch = {4'h3, bcd[7:4]};     // tens
            3'd3:    ch = {4'h3, bcd[3:0]};     // ones
            3'd4:    ch = 8'h0D;                // CR
            default: ch = 8'h0A;                // LF
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_WAIT;
            per_cnt  <= 0;
            hi_cnt   <= 0;
            q        <= 0;
            bcd      <= 0;
            step     <= 0;
            tx_sh    <= 10'h3FF;
            tx_bits  <= 0;
            baud_cnt <= 0;
        end else begin
            // ---------------- UART bit timing ----------------
            if (tx_busy) begin
                if (baud_cnt == BAUD_LAST[BW-1:0]) begin
                    baud_cnt <= 0;
                    tx_sh    <= {1'b1, tx_sh[9:1]};
                    tx_bits  <= tx_bits - 4'd1;
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end

            // ---------------- control ----------------
            case (state)
                S_WAIT: begin
                    if (rise) begin
                        per_cnt <= 1;
                        hi_cnt  <= 1;
                        state   <= S_MEAS;
                    end else if (&per_cnt) begin        // no edge: 0 % or 100 %
                        q     <= pwm ? 12'd4095 : 12'd0;
                        bcd   <= 0;
                        step  <= 0;
                        state <= S_BCD;
                    end else begin
                        per_cnt <= per_cnt + 1'b1;
                    end
                end

                S_MEAS: begin
                    if (rise) begin                     // one full period done
                        step  <= 0;
                        state <= S_DIV;
                    end else if (&per_cnt) begin        // signal stopped
                        q     <= pwm ? 12'd4095 : 12'd0;
                        bcd   <= 0;
                        step  <= 0;
                        state <= S_BCD;
                    end else begin
                        per_cnt <= per_cnt + 1'b1;
                        if (pwm) hi_cnt <= hi_cnt + 1'b1;
                    end
                end

                S_DIV: begin                            // hi < per always holds here
                    if (rem_ge) begin
                        hi_cnt <= rem_sub;
                        q      <= {q[10:0], 1'b1};
                    end else begin
                        hi_cnt <= rem2[CW-1:0];
                        q      <= {q[10:0], 1'b0};
                    end
                    step <= step + 1'b1;
                    if (step == 4'd11) begin
                        step  <= 0;
                        bcd   <= 0;
                        state <= S_BCD;
                    end
                end

                S_BCD: begin
                    bcd  <= {bcd_adj[14:0], q[11]};
                    q    <= {q[10:0], 1'b0};
                    step <= step + 1'b1;
                    if (step == 4'd11) begin
                        step  <= 0;
                        state <= S_TX;
                    end
                end

                S_TX: begin
                    if (!tx_busy) begin
                        if (step == 4'd6) begin
                            step    <= 0;
                            per_cnt <= 0;
                            state   <= S_WAIT;
                        end else begin
                            tx_sh    <= {1'b1, ch, 1'b0};
                            tx_bits  <= 4'd10;
                            baud_cnt <= 0;
                            step     <= step + 1'b1;
                        end
                    end
                end

                default: state <= S_WAIT;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    assign uo_out  = {6'b0, pwm, tx_sh[0]};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // bcd_adj[15] is never needed: thousands digit is at most 4
    wire _unused = &{ena, ui_in[7:1], uio_in, bcd_adj[15], 1'b0};

endmodule
