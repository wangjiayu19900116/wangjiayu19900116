# axil_regs 验证方案

## 1. 验证目标与通过标准

- 第 4 章定向用例全部通过,随机测试多种子无失败。
- 断言 0 fail,第 5 章 cover property 全部命中。
- 代码覆盖率目标:行覆盖、翻转覆盖 90% 以上。
- 本方案只交付验证计划,不含 TB 实现。lint 和仿真均未执行(当前机器未安装 verilator/iverilog)。

## 2. check 点表

验证手段:A=断言,D=定向用例,R=随机加覆盖。

| 编号 | 类别 | 内容 | 风险 | 手段 |
|---|---|---|---|---|
| C01 | 协议 | awready 与 wready 相等 | AW/W 不同步握手 | A |
| C02 | 协议 | bvalid 在 bready 前保持,bresp 稳定 | 响应丢失或抖动 | A, D |
| C03 | 协议 | rvalid 在 rready 前保持,rdata/rresp 稳定 | 读数据丢失或抖动 | A, D |
| C04 | 协议 | ready 与对应 valid 互斥 | 响应被新请求覆盖 | A |
| C05 | 协议 | ready 只在请求有效时出现 | 无请求误握手 | A |
| C06 | 复位 | 复位期间握手输出为 0 | 复位期间误响应 | A, D |
| C07 | 非法输入 | 响应码只能是 OKAY/SLVERR | 非法 resp 编码 | A |
| C08 | 数据完整性 | 写入按 wstrb 逐字节生效 | 字节使能错位 | A, D, R |
| C09 | 边界 | 越界读写返回 SLVERR,越界读数据为 0 | 越界写污染寄存器 | A, D |
| C10 | 数据完整性 | 无写握手时寄存器不变 | 误写 | A, R |
| C11 | X 态 | 复位释放后输出无 X | X 扩散 | A |
| C12 | 边界 | wstrb 全 0 不改写,响应 OKAY | 误写 | D, R |
| C13 | 协议 | 同拍读写同一寄存器,读到旧值 | 读写冲突行为不明 | D |
| C14 | 协议 | AW、W 不同拍到达,先到者保持等待后完成 | 死锁或丢事务 | D, R |
| C15 | 边界 | 首个和最后一个寄存器,以及 NUM_REGS 为 1、等于 2**(ADDR_WIDTH-2) 的参数退化 | 译码边界错误 | D |
| C16 | 复位 | 事务进行中异步复位后恢复正常 | 状态残留 | D |

## 3. TB 架构

- 激励:AXI4-Lite 主机 BFM,支持独立控制 AW/W/AR 的 valid 延迟,以及 bready/rready 的反压延迟。遵守 valid 握手前保持的主机义务。
- 参考模型:TB 内维护 NUM_REGS 个字的数组,按 wstrb 字节更新;越界写丢弃,读返回 0 并预期 SLVERR。
- Scoreboard:每笔读的 rdata/rresp、每笔写的 bresp 与参考模型比对;测试结束时用 reg_q_o 与参考数组全量比对。
- 监测点:AXI 全部端口、reg_q_o;断言通过 bind 自动挂接。
- 随机测试:读写地址(含越界,约 10% 概率)、wdata、wstrb 随机,延迟 0~7 拍随机;种子由命令行传入,回归至少 20 个种子,失败时打印种子。

## 4. 用例清单

| 用例名 | 对应check点 | 激励要点 | 预期结果 |
|---|---|---|---|
| t_reset_default | C06 C11 | 复位后立即读全部寄存器 | 读值为 RESET_VAL,resp OKAY |
| t_wr_rd_basic | C08 | 逐个寄存器全字写后读回 | 读回等于写入值,resp OKAY |
| t_wstrb_each | C08 | 每个字节单独使能写,再混合使能写 | 仅使能字节被更新 |
| t_wstrb_zero | C12 | wstrb 为 0 的写 | 寄存器不变,bresp OKAY |
| t_oob_write | C09 C10 | 写 NUM_REGS 及更高索引 | bresp SLVERR,全部寄存器不变 |
| t_oob_read | C09 | 读越界地址 | rdata 为 0,rresp SLVERR |
| t_aw_first | C14 | AW 先于 W 若干拍到达 | 正常完成写 |
| t_w_first | C14 | W 先于 AW 若干拍到达 | 正常完成写 |
| t_b_backpressure | C02 C04 | bready 延迟多拍,同时后续写请求保持 | bvalid/bresp 保持,新写等响应结束后才被接收 |
| t_r_backpressure | C03 C04 | rready 延迟多拍 | rvalid/rdata/rresp 保持 |
| t_rw_same_reg | C13 | 同拍对同一寄存器读写 | 读到写入前旧值 |
| t_back2back | C04 | 连续背靠背写、读、读写混合 | 无丢失,顺序正确 |
| t_reset_mid_txn | C16 | 事务中途拉低 rst_n | 握手输出清零,寄存器复位,恢复后事务正常 |
| t_param_corner | C15 | NUM_REGS=1;NUM_REGS=2**(ADDR_WIDTH-2) | 无越界误判,译码正确 |
| t_random | C08 C10 C12 C14 | 第 3 章随机约束,多种子 | scoreboard 0 error,断言 0 fail |

## 5. 覆盖率计划

功能覆盖点(covergroup 建议):

- 寄存器索引:全部索引加越界值。
- wstrb:16 种取值,至少覆盖全 0、全 1、单字节、部分字节。
- 读写延迟:AW/W 到达间隔 0、1、多拍;bready/rready 延迟 0、1、多拍。
- 交叉:读写同拍同索引;背压期间有新请求。

cover property(位于 rtl/axil_regs_sva.sv):c_wr_ok、c_wr_oob、c_rd_ok、c_rd_oob、c_b_stall、c_r_stall、c_wr_part。

## 6. 工具与跑法

- 断言文件在 bind 文件中,编译时与 RTL 一起带上。
- Verilator(推荐):`verilator --lint-only -Wall rtl/axil_regs.sv rtl/axil_regs_sva.sv`;带断言的仿真用 `--assert --binary`。
- iverilog:`iverilog -g2012 -t null rtl/axil_regs.sv rtl/axil_regs_sva.sv`,但对并发断言支持有限,断言需用 Verilator 或商用仿真器。
- 商用仿真器:如 VCS、Xcelium、Questa,同时带上两个 .sv 文件并打开断言与覆盖率收集。
- 安装建议:`winget install verilator`,或安装 oss-cad-suite。
