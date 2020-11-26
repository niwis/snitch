// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Thomas Benz <tbenz@ethz.ch>

// Implements the tightly-coupled frontend. This module can directly be connected
// to an accelerator bus in the snitch system

module axi_dma_tc_snitch_fe #(
    parameter type         axi_req_t          = logic,
    parameter type         axi_res_t          = logic
) (
    input  logic           clk_i,
    input  logic           rst_ni,
    // AXI4 bus
    output axi_req_t       axi_dma_req_o,
    input  axi_res_t       axi_dma_res_i,
    // debug output
    output logic           dma_busy_o,
    // accelerator interface
    input  logic [31:0]       acc_qaddr_i,
    input  logic [ 4:0]       acc_qid_i,
    input  logic [31:0]       acc_qdata_op_i,
    input  snitch_pkg::data_t acc_qdata_arga_i,
    input  snitch_pkg::data_t acc_qdata_argb_i,
    input  snitch_pkg::addr_t acc_qdata_argc_i,
    input  logic              acc_qvalid_i,
    output logic              acc_qready_o,

    output snitch_pkg::data_t acc_pdata_o,
    output logic [ 4:0]       acc_pid_o,
    output logic              acc_perror_o,
    output logic              acc_pvalid_o,
    input  logic              acc_pready_i,

    // hart id of the frankensnitch
    input  logic [31:0]       hart_id_i,

    // performance output
    output axi_dma_pkg::dma_perf_t dma_perf_o
);

    //--------------------------------------
    // Backend Instanciation
    //--------------------------------------
    logic                    backend_idle;
    logic                    trans_complete;
    axi_dma_pkg::burst_req_t burst_req;
    logic                    burst_req_valid;
    logic                    burst_req_ready;
    logic                    oned_trans_complete;

    axi_dma_backend #(
        .DataWidth       ( snitch_axi_pkg::DMADataWidth       ),
        .AddrWidth       ( snitch_axi_pkg::DMAAddrWidth       ),
        .IdWidth         ( snitch_pkg::IdWidthDma             ),
        .AxReqFifoDepth  ( snitch_pkg::DMA_AXI_REQ_FIFO_DEPTH ),
        .TransFifoDepth  ( snitch_pkg::DMA_REQ_FIFO_DEPTH     ),
        .BufferDepth     ( 3                                  ),
        .axi_req_t       ( axi_req_t                          ),
        .axi_res_t       ( axi_res_t                          ),
        .burst_req_t     ( axi_dma_pkg::burst_req_t           ),
        .DmaIdWidth      ( 32                                 ),
        .DmaTracing      ( 1                                  )
    ) i_axi_dma_backend (
        .clk_i            ( clk_i               ),
        .rst_ni           ( rst_ni              ),
        .axi_dma_req_o    ( axi_dma_req_o       ),
        .axi_dma_res_i    ( axi_dma_res_i       ),
        .burst_req_i      ( burst_req           ),
        .valid_i          ( burst_req_valid     ),
        .ready_o          ( burst_req_ready     ),
        .backend_idle_o   ( backend_idle        ),
        .trans_complete_o ( oned_trans_complete ),
        .dma_id_i         ( hart_id_i           )
    );

    //--------------------------------------
    // 2D Extension
    //--------------------------------------
    axi_dma_pkg::twod_req_t twod_req_d, twod_req_q;
    logic                   twod_req_valid;
    logic                   twod_req_ready;
    logic                   twod_req_last;

    axi_dma_twod_ext #(
        .ADDR_WIDTH       ( snitch_axi_pkg::DMAAddrWidth   ),
        .REQ_FIFO_DEPTH   ( snitch_pkg::DMA_REQ_FIFO_DEPTH )
    ) i_axi_dma_twod_ext (
        .clk_i                ( clk_i           ),
        .rst_ni               ( rst_ni          ),
        .twod_req_i           ( twod_req_d      ),
        .twod_req_valid_i     ( twod_req_valid  ),
        .twod_req_ready_o     ( twod_req_ready  ),
        .burst_req_o          ( burst_req       ),
        .burst_req_valid_o    ( burst_req_valid ),
        .burst_req_ready_i    ( burst_req_ready ),
        .twod_req_last_o      ( twod_req_last   )
    );

    //--------------------------------------
    // Buffer twod last
    //--------------------------------------
    localparam int unsigned TwodBufferDepth = 2 * snitch_pkg::DMA_REQ_FIFO_DEPTH +
        snitch_pkg::DMA_AXI_REQ_FIFO_DEPTH + 3 + 1;
    logic twod_req_last_realigned;
    fifo_v3 # (
        .DATA_WIDTH  (  1                 ),
        .DEPTH       ( TwodBufferDepth  )
    ) i_fifo_v3_last_twod_buffer (
        .clk_i       ( clk_i                             ),
        .rst_ni      ( rst_ni                            ),
        .flush_i     ( 1'b0                              ),
        .testmode_i  ( 1'b0                              ),
        .full_o      ( ),
        .empty_o     ( ),
        .usage_o     ( ),
        .data_i      ( twod_req_last                     ),
        .push_i      ( burst_req_valid & burst_req_ready ),
        .data_o      ( twod_req_last_realigned           ),
        .pop_i       ( oned_trans_complete               )
    );

    //--------------------------------------
    // ID gen
    //--------------------------------------
    logic [31:0] next_id;
    logic [31:0] completed_id;

    axi_dma_tc_snitch_fe_id_gen #(
        .ID_WIDTH     ( 32     )
    ) i_axi_dma_tc_snitch_fe_id_gen (
        .clk_i        ( clk_i                                          ),
        .rst_ni       ( rst_ni                                         ),
        .issue_i      ( twod_req_valid && twod_req_ready               ),
        .retire_i     ( oned_trans_complete && twod_req_last_realigned ),
        .next_o       ( next_id                                        ),
        .completed_o  ( completed_id                                   )
    );

    // dma is busy when it is not idle
    assign dma_busy_o = next_id != completed_id;

    //--------------------------------------
    // Performance counters
    //--------------------------------------
    axi_dma_perf_counters #(
        .TRANSFER_ID_WIDTH  ( 32           ),
        .DATA_WIDTH         ( snitch_axi_pkg::DMADataWidth ),
        .axi_req_t          ( axi_req_t    ),
        .axi_res_t          ( axi_res_t    )
    ) i_axi_dma_perf_counters (
        .clk_i           ( clk_i               ),
        .rst_ni          ( rst_ni              ),
        .axi_dma_req_i   ( axi_dma_req_o       ),
        .axi_dma_res_i   ( axi_dma_res_i       ),
        .next_id_i       ( next_id             ),
        .completed_id_i  ( completed_id        ),
        .dma_busy_i      ( dma_busy_o          ),
        .dma_perf_o      ( dma_perf_o          )
    );

    //--------------------------------------
    // Spill register for response channel
    //--------------------------------------
    snitch_pkg::acc_resp_t acc_pdata_spill, acc_pdata;
    logic acc_pvalid_spill;
    logic acc_pready_spill;

    // the response path needs to be decoupled
    spill_register #(
        .T            ( snitch_pkg::acc_resp_t )
    ) i_spill_register_dma_resp (
        .clk_i        ( clk_i            ),
        .rst_ni       ( rst_ni           ),
        .valid_i      ( acc_pvalid_spill ),
        .ready_o      ( acc_pready_spill ),
        .data_i       ( acc_pdata_spill   ),
        .valid_o      ( acc_pvalid_o     ),
        .ready_i      ( acc_pready_i     ),
        .data_o       ( acc_pdata         )
    );

    assign acc_pdata_o  = acc_pdata.data;
    assign acc_pid_o    = acc_pdata.id;
    assign acc_perror_o = acc_pdata.error;

    //--------------------------------------
    // Instruction decode
    //--------------------------------------
    logic            is_dma_op;
    logic [12*8-1:0] dma_op_name;

    always_comb begin : proc_fe_inst_decode
        twod_req_d            = twod_req_q;
        twod_req_d.burst_src  = axi_pkg::BURST_INCR;
        twod_req_d.burst_dst  = axi_pkg::BURST_INCR;
        twod_req_valid        = 1'b0;
        acc_qready_o          = 1'b0;
        acc_pdata_spill       = '0;
        acc_pdata_spill.error = 1'b1;
        acc_pvalid_spill      = 1'b0;

        // debug signal
        is_dma_op        = 1'b0;
        dma_op_name      = "Invalid";

        // decode
        if (acc_qvalid_i == 1'b1) unique casez (acc_qdata_op_i)

            // manipulate the source register
            riscv_instr::DMSRC : begin
                twod_req_d.src[31: 0] = acc_qdata_arga_i[31:0];
                twod_req_d.src[snitch_pkg::PLEN-1:32] = acc_qdata_argb_i[snitch_pkg::PLEN-1-32: 0];
                acc_qready_o = 1'b1;
                is_dma_op    = 1'b1;
                dma_op_name  = "DMSRC";
            end

            // manipulate the destination register
            riscv_instr::DMDST : begin
                twod_req_d.dst[31: 0] = acc_qdata_arga_i[31:0];
                twod_req_d.dst[snitch_pkg::PLEN-1:32] = acc_qdata_argb_i[snitch_pkg::PLEN-1-32: 0];
                acc_qready_o = 1'b1;
                is_dma_op    = 1'b1;
                dma_op_name  = "DMDST";
            end

            // start the DMA
            riscv_instr::DMCPYI,
            riscv_instr::DMCPY : begin
                automatic logic [1:0] cfg;

                // Parse the transfer parameters from the register or immediate.
                unique casez (acc_qdata_op_i)
                    riscv_instr::DMCPYI : cfg = acc_qdata_op_i[24:20];
                    riscv_instr::DMCPY :  cfg = acc_qdata_argb_i;
                    default:;
                endcase
                dma_op_name = "DMCPY";
                is_dma_op   = 1'b1;

                twod_req_d.num_bytes   = acc_qdata_arga_i;
                twod_req_d.decouple_rw = cfg[0];
                twod_req_d.is_twod     = cfg[1];

                // Perform the following sequence:
                // 1. wait for acc response channel to be ready (pready)
                // 2. request twod transfer (valid)
                // 3. wait for twod transfer to be accepted (ready)
                // 4. send acc response (pvalid)
                // 5. acknowledge acc request (qready)
                if (acc_pready_spill) begin
                    twod_req_valid = 1'b1;
                    if (twod_req_ready) begin
                        acc_pdata_spill.id    = acc_qid_i;
                        acc_pdata_spill.data  = next_id;
                        acc_pdata_spill.error = 1'b0;
                        acc_pvalid_spill      = 1'b1;
                        acc_qready_o          = twod_req_ready;
                    end
                end
            end

            // status of the DMA
            riscv_instr::DMSTATI,
            riscv_instr::DMSTAT : begin
                automatic logic [1:0] status;

                // Parse the status index from the register or immediate.
                unique casez (acc_qdata_op_i)
                    riscv_instr::DMSTATI : status = acc_qdata_op_i[24:20];
                    riscv_instr::DMSTAT :  status = acc_qdata_argb_i;
                    default:;
                endcase
                dma_op_name = "DMSTAT";
                is_dma_op   = 1'b1;

                // Compose the response.
                acc_pdata_spill.id    = acc_qid_i;
                acc_pdata_spill.error = 1'b0;
                case (status)
                    2'b00 : acc_pdata_spill.data = completed_id;
                    2'b01 : acc_pdata_spill.data = next_id;
                    2'b10 : acc_pdata_spill.data = {{{8'd63}{1'b0}}, dma_busy_o};
                    2'b11 : acc_pdata_spill.data = {{{8'd63}{1'b0}}, !twod_req_ready};
                    default:;
                endcase

                // Wait for acc response channel to become ready, then ack the
                // request.
                if (acc_pready_spill) begin
                    acc_pvalid_spill = 1'b1;
                    acc_qready_o     = 1'b1;
                end
            end

            // manipulate the strides
            riscv_instr::DMSTR : begin
                twod_req_d.stride_src = acc_qdata_arga_i;
                twod_req_d.stride_dst = acc_qdata_argb_i;
                acc_qready_o = 1'b1;
                is_dma_op    = 1'b1;
                dma_op_name  = "DMSTR";
            end

            // manipulate the strides
            riscv_instr::DMREP : begin
                twod_req_d.num_repetitions = acc_qdata_arga_i;
                acc_qready_o = 1'b1;
                is_dma_op    = 1'b1;
                dma_op_name  = "DMREP";
            end

            default:;
        endcase
    end

    //--------------------------------------
    // State
    //--------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin : proc_modifiable_request
        if(!rst_ni) begin
            twod_req_q <= '0;
        end else begin
            twod_req_q <= twod_req_d;
        end
    end

endmodule : axi_dma_tc_snitch_fe
