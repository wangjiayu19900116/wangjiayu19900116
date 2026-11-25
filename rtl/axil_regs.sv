// -----------------------------------------------------------------------------
// 模块名   : axil_regs
// 功能     : AXI4-Lite slave 通用寄存器读写模块,寄存器值以扁平总线输出
// 参数     : DATA_WIDTH(仅支持 32) / ADDR_WIDTH(字节地址位宽) / NUM_REGS / RESET_VAL
// 时钟复位 : 单时钟 clk 上升沿;rst_n 异步低有效复位,同步释放由外部保证
// Latency  : 写 2 拍到 BVALID,读 2 拍到 RVALID(自请求有效起算,对端 ready 已就绪)
// 作者/日期: rtl-gen / 2026-11-25
// -----------------------------------------------------------------------------
module axil_regs #(
    parameter int                    DATA_WIDTH = 32,
    parameter int                    ADDR_WIDTH = 6,
    parameter int                    NUM_REGS   = 16,
    parameter logic [DATA_WIDTH-1:0] RESET_VAL  = '0
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // AXI4-Lite 写地址通道
    input  logic [ADDR_WIDTH-1:0]         s_axi_awaddr,
    input  logic [2:0]                    s_axi_awprot,
    input  logic                          s_axi_awvalid,
    output logic                          s_axi_awready,
    // AXI4-Lite 写数据通道
    input  logic [DATA_WIDTH-1:0]         s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0]       s_axi_wstrb,
    input  logic                          s_axi_wvalid,
    output logic                          s_axi_wready,
    // AXI4-Lite 写响应通道
    output logic [1:0]                    s_axi_bresp,
    output logic                          s_axi_bvalid,
    input  logic                          s_axi_bready,

    // AXI4-Lite 读地址通道
    input  logic [ADDR_WIDTH-1:0]         s_axi_araddr,
    input  logic [2:0]                    s_axi_arprot,
    input  logic                          s_axi_arvalid,
    output logic                          s_axi_arready,
    // AXI4-Lite 读数据通道
    output logic [DATA_WIDTH-1:0]         s_axi_rdata,
    output logic [1:0]                    s_axi_rresp,
    output logic                          s_axi_rvalid,
    input  logic                          s_axi_rready,

    // 寄存器值输出,第 i 个寄存器位于 [i*DATA_WIDTH +: DATA_WIDTH]
    output logic [NUM_REGS*DATA_WIDTH-1:0] reg_q_o
);

    localparam int          STRB_W      = DATA_WIDTH / 8;
    localparam int          IDX_W       = ADDR_WIDTH - 2;  // 字地址位宽,低 2 位忽略
    localparam logic [1:0]  RESP_OKAY   = 2'b00;
    localparam logic [1:0]  RESP_SLVERR = 2'b10;

    logic [DATA_WIDTH-1:0] reg_q [NUM_REGS];

    logic                  wr_ready_q;
    logic                  wr_ready_d;
    logic                  bvalid_q;
    logic [1:0]            bresp_q;
    logic                  wr_req;
    logic                  wr_fire;
    logic [IDX_W-1:0]      wr_idx;
    logic                  wr_oob;

    logic                  arready_q;
    logic                  arready_d;
    logic                  rvalid_q;
    logic [DATA_WIDTH-1:0] rdata_q;
    logic [1:0]            rresp_q;
    logic                  rd_fire;
    logic [IDX_W-1:0]      rd_idx;
    logic                  rd_oob;

    logic                  unused_ok;

    // 组合逻辑:写通道请求、握手与地址译码
    assign wr_req     = s_axi_awvalid & s_axi_wvalid;
    assign wr_fire    = wr_req & wr_ready_q;
    // 仅在无挂起响应、且 ready 尚未拉高时发起,保证 ready 只高一拍
    assign wr_ready_d = wr_req & ~bvalid_q & ~wr_ready_q;
    assign wr_idx     = s_axi_awaddr[ADDR_WIDTH-1:2];
    assign wr_oob     = (int'(wr_idx) >= NUM_REGS);

    // 组合逻辑:读通道握手与地址译码
    assign rd_fire    = s_axi_arvalid & arready_q;
    assign arready_d  = s_axi_arvalid & ~rvalid_q & ~arready_q;
    assign rd_idx     = s_axi_araddr[ADDR_WIDTH-1:2];
    assign rd_oob     = (int'(rd_idx) >= NUM_REGS);

    // 时序逻辑:写握手与写响应(valid/ready 相互独立,bvalid 不依赖 bready)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ready_q <= 1'b0;
            bvalid_q   <= 1'b0;
            bresp_q    <= RESP_OKAY;
        end else begin
            wr_ready_q <= wr_ready_d;
            if (wr_fire) begin
                bvalid_q <= 1'b1;
                bresp_q  <= wr_oob ? RESP_SLVERR : RESP_OKAY;
            end else if (bvalid_q && s_axi_bready) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    // 时序逻辑:寄存器阵列写入,按 wstrb 逐字节更新;越界写丢弃,wstrb 全 0 不改写
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_REGS; i++) begin
                reg_q[i] <= RESET_VAL;
            end
        end else if (wr_fire && !wr_oob) begin
            for (int b = 0; b < STRB_W; b++) begin
                if (s_axi_wstrb[b]) begin
                    reg_q[wr_idx][8*b +: 8] <= s_axi_wdata[8*b +: 8];
                end
            end
        end
    end

    // 时序逻辑:读握手与读数据,握手拍锁存寄存器旧值;越界读返回 0 并报 SLVERR
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready_q <= 1'b0;
            rvalid_q  <= 1'b0;
            rdata_q   <= '0;
            rresp_q   <= RESP_OKAY;
        end else begin
            arready_q <= arready_d;
            if (rd_fire) begin
                rvalid_q <= 1'b1;
                rdata_q  <= rd_oob ? '0 : reg_q[rd_idx];
                rresp_q  <= rd_oob ? RESP_SLVERR : RESP_OKAY;
            end else if (rvalid_q && s_axi_rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    // 输出连接:全部由寄存器直出
    assign s_axi_awready = wr_ready_q;
    assign s_axi_wready  = wr_ready_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bresp   = bresp_q;
    assign s_axi_arready = arready_q;
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rdata   = rdata_q;
    assign s_axi_rresp   = rresp_q;

    // 寄存器阵列打平为总线输出
    for (genvar g = 0; g < NUM_REGS; g++) begin : g_reg_out
        assign reg_q_o[g*DATA_WIDTH +: DATA_WIDTH] = reg_q[g];
    end

    // 未使用信号:awprot/arprot 不区分访问属性,地址低 2 位按字对齐忽略
    assign unused_ok = &{1'b0, s_axi_awprot, s_axi_arprot, s_axi_awaddr[1:0], s_axi_araddr[1:0]};

endmodule
