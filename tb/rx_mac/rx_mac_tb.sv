`timescale 1ns / 1ps

module tb_rx_mac_core();

    // =========================================================================
    // System Signals
    // =========================================================================
    logic       rgmii_rx_clk;
    logic       rgmii_rst_n;
    logic [3:0] rgmii_rxd;
    logic       rgmii_rx_ctl;

    logic [7:0] m_axis_tdata;
    logic       m_axis_tvalid;
    logic       m_axis_tlast;
    logic       rx_error;

    // =========================================================================
    // Clock Generation (125 MHz)
    // =========================================================================
    initial begin
        rgmii_rx_clk = 0;
        // 125 MHz clock has an 8 ns period (toggles every 4 ns)
        forever #4 rgmii_rx_clk = ~rgmii_rx_clk; 
    end

    // =========================================================================
    // Device Under Test (DUT)
    // =========================================================================
    rx_mac_core dut (
        .rgmii_rx_clk (rgmii_rx_clk),
        .rgmii_rst_n  (rgmii_rst_n),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .rx_error     (rx_error)
    );

    // =========================================================================
    // Scoreboard
    // =========================================================================
    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic check_int(input string name, input int got, input int exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  [FAIL] %-44s got %0d, expected %0d", name, got, exp);
        end else begin
            $display("  [ ok ] %-44s %0d", name, got);
        end
    endtask

    // =========================================================================
    // AXI4-Stream Payload Monitor
    //
    // Checks the streamed bytes against what was sent instead of just printing
    // them: the RX MAC has to strip the preamble, the 14-byte L2 header AND the
    // trailing 4-byte FCS, and an off-by-one in the sliding window would be
    // invisible to a $display-only monitor.
    // =========================================================================
    logic [7:0] rx_buf [0:255];   // bytes the DUT streamed up
    int         rx_idx;           // how many, for the current frame

    // Counters, not single-bit flags. rx_error is only meaningful on the one
    // cycle the packet ends, so it has to be accumulated across the frame
    // rather than sampled at a fixed offset afterwards -- and counting how
    // many times it fired is strictly more informative than a sticky bit.
    int         rx_tlast_n;
    int         rx_error_n;

    initial begin
        rx_idx     = 0;
        rx_tlast_n = 0;
        rx_error_n = 0;
    end

    // PURE RECORDER. Two deliberate structural choices, both about portability:
    //
    //   1. A clocked `always` block, not `initial ... forever`. Under --timing
    //      an initial/forever monitor becomes a coroutine whose scoreboard
    //      writes were not reliably observed by the test process unless
    //      waveform tracing happened to keep the signals alive -- a bench whose
    //      result depends on --trace is a race, and it would resolve
    //      differently again under xsim. An `always` block is a first-class
    //      scheduled process in every simulator.
    //
    //   2. It only ever WRITES scoreboard state, never reads anything the test
    //      process owns. Data flow stays one-way: record here, compare in
    //      send_frame.
    //
    // Sampling is on the NEGEDGE, mid-cycle. m_axis_tvalid / tlast / rx_error
    // are all combinational off flopped state, and reading them exactly ON the
    // rising edge is a race -- you get the pre-edge or post-edge value
    // depending on how the simulator orders the combinational settle. That is
    // what made tlast and rx_error (both single-cycle pulses) read as 0 here.
    // Half a cycle later everything is settled, in any simulator, and it needs
    // no #delay so there is no timescale dependence either.
    always @(negedge rgmii_rx_clk) begin
        if (rx_error) rx_error_n++;
        if (m_axis_tvalid) begin
            if (rx_idx < 256) rx_buf[rx_idx] = m_axis_tdata;
            rx_idx++;
            if (m_axis_tlast) rx_tlast_n++;
        end
    end

    // =========================================================================
    // RGMII Driver Tasks
    // =========================================================================
    
    // Drive a single byte over the RGMII DDR interface.
    //
    // Each nibble is placed in the MIDDLE of its half period with a blocking
    // assignment. Driving with a non-blocking assignment ON the clock edge
    // races the DUT's capture flops -- whether they see the old or the new
    // value depends on the simulator's NBA ordering, and the --timing
    // scheduler resolves it the opposite way to xsim. The nibbles then land
    // half a byte out of phase and every frame decodes to garbage.
    task automatic send_byte(input logic [7:0] data, input logic err = 0);
        // Lower nibble, sampled by the DUT on the rising edge
        @(negedge rgmii_rx_clk);
        #2;
        rgmii_rxd    = data[3:0];
        rgmii_rx_ctl = 1'b1;

        // Upper nibble, sampled on the falling edge
        @(posedge rgmii_rx_clk);
        #2;
        rgmii_rxd    = data[7:4];
        rgmii_rx_ctl = 1'b1 ^ err; // XOR with RX_ER
    endtask

    // Assemble and drive a full Ethernet MAC frame
    int frame_num = 0;

    task automatic send_frame(
        input byte payload[],
        input bit corrupt_crc = 0,
        input int preamble_length = 7
    );
        byte frame_data[];
        int frame_len;
        int mismatches;
        logic [31:0] crc_val;
        
        // 14-byte Ethernet Header + Payload
        frame_len = 14 + payload.size();
        frame_data = new[frame_len];
        
        // Populate Dummy MAC Header
        for(int i = 0; i < 6; i++)  frame_data[i] = 8'hAA; // Dest MAC
        for(int i = 6; i < 12; i++) frame_data[i] = 8'hBB; // Src MAC
        frame_data[12] = 8'h08; // EtherType (IPv4)
        frame_data[13] = 8'h00;
        
        // Populate Payload
        for(int i = 0; i < payload.size(); i++) begin
            frame_data[14 + i] = payload[i];
        end

        // Arm the recorder. The DUT must hand up exactly this payload, with the
        // L2 header and the FCS already stripped.
        frame_num++;
        rx_idx     = 0;
        rx_tlast_n = 0;
        rx_error_n = 0;
        
        // Compute Standard IEEE 802.3 CRC-32 (Right-Shifting).
        //
        // frame_data is `byte`, which is SIGNED. XORing it straight into a
        // 32-bit accumulator leaves the width extension of any byte >= 0x80
        // (every MAC address byte here, and half of payload_1) dependent on how
        // the simulator resolves mixed-signedness operands. Mask to 8 bits
        // explicitly so the value is unambiguous everywhere.
        crc_val = 32'hFFFFFFFF;
        for (int i = 0; i < frame_len; i++) begin
            crc_val = crc_val ^ {24'h0, (frame_data[i] & 8'hFF)};
            for (int j = 0; j < 8; j++) begin
                if (crc_val[0]) crc_val = (crc_val >> 1) ^ 32'hEDB88320;
                else            crc_val = (crc_val >> 1);
            end
        end
        crc_val = ~crc_val; // Invert to get final FCS
        
        // Inject error if requested
        if (corrupt_crc) crc_val = ~crc_val; 
        
        // -----------------------------------------------------------------
        // Transmission Sequence
        // -----------------------------------------------------------------
        $display("\n[%0t ns] --- Starting Frame Transmission ---", $time);
        
        // 1. Preamble (Variable length)
        for(int i = 0; i < preamble_length; i++) send_byte(8'h55);
        
        // 2. Start Frame Delimiter (SFD)
        send_byte(8'hD5);
        
        // 3. Header + Payload
        for(int i = 0; i < frame_len; i++) send_byte(frame_data[i]);
        
        // 4. Frame Check Sequence (4 Bytes, LSB transmitted first)
        send_byte(crc_val[7:0]);
        send_byte(crc_val[15:8]);
        send_byte(crc_val[23:16]);
        send_byte(crc_val[31:24]);
        
        // 5. End of Packet (Return to Idle)
        @(negedge rgmii_rx_clk);
        #2;
        rgmii_rx_ctl = 0;
        rgmii_rxd    = 0;

        // Let the DDR pipeline and the sliding window flush.
        repeat(12) @(posedge rgmii_rx_clk);   // inter-frame gap

        mismatches = 0;
        for (int i = 0; i < payload.size() && i < rx_idx; i++)
            if (rx_buf[i] !== payload[i]) mismatches++;

        check_int($sformatf("F%0d payload byte count", frame_num),
                  rx_idx, payload.size());
        check_int($sformatf("F%0d payload contents", frame_num),
                  mismatches, 0);
        check_int($sformatf("F%0d tlast asserted exactly once", frame_num),
                  rx_tlast_n, 1);
        check_int($sformatf("F%0d rx_error (CRC)", frame_num),
                  (rx_error_n > 0) ? 1 : 0, int'(corrupt_crc));
    endtask

    // =========================================================================
    // Test Sequence Orchestrator
    // =========================================================================
    byte payload_1[] = '{8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h11, 8'h22, 8'h33, 8'h44};
    byte payload_2[] = '{8'hC0, 8'hFF, 8'hEE, 8'h00, 8'hFF};
    byte payload_3[] = '{8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08, 8'h09, 8'h0A};

    initial begin
        // Initialize lines
        rgmii_rst_n  = 0;
        rgmii_rxd    = 0;
        rgmii_rx_ctl = 0;

        // Apply Hard Reset
        repeat(5) @(posedge rgmii_rx_clk);
        rgmii_rst_n = 1;
        repeat(5) @(posedge rgmii_rx_clk);

        $display("=================================================");
        $display("Starting RX MAC Edge-Case Testbench");
        $display("=================================================");

        // Edge Case 1: Standard Frame
        $display("\n---> Test 1: Standard Valid Frame");
        send_frame(payload_1, 0, 7);

        // Edge Case 2: Bad CRC Evaluation (Gate Trigger)
        $display("\n---> Test 2: Frame with Corrupt FCS");
        send_frame(payload_2, 1, 7);

        // Edge Case 3: Preamble Extension (Common with physical PHYs)
        $display("\n---> Test 3: Extended Preamble (12 bytes instead of 7)");
        send_frame(payload_3, 0, 12);

        // Edge Case 4: Back-to-Back Burst (Minimum Inter-Frame Gap)
        $display("\n---> Test 4: Back-to-Back Line Rate Burst");
        send_frame(payload_1, 0, 7);
        send_frame(payload_2, 0, 7); // Sending payload 2 with GOOD CRC this time

        $display("\n=================================================");
        $display("  tb_rx_mac_core : %0d checks, %0d failures", checks, errors);
        if (errors == 0) $display("  RESULT: ALL TESTS PASSED");
        else             $display("  RESULT: %0d FAILURE(S)", errors);
        $display("=================================================");
        $finish;
    end

endmodule