# CLAUDE.md

## RTL 生成规则

只要任务涉及生成、编写或修改 Verilog/SystemVerilog/RTL 代码(新建模块、状态机、FIFO、仲裁器、接口控制器、流水线等硬件设计),**必须先调用 `rtl-gen` skill**,按其六阶段流程执行(需求分析 → 设计文档 → RTL → check 点 → SVA 断言 → lint + 验证方案),不要直接徒手写 RTL 代码。用户没有输入 `/rtl-gen` 也同样适用。

例外:只是回答 RTL 相关的概念问题、阅读/解释已有代码而不产出新代码时,不需要调用。
