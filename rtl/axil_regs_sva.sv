// -----------------------------------------------------------------------------
// 模块名   : axil_regs_sva
// 功能     : axil_regs 的 SVA 断言集合,通过 bind 挂接,不侵入 RTL
// 约定     : 每条断言注释对应设计文档/验证方案中的 check 点编号 Cxx
// 说明     : assume 描述 AXI 主机义务(valid 握手前保持),仿真中按 assert 检查
// 命名     : 本模块端口全部为输入,按 rtl-style N-5 统一以 _i 结尾(取被观测信号
//            去掉方向后缀后的基名 + _i),bind 处用命名端口逐一连接(F-5)
// 作者/日期: rtl-gen / 2026-11-25
// -----------------------------------------------------------------------------
module axil_regs_sva #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 6,
    parameter int NUM_REGS   = 16
) (
    input logic                            clk_i,
    input logic                            rst_n_i,

    // 被观测的 AXI4-Lite 端口
    input logic [ADDR_WIDTH-1:0]           s_axi_awaddr_i,
    input logic                            s_axi_awvalid_i,
    input logic                            s_axi_awready_i,
    input logic [DATA_WIDTH-1:0]           s_axi_wdata_i,
    input logic [DATA_WIDTH/8-1:0]         s_axi_wstrb_i,
    input logic                            s_axi_wvalid_i,
    input logic                            s_axi_wready_i,
    input logic [1:0]                      s_axi_bresp_i,
    input logic                            s_axi_bvalid_i,
    input logic                            s_axi_bready_i,
    input logic [ADDR_WIDTH-1:0]           s_axi_araddr_i,
    input logic                            s_axi_arvalid_i,
    input logic                            s_axi_arready_i,
    input logic [DATA_WIDTH-1:0]           s_axi_rdata_i,
    input logic [1:0]                      s_axi_rresp_i,
    input logic                            s_axi_rvalid_i,
    input logic                            s_axi_rready_i,

    // 被观测的寄存器输出与内部信号
    input logic [NUM_REGS*DATA_WIDTH-1:0]  reg_q_i,
    input logic                            wr_fire_i,
    input logic                            wr_oob_i,
    input logic [ADDR_WIDTH-3:0]           wr_idx_i,
    input logic                            rd_fire_i,
    input logic                            rd_oob_i
);

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // 主机义务:valid 握手前保持,地址/数据/strobe 稳定(C05 依赖)
    asm_aw_hold: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_awvalid_i && !s_axi_awready_i |=> s_axi_awvalid_i && $stable(s_axi_awaddr_i));
    asm_w_hold: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_wvalid_i && !s_axi_wready_i |=>
        s_axi_wvalid_i && $stable(s_axi_wdata_i) && $stable(s_axi_wstrb_i));
    asm_ar_hold: assume property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_arvalid_i && !s_axi_arready_i |=> s_axi_arvalid_i && $stable(s_axi_araddr_i));

    // C01:AW/W 共用同一个 ready
    a_c01: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_awready_i == s_axi_wready_i) else $error("C01 awready != wready");

    // C02:B 通道背压期间 bvalid 保持、bresp 稳定
    a_c02: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_bvalid_i && !s_axi_bready_i |=> s_axi_bvalid_i && $stable(s_axi_bresp_i))
        else $error("C02 B channel not held under backpressure");

    // C03:R 通道背压期间 rvalid 保持、rdata/rresp 稳定
    a_c03: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_rvalid_i && !s_axi_rready_i |=>
        s_axi_rvalid_i && $stable(s_axi_rdata_i) && $stable(s_axi_rresp_i))
        else $error("C03 R channel not held under backpressure");

    // C04:挂起响应时不再接收新请求,ready 与 valid 互斥
    a_c04_w: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        !(s_axi_awready_i && s_axi_bvalid_i)) else $error("C04 awready with bvalid");
    a_c04_r: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        !(s_axi_arready_i && s_axi_rvalid_i)) else $error("C04 arready with rvalid");

    // C05:ready 只在请求有效时出现(依赖主机 valid 保持假设)
    a_c05_w: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_awready_i |-> s_axi_awvalid_i && s_axi_wvalid_i)
        else $error("C05 awready without request");
    a_c05_r: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_arready_i |-> s_axi_arvalid_i) else $error("C05 arready without request");

    // C06:复位期间所有握手输出为 0(异步复位,时钟沿采样时已生效)
    a_c06: assert property (@(posedge clk_i)
        !rst_n_i |-> !s_axi_awready_i && !s_axi_wready_i && !s_axi_bvalid_i &&
                     !s_axi_arready_i && !s_axi_rvalid_i)
        else $error("C06 outputs not cleared in reset");

    // C07:响应码只能是 OKAY 或 SLVERR
    a_c07_b: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_bvalid_i |-> s_axi_bresp_i inside {RESP_OKAY, RESP_SLVERR})
        else $error("C07 illegal bresp");
    a_c07_r: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_rvalid_i |-> s_axi_rresp_i inside {RESP_OKAY, RESP_SLVERR})
        else $error("C07 illegal rresp");

    // C08:有效写握手后,wstrb 置位的字节在下一拍更新为写入数据
    for (genvar b = 0; b < DATA_WIDTH/8; b++) begin : g_c08
        a_c08: assert property (@(posedge clk_i) disable iff (!rst_n_i)
            wr_fire_i && !wr_oob_i && s_axi_wstrb_i[b] |=>
            reg_q_i[$past(wr_idx_i)*DATA_WIDTH + 8*b +: 8] == $past(s_axi_wdata_i[8*b +: 8]))
            else $error("C08 byte %0d not written", b);
    end

    // C09:越界写/读返回 SLVERR,越界读数据为 0
    a_c09_w: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        wr_fire_i && wr_oob_i |=> s_axi_bvalid_i && s_axi_bresp_i == RESP_SLVERR)
        else $error("C09 oob write resp");
    a_c09_r: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        rd_fire_i && rd_oob_i |=>
        s_axi_rvalid_i && s_axi_rresp_i == RESP_SLVERR && s_axi_rdata_i == '0)
        else $error("C09 oob read resp");

    // C10:没有有效写握手时寄存器内容不变
    a_c10: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        reg_q_i != $past(reg_q_i) |-> $past(wr_fire_i && !wr_oob_i))
        else $error("C10 reg changed without write");

    // C11:复位释放后输出无 X
    a_c11: assert property (@(posedge clk_i) disable iff (!rst_n_i)
        !$isunknown({s_axi_awready_i, s_axi_wready_i, s_axi_bvalid_i, s_axi_bresp_i,
                     s_axi_arready_i, s_axi_rvalid_i, s_axi_rresp_i, reg_q_i}))
        else $error("C11 X on outputs");

    // cover:供覆盖率收集
    c_wr_ok:   cover property (@(posedge clk_i) disable iff (!rst_n_i)
        wr_fire_i && !wr_oob_i);
    c_wr_oob:  cover property (@(posedge clk_i) disable iff (!rst_n_i)
        wr_fire_i && wr_oob_i);
    c_rd_ok:   cover property (@(posedge clk_i) disable iff (!rst_n_i)
        rd_fire_i && !rd_oob_i);
    c_rd_oob:  cover property (@(posedge clk_i) disable iff (!rst_n_i)
        rd_fire_i && rd_oob_i);
    c_b_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_bvalid_i && !s_axi_bready_i);
    c_r_stall: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        s_axi_rvalid_i && !s_axi_rready_i);
    c_wr_part: cover property (@(posedge clk_i) disable iff (!rst_n_i)
        wr_fire_i && (s_axi_wstrb_i != '1) && (s_axi_wstrb_i != '0));

endmodule

// 挂接:checker 端口名与 DUT 信号名不同(N-5),不能用 .*,逐一命名连接(F-5)
bind axil_regs axil_regs_sva #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .NUM_REGS   (NUM_REGS)
) sva_inst (
    .clk_i           (clk_i),
    .rst_n_i         (rst_n_i),
    .s_axi_awaddr_i  (s_axi_awaddr_i),
    .s_axi_awvalid_i (s_axi_awvalid_i),
    .s_axi_awready_i (s_axi_awready_o),
    .s_axi_wdata_i   (s_axi_wdata_i),
    .s_axi_wstrb_i   (s_axi_wstrb_i),
    .s_axi_wvalid_i  (s_axi_wvalid_i),
    .s_axi_wready_i  (s_axi_wready_o),
    .s_axi_bresp_i   (s_axi_bresp_o),
    .s_axi_bvalid_i  (s_axi_bvalid_o),
    .s_axi_bready_i  (s_axi_bready_i),
    .s_axi_araddr_i  (s_axi_araddr_i),
    .s_axi_arvalid_i (s_axi_arvalid_i),
    .s_axi_arready_i (s_axi_arready_o),
    .s_axi_rdata_i   (s_axi_rdata_o),
    .s_axi_rresp_i   (s_axi_rresp_o),
    .s_axi_rvalid_i  (s_axi_rvalid_o),
    .s_axi_rready_i  (s_axi_rready_i),
    .reg_q_i         (reg_q_o),
    .wr_fire_i       (wr_fire),
    .wr_oob_i        (wr_oob),
    .wr_idx_i        (wr_idx),
    .rd_fire_i       (rd_fire),
    .rd_oob_i        (rd_oob)
);
