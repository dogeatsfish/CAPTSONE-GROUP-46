#==============================================================================
# Bench manifest -- sourced by the runners, not executed directly.
#
# ONE definition of what benches exist, what their top module is called, and
# which filelist builds them. Both the Verilator runner and the xsim runner read
# this, so the two flows can never drift apart on source order or top names.
#
# Adding a bench: drop a filelist in sim/filelists/<name>.f, add one line here,
# and both simulators pick it up. Nothing else to touch.
#
#   BENCH_TOP[<name>]  = top-level module name
#   BENCH_ORDER        = execution order for the regression (units, then chip)
#==============================================================================

declare -A BENCH_TOP=(
  [cdc_fifo]="axis_cdc_fifo_tb"
  [rx_mac]="tb_rx_mac_core"
  [tx_mac]="tx_mac_core_tb"
  [parser]="cut_through_parser_tb"
  [order_book]="order_book_array_tb"
  [order_book_crv]="order_book_crv_tb"
  [alpha_engine]="alpha_engine_core_tb"
  [risk_gateway]="tb_pre_trade_risk_gateway"
  [tx_gen]="outbound_tx_generator_tb"
  [integration]="commontrader_top_tb"
  [replay]="commontrader_replay_tb"
  [integration_crv]="commontrader_crv_tb"
)

# Unit benches first, integration last: if a block is broken, its own bench
# should be what tells you, not the full-chip run.
BENCH_ORDER=(
  cdc_fifo
  rx_mac
  tx_mac
  parser
  order_book
  order_book_crv
  alpha_engine
  risk_gateway
  tx_gen
  integration
  replay
  integration_crv
)
