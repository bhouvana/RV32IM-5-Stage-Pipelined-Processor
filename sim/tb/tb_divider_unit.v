`include "Divider.v"

// Standalone unit test for Divider.v, independent of the pipeline. Not part
// of sim/run_tests.sh's tb_*.v glob on purpose (different harness shape --
// drives the DUT directly with a task instead of loading a program).
module tb_divider_unit;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg isSigned = 0;
    reg [31:0] dividend = 0;
    reg [31:0] divisor = 0;
    wire busy, done;
    wire [31:0] quotient, remainder;

    integer fails = 0;
    integer checks = 0;

    Divider dut(.clk(clk), .rst(rst), .start(start), .isSigned(isSigned),
                .dividend(dividend), .divisor(divisor),
                .busy(busy), .done(done), .quotient(quotient), .remainder(remainder));

    always #5 clk = ~clk;

    task run_case;
        input sgn;
        input [31:0] a, b;
        input [31:0] exp_q, exp_r;
        input [255:0] label;
        integer cyc;
        begin
            // Nonblocking: driving DUT inputs with blocking assignment right
            // after @(posedge clk) races against the DUT's own posedge-
            // triggered always block sampling those same signals at the same
            // edge (evaluation order between separate blocks is otherwise
            // unspecified). Nonblocking defers the update past the current
            // active-region reads, matching how a synchronous design's
            // stimulus should always be driven.
            @(posedge clk);
            isSigned <= sgn; dividend <= a; divisor <= b; start <= 1;
            @(posedge clk);
            start <= 0;
            cyc = 0;
            while (!done && cyc < 40) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            checks = checks + 1;
            if (!done) begin
                fails = fails + 1;
                $display("FAIL  %0s: never completed (busy=%b after %0d cycles)", label, busy, cyc);
            end else if (quotient !== exp_q || remainder !== exp_r) begin
                fails = fails + 1;
                $display("FAIL  %0s: q=%0d r=%0d (0x%08h/0x%08h), expected q=0x%08h r=0x%08h",
                          label, quotient, remainder, quotient, remainder, exp_q, exp_r);
            end else begin
                $display("pass  %0s: q=0x%08h r=0x%08h in %0d cycles", label, quotient, remainder, cyc);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        @(posedge clk); rst = 0;
        @(posedge clk); rst = 1;

        run_case(0, 32'd17, 32'd5, 32'd3, 32'd2, "unsigned 17/5");
        run_case(1, 32'd17, 32'd5, 32'd3, 32'd2, "signed 17/5");
        run_case(1, -32'd7, 32'd2, -32'd3, -32'd1, "signed -7/2 (truncate toward zero)");
        run_case(1, 32'd7, -32'd2, -32'd3, 32'd1, "signed 7/-2");
        run_case(1, -32'd7, -32'd2, 32'd3, -32'd1, "signed -7/-2");
        run_case(1, 32'd5, 32'd0, 32'hFFFFFFFF, 32'd5, "signed div by zero");
        run_case(0, 32'd5, 32'd0, 32'hFFFFFFFF, 32'd5, "unsigned div by zero");
        run_case(1, 32'h80000000, 32'hFFFFFFFF, 32'h80000000, 32'd0, "signed overflow INT_MIN/-1");
        run_case(0, 32'hFFFFFFFF, 32'd1, 32'hFFFFFFFF, 32'd0, "unsigned 0xFFFFFFFF/1");
        run_case(0, 32'd0, 32'd7, 32'd0, 32'd0, "0/7");

        if (fails == 0)
            $display("PASS  divider_unit (%0d checks)", checks);
        else
            $display("FAIL  divider_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
