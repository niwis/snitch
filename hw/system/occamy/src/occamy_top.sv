// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
// Author: Fabian Schuiki <zarubaf@iis.ee.ethz.ch>

`include "occamy/unpack.svh"

module occamy_top
  import occamy_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  /// PCIe Ports
  input  pice_in_t pcie_i,
  output pice_out_t pcie_o

  /// HBM2e Ports
  /// HBI Ports
);

  quadrant_in_t [NrS1Quadrants-1:0] quadrant_in;
  quadrant_out_t [NrS1Quadrants-1:0] quadrant_out;

  `UNPACK_IN(axi_wide_req_t, quadrant_out, wide_out_req, NrS1Quadrants)
  `UNPACK_IN(axi_wide_resp_t, quadrant_out, wide_in_rsp, NrS1Quadrants)
  `UNPACK_OUT(axi_wide_req_t, quadrant_in, wide_in_req, NrS1Quadrants)
  `UNPACK_OUT(axi_wide_resp_t, quadrant_in, wide_out_rsp, NrS1Quadrants)
  `UNPACK_IN(axi_narrow_req_t, quadrant_out, narrow_out_req, NrS1Quadrants)
  `UNPACK_IN(axi_narrow_resp_t, quadrant_out, narrow_in_rsp, NrS1Quadrants)
  `UNPACK_OUT(axi_narrow_req_t, quadrant_in, narrow_in_req, NrS1Quadrants)
  `UNPACK_OUT(axi_narrow_resp_t, quadrant_in, narrow_out_rsp, NrS1Quadrants)

  axi_wide_req_t axi_narrow_to_wide_req;
  axi_wide_resp_t axi_narrow_to_wide_rsp;
  axi_narrow_req_t axi_narrow_to_wide_id_remap_req;
  axi_narrow_resp_t axi_narrow_to_wide_id_remap_rsp;

  localparam int unsigned WideNumMstPorts = NrS1Quadrants + 1;
  localparam int unsigned WideNumSlvPorts = NrS1Quadrants + 2;
  localparam bit [WideNumSlvPorts-1:0][WideNumMstPorts-1:0] WideConnectivity = '1;


  addr_t [NrS1Quadrants-1:0] s1_quadrant_base_addr;
  for (genvar i = 0; i < NrS1Quadrants; i++) begin : gen_s1_quadrant_base_addr
    assign s1_quadrant_base_addr[i] = ClusterBaseOffset +
              i * S1QuadrantAddressSpace;
  end

  xbar_rule_t [NrS1Quadrants-1:0] wide_addr_map;
  // Generate address map based on `tile_id`.
  for (genvar i = 0; i < NrS1Quadrants; i++) begin : gen_wide_addr_map
    assign wide_addr_map[i] = '{
      idx: i,
      start_addr: s1_quadrant_base_addr[i],
      end_addr: s1_quadrant_base_addr[i] + S1QuadrantAddressSpace
    };
  end

  // The last master is the default port.
  logic [WideNumSlvPorts-1:0][$clog2(WideNumMstPorts)-1:0] wide_default_port;
  for (genvar i = 0; i < WideNumSlvPorts; i++) assign wide_default_port[i] = WideNumMstPorts - 1;

  /// Wide crossbar.
  axi_xp #(
    .NumSlvPorts (WideNumSlvPorts),
    .NumMstPorts (WideNumMstPorts),
    .Connectivity (WideConnectivity),
    .AxiAddrWidth (AddrWidth),
    .AxiDataWidth (WideDataWidth),
    .AxiIdWidth (WideIdWidth),
    .AxiUserWidth (UserWidth),
    // Check with specification of upstream modules.
    .AxiSlvPortMaxUniqIds (4),
    .AxiSlvPortMaxWriteTxns (16),
    .AxiMaxTxnsPerId (16),
    .NumAddrRules (NrS1Quadrants),
    .slv_req_t (axi_wide_req_t),
    .slv_resp_t (axi_wide_resp_t),
    .mst_req_t (axi_wide_req_t),
    .mst_resp_t (axi_wide_resp_t),
    .rule_t (xbar_rule_t)
  ) i_axi_xp_wide (
    .clk_i (clk_i),
    .rst_ni (rst_ni),
    .test_en_i (1'b0),
    .slv_req_i ({pcie_i.pcie_in_req, axi_narrow_to_wide_req, quadrant_out_wide_out_req}),
    .slv_resp_o ({pcie_o.pcie_in_rsp, axi_narrow_to_wide_rsp, quadrant_in_wide_out_rsp}),
    .mst_req_o ({pcie_o.pcie_out_req, quadrant_in_wide_in_req}),
    .mst_resp_i ({pcie_i.pcie_out_rsp, quadrant_out_wide_in_rsp}),
    .addr_map_i (wide_addr_map),
    .en_default_mst_port_i ('1),
    .default_mst_port_i (wide_default_port)
  );

  axi_narrow_wide_id_req_t axi_narrow_wide_id_req;
  axi_narrow_wide_id_resp_t axi_narrow_wide_id_rsp;

  axi_dw_upsizer #(
    .AxiMaxReads (4),
    .AxiSlvPortDataWidth (NarrowDataWidth),
    .AxiMstPortDataWidth (WideDataWidth),
    .AxiAddrWidth (AddrWidth),
    .AxiIdWidth (WideIdWidth),
    .aw_chan_t (axi_wide_aw_chan_t),
    .mst_w_chan_t (axi_wide_w_chan_t),
    .slv_w_chan_t (axi_narrow_wide_id_w_chan_t),
    .b_chan_t (axi_wide_b_chan_t),
    .ar_chan_t (axi_wide_ar_chan_t),
    .mst_r_chan_t (axi_wide_r_chan_t),
    .slv_r_chan_t (axi_narrow_wide_id_r_chan_t),
    .axi_mst_req_t (axi_wide_req_t),
    .axi_mst_resp_t (axi_wide_resp_t),
    .axi_slv_req_t (axi_narrow_wide_id_req_t),
    .axi_slv_resp_t (axi_narrow_wide_id_resp_t)
  ) i_axi_dw_upsizer (
    .clk_i (clk_i),
    .rst_ni (rst_ni),
    .slv_req_i (axi_narrow_wide_id_req),
    .slv_resp_o (axi_narrow_wide_id_rsp),
    .mst_req_o (axi_narrow_to_wide_req),
    .mst_resp_i (axi_narrow_to_wide_rsp)
  );

  axi_id_remap #(
    .AxiSlvPortIdWidth (NarrowIdWidth),
    .AxiSlvPortMaxUniqIds (2),
    .AxiMaxTxnsPerId (2),
    .AxiMstPortIdWidth (WideIdWidth),
    .slv_req_t (axi_narrow_req_t),
    .slv_resp_t (axi_narrow_resp_t),
    .mst_req_t (axi_narrow_wide_id_req_t),
    .mst_resp_t (axi_narrow_wide_id_resp_t)
  ) i_axi_id_remap (
    .clk_i (clk_i),
    .rst_ni (rst_ni),
    .slv_req_i (axi_narrow_to_wide_id_remap_req),
    .slv_resp_o (axi_narrow_to_wide_id_remap_rsp),
    .mst_req_o (axi_narrow_wide_id_req),
    .mst_resp_i (axi_narrow_wide_id_rsp)
  );

  localparam int unsigned NarrowNumMstPorts = NrS1Quadrants + 1;
  localparam int unsigned NarrowNumSlvPorts = NrS1Quadrants;
  localparam bit [NarrowNumSlvPorts-1:0][NarrowNumMstPorts-1:0] NarrowConnectivity = '1;

  xbar_rule_t [NrS1Quadrants-1:0] narrow_addr_map;
  // Generate address map based on `tile_id`.
  for (genvar i = 0; i < NrS1Quadrants; i++) begin : gen_narrow_addr_map
    assign narrow_addr_map[i] = '{
      idx: i,
      start_addr: s1_quadrant_base_addr[i],
      end_addr: s1_quadrant_base_addr[i] + S1QuadrantAddressSpace
    };
  end

  // The last master is the default port.
  logic [NarrowNumSlvPorts-1:0][$clog2(NarrowNumMstPorts)-1:0] narrow_default_port;
  for (genvar i = 0; i < NarrowNumSlvPorts; i++) begin : gen_narrow_default_port
    assign narrow_default_port[i] = NarrowNumMstPorts - 1;
  end

  /// Narrow crossbar.
  axi_xp #(
    .NumSlvPorts (NarrowNumSlvPorts),
    .NumMstPorts (NarrowNumMstPorts),
    .Connectivity (NarrowConnectivity),
    .AxiAddrWidth (AddrWidth),
    .AxiDataWidth (NarrowDataWidth),
    .AxiIdWidth (NarrowIdWidth),
    .AxiUserWidth (UserWidth),
    // Check with specification of upstream modules.
    .AxiSlvPortMaxUniqIds (4),
    .AxiSlvPortMaxWriteTxns (16),
    .AxiMaxTxnsPerId (16),
    .NumAddrRules (NrS1Quadrants),
    .slv_req_t (axi_narrow_req_t),
    .slv_resp_t (axi_narrow_resp_t),
    .mst_req_t (axi_narrow_req_t),
    .mst_resp_t (axi_narrow_resp_t),
    .rule_t (xbar_rule_t)
  ) i_axi_xp_narrow_quadrant_s1 (
    .clk_i (clk_i),
    .rst_ni (rst_ni),
    .test_en_i (1'b0),
    .slv_req_i ({quadrant_out_narrow_out_req}),
    .slv_resp_o ({quadrant_in_narrow_out_rsp}),
    .mst_req_o ({axi_narrow_to_wide_id_remap_req, quadrant_in_narrow_in_req}),
    .mst_resp_i ({axi_narrow_to_wide_id_remap_rsp, quadrant_out_narrow_in_rsp}),
    .addr_map_i (narrow_addr_map),
    .en_default_mst_port_i ('1),
    .default_mst_port_i (narrow_default_port)
  );

  // Instantiate compute tiles.
  for (genvar i = 0; i < NrS1Quadrants; i++) begin : gen_s1_quadrants
    occamy_quadrant_s1 i_occamy_quadrant_s1 (
      .clk_i (clk_i),
      .rst_ni (rst_ni),
      .tile_id_i (i[5:0]),
      .debug_req_i ('0),
      .meip_i ('0),
      .mtip_i ('0),
      .msip_i ('0),
      .quadrant_i (quadrant_in[i]),
      .quadrant_o (quadrant_out[i])
    );
  end

endmodule
