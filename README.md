# RISC-V 5-Stage Pipelined Processor with Hazard Detection & Forwarding
this is a basic 5 stage pipelined processor with all the R I L S B type instructions

A synthesizable, high-performance 5-Stage Pipelined RISC-V Core implemented in Verilog. This processor implements the standard RISC-V RV32I pipeline stages (Fetch, Decode, Execute, Memory, Writeback) and features hardware-level hazard mitigation, including a dynamic Forwarding Unit for RAW hazards, a Hazard Detection Unit for load-use stalls, and pipeline flushing for control hazards.



The processor architecture is divided into five distinct stages separated by intermediate pipeline registers (reg1 to reg4):

```mermaid
graph LR
    subgraph IF [Instruction Fetch]
        PC[PC Register] --> IM[Instruction Memory]
    end
    subgraph ID [Instruction Decode]
        IM --> REG1[IF/ID Register]
        REG1 --> RF[Register File]
        REG1 --> CTRL[Control Unit]
        REG1 --> HZD[Hazard Unit]
    end
    subgraph EX [Execute]
        REG2[ID/EX Register] --> ALU[ALU]
        REG2 --> FWD[Forwarding Unit]
    end
    subgraph MEM [Memory]
        REG3[EX/MEM Register] --> DM[Data Memory]
    end
    subgraph WB [Writeback]
        REG4[MEM/WB Register] --> WB_MUX[WB Select Mux]
    end
    WB_MUX -.->|Writeback Data| RF
