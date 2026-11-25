// -----------------------------------------------------------------------------
// 模块名   : axil_regs_sva
// 功能     : axil_regs 的 SVA 断言集合,通过 bind 挂接,不侵入 RTL
// 约定     : 每条断言注释对应设计文档/验证方案中的 check 点编号 Cxx
// 说明     : assume 描述 AXI 主机义务(valid 握手前保持),仿真中按 assert 检查
// -----------------------------------------------------------------------------
module axil_regs_sva #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 6,
    parameter int NUM_REGS   = 16
) (
    input logic                            clk,
    input logic                            rst_n,
    input logic [ADDR_WIDTH-1:0]           s_axi_awaddr,
    input logic                            s_axi_awvalid,
    input logic                            s_axi_awready,
    input logic [DATA_WIDTH-1:0]           s_axi_wdata,
    input logic [DATA_WIDTH/8-1:0]         s_axi_wstrb,
    input logic                            s_axi_wvalid,
    input logic                            s_axi_wready,
    input logic [1:0]                      s_axi_bresp,
    input logic                            s_axi_bvalid,
    input logic                            s_axi_bready,
    input logic [ADDR_WIDTH-1:0]           s_axi_araddr,
    input logic                            s_axi_arvalid,
    input logic                            s_axi_arready,
    input logic [DATA_WIDTH-1:0]           s_axi_rdata,
    input logic [1:0]                      s_axi_rresp,
    input logic                            s_axi_rvalid,
    input logic                            s_axi_rready,
    input logic [NUM_REGS*DATA_WIDTH-1:0]  reg_q_o,
    input logic                            wr_fire,
    input logic                            wr_oob,
    input logic [ADDR_WIDTH-3:0]           wr_idx,
    input logic                            rd_fire,
    input logic                            rd_oob
);

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // 主机义务:valid 握手前保持,地址/数据/strobe 稳定(C05 依赖)
    asm_aw_hold: assume property (@(posedge clk) disable iff (!rst_n)
        s_axi_awvalid && !s_axi_awready |=> s_axi_awvalid && $stable(s_axi_awaddr));
    asm_w_hold: assume property (@(posedge clk) disable iff (!rst_n)
        s_axi_wvalid && !s_axi_wready |=> s_axi_wvalid && $stable(s_axi_wdata) && $stable(s_axi_wstrb));
    asm_ar_hold: assume property (@(posedge clk) disable iff (!rst_n)
        s_axi_arvalid && !s_axi_arready |=> s_axi_arvalid && $stable(s_axi_araddr));

    // C01:AW/W 共用同一个 ready
    a_c01: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_awready == s_axi_wready) else $error("C01 awready != wready");

    // C02:B 通道背压期间 bvalid 保持、bresp 稳定
    a_c02: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_bvalid && !s_axi_bready |=> s_axi_bvalid && $stable(s_axi_bresp))
        else $error("C02 B channel not held under backpressure");

    // C03:R 通道背压期间 rvalid 保持、rdata/rresp 稳定
    a_c03: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_rvalid && !s_axi_rready |=> s_axi_rvalid && $stable(s_axi_rdata) && $stable(s_axi_rresp))
        else $error("C03 R channel not held under backpressure");

    // C04:挂起响应时不再接收新请求,ready 与 valid 互斥
    a_c04_w: assert property (@(posedge clk) disable iff (!rst_n)
        !(s_axi_awready && s_axi_bvalid)) else $error("C04 awready with bvalid");
    a_c04_r: assert property (@(posedge clk) disable iff (!rst_n)
        !(s_axi_arready && s_axi_rvalid)) else $error("C04 arready with rvalid");

    // C05:ready 只在请求有效时出现(依赖主机 valid 保持假设)
    a_c05_w: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_awready |-> s_axi_awvalid && s_axi_wvalid) else $error("C05 awready without request");
    a_c05_r: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_arready |-> s_axi_arvalid) else $error("C05 arready without request");

    // C06:复位期间所有握手输出为 0(异步复位,时钟沿采样时已生效)
    a_c06: assert property (@(posedge clk)
        !rst_n |-> !s_axi_awready && !s_axi_wready && !s_axi_bvalid && !s_axi_arready && !s_axi_rvalid)
        else $error("C06 outputs not cleared in reset");

    // C07:响应码只能是 OKAY 或 SLVERR
    a_c07_b: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_bvalid |-> s_axi_bresp inside {RESP_OKAY, RESP_SLVERR}) else $error("C07 illegal bresp");
    a_c07_r: assert property (@(posedge clk) disable iff (!rst_n)
        s_axi_rvalid |-> s_axi_rresp inside {RESP_OKAY, RESP_SLVERR}) else $error("C07 illegal rresp");

    // C08:有效写握手后,wstrb 置位的字节在下一拍更新为写入数据
    for (genvar b = 0; b < DATA_WIDTH/8; b++) begin : g_c08
        a_c08: assert property (@(posedge clk) disable iff (!rst_n)
            wr_fire && !wr_oob && s_axi_wstrb[b] |=>
            reg_q_o[$past(wr_idx)*DATA_WIDTH + 8*b +: 8] == $past(s_axi_wdata[8*b +: 8]))
            else $error("C08 byte %0d not written", b);
    end

    // C09:越界写/读返回 SLVERR,越界读数据为 0
    a_c09_w: assert property (@(posedge clk) disable iff (!rst_n)
        wr_fire && wr_oob |=> s_axi_bvalid && s_axi_bresp == RESP_SLVERR) else $error("C09 oob write resp");
    a_c09_r: assert property (@(posedge clk) disable iff (!rst_n)
        rd_fire && rd_oob |=> s_axi_rvalid && s_axi_rresp == RESP_SLVERR && s_axi_rdata == '0)
        else $error("C09 oob read resp");

    // C10:没有有效写握手时寄存器内容不变
    a_c10: assert property (@(posedge clk) disable iff (!rst_n)
        reg_q_o != $past(reg_q_o) |-> $past(wr_fire && !wr_oob)) else $error("C10 reg changed without write");

    // C11:复位释放后输出无 X
    a_c11: assert property (@(posedge clk) disable iff (!rst_n)
        !$isunknown({s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_bresp,
                     s_axi_arready, s_axi_rvalid, s_axi_rresp, reg_q_o}))
        else $error("C11 X on outputs");

    // cover:供覆盖率收集
    c_wr_ok:    cover property (@(posedge clk) disable iff (!rst_n) wr_fire && !wr_oob);
    c_wr_oob:   cover property (@(posedge clk) disable iff (!rst_n) wr_fire && wr_oob);
    c_rd_ok:    cover property (@(posedge clk) disable iff (!rst_n) rd_fire && !rd_oob);
    c_rd_oob:   cover property (@(posedge clk) disable iff (!rst_n) rd_fire && rd_oob);
    c_b_stall:  cover property (@(posedge clk) disable iff (!rst_n) s_axi_bvalid && !s_axi_bready);
    c_r_stall:  cover property (@(posedge clk) disable iff (!rst_n) s_axi_rvalid && !s_axi_rready);
    c_wr_part:  cover property (@(posedge clk) disable iff (!rst_n) wr_fire && (s_axi_wstrb != '1) && (s_axi_wstrb != '0));

endmodule

bind axil_regs axil_regs_sva #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .NUM_REGS  (NUM_REGS)
) sva_inst (.*);
