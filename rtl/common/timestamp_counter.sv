//==============================================================================
// timestamp_counter  -  shared free-running latency time base (FS-12)
//
// ONE instance of this module exists in the design, at the top level. Its output
// is read by BOTH the Cut-through Stream Parser (which stamps a packet on
// ingress) and the Outbound TX Generator (which subtracts that stamp on egress
// to produce the latency telemetry).
//
// This is the whole reason the counter is a separate module instantiated once,
// rather than a counter inside each block: two independent counters would have
// no common time origin, and their difference would be meaningless. If you ever
// find yourself instantiating a second one of these, stop -- the measurement is
// already broken.
//
// WRAP BEHAVIOUR
//   Free-running, wraps silently. At WIDTH=16 and 4 ns/tick the range is 262 us.
//   The subtraction in the TX Generator is plain unsigned two's-complement, so a
//   single wrap between stamp and read still yields the correct delta; only a
//   latency exceeding the full 262 us range would alias. End-to-end latency is
//   budgeted at well under 10 us, so this cannot occur in a healthy system.
//
//   `wrapped` is a sticky flag for exactly that pathology: if it ever asserts in
//   a measurement window shorter than 262 us, something is stalled and the
//   telemetry from that window should not be trusted.
//==============================================================================

module timestamp_counter #(
  parameter int WIDTH = 16
)(
  input  logic             clk,
  input  logic             rst_n,

  output logic [WIDTH-1:0] timestamp_now,
  output logic             wrapped       // sticky: counter has rolled over
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      timestamp_now <= '0;
      wrapped       <= 1'b0;
    end else begin
      timestamp_now <= timestamp_now + 1'b1;

      // Roll-over is the all-ones -> zero transition.
      if (&timestamp_now) wrapped <= 1'b1;
    end
  end

endmodule
