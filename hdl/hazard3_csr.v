/*****************************************************************************\
|                        Copyright (C) 2021 Luke Wren                         |
|                     SPDX-License-Identifier: Apache-2.0                     |
\*****************************************************************************/

`default_nettype none

// Control and Status Registers (CSRs)
// Also includes CSR-related logic like interrupt enable/masking,
// trap vector calculation.

module hazard3_csr #(
	parameter XLEN            = 32,   // Must be 32
	parameter W_COUNTER       = 64,   // This *should* be 64, but can be reduced to save gates.
	                                  // The full 64 bits is writeable, so high-word increment can
	                                  // be implemented in software, and a narrower hw counter used
`include "hazard3_config.vh"
,
`include "hazard3_width_const.vh"
) (
	input  wire               clk,
	input  wire               rst_n,

	// Debug signalling
	output reg                debug_mode,

	input  wire               dbg_req_halt,
	input  wire               dbg_req_halt_on_reset,
	input  wire               dbg_req_resume,

	output wire               dbg_instr_caught_exception,
	output wire               dbg_instr_caught_ebreak,

	input  wire [W_DATA-1:0]  dbg_data0_rdata,
	output wire [W_DATA-1:0]  dbg_data0_wdata,
	output wire               dbg_data0_wen,

	// Read port is combinatorial.
	// Write port is synchronous, and write effects will be observed on the next clock cycle.
	// The *_soon strobes are versions which the core does not gate with its stall signal.
	// These are needed because:
	// - Core stall is a function of bus stall
	// - Illegal CSR accesses produce trap entry
	// - Trap entry (not necessarily caused by CSR access) gates outgoing bus accesses
	// - Through-paths from e.g. hready to htrans are problematic for timing/implementation
	input  wire [11:0]        addr,
	input  wire [XLEN-1:0]    wdata,
	input  wire               wen,
	input  wire               wen_soon, // wen will be asserted once some stall condition clears
	input  wire [1:0]         wtype,
	output reg  [XLEN-1:0]    rdata,
	input  wire               ren,
	input  wire               ren_soon, // ren will be asserted once some stall condition clears
	output wire               illegal,

	// Trap signalling
	// *We* tell the core that we are taking a trap, and where to, based on:
	// - Synchronous exception inputs from the core
	// - External IRQ signals
	// - Masking etc based on the state of CSRs like mie
	//
	// We do this by raising trap_enter_vld, and keeping it raised until trap_enter_rdy
	// goes high. trap_addr has the absolute value of trap target address.
	// Once trap_enter_vld && _rdy, mepc_in is copied to mepc, and other trap state is set.
	//
	// Note that an exception input can go away, e.g. if the pipe gets flushed. In this
	// case we lower trap_enter_vld.
	output wire [XLEN-1:0]     trap_addr,
	output wire                trap_is_irq,
	output wire                trap_enter_vld,
	input  wire                trap_enter_rdy,
	// True when we are about to trap, but are waiting for an excepting or
	// potentially-excepting instruction to clear M first. The instruction in X
	// is suppressed, X PC does not increment but still tracks exception
	// addresses.
	output wire                trap_enter_soon,
	// We need to know about load/stores in data phase because their exception
	// status is still unknown, so we fence off on them before entering debug
	// mode.
	input  wire                loadstore_dphase_pending,
	input  wire [XLEN-1:0]     mepc_in,
	output wire                wfi_stall_clear,

	// Exceptions must *not* be a function of bus stall.
	input  wire [W_EXCEPT-1:0] except,

	// Level-sensitive interrupt sources
	input  wire                delay_irq_entry,
	input  wire [NUM_IRQ-1:0]  irq,
	input  wire                irq_software,
	input  wire                irq_timer,

	// Other CSR-specific signalling
	input  wire                instr_ret
);

`include "hazard3_ops.vh"
`include "hazard3_csr_addr.vh"

localparam X0 = {XLEN{1'b0}};


// ----------------------------------------------------------------------------
// CSR state + update logic
// ----------------------------------------------------------------------------
// Names are (reg)_(field)

// Generic update logic for write/set/clear of an entire CSR:
wire [XLEN-1:0] wdata_update =
		wtype == CSR_WTYPE_C ? rdata & ~wdata :
		wtype == CSR_WTYPE_S ? rdata |  wdata : wdata;

function [XLEN-1:0] update_nonconst;
	input [XLEN-1:0] prev;
	input [XLEN-1:0] nonconst;
begin
		update_nonconst = (wdata_update & nonconst) | (prev & ~nonconst) ;
end
endfunction


wire enter_debug_mode;
wire exit_debug_mode;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		debug_mode <= 1'b0;
	end else if (DEBUG_SUPPORT) begin
		debug_mode <= (debug_mode && !exit_debug_mode) || enter_debug_mode;
	end
end

// ----------------------------------------------------------------------------
// Trap-handling CSRs

wire debug_suppresses_trap_update = DEBUG_SUPPORT && (debug_mode || enter_debug_mode);

// Two-level interrupt enable stack, shuffled on entry/exit:
reg mstatus_mpie;
reg mstatus_mie;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mstatus_mpie <= 1'b0;
		mstatus_mie <= 1'b0;
	end else if (CSR_M_TRAP) begin
		if (trap_enter_vld && trap_enter_rdy && !debug_suppresses_trap_update) begin
			if (except == EXCEPT_MRET) begin
				mstatus_mpie <= 1'b1;
				mstatus_mie <= mstatus_mpie;
			end else begin
				mstatus_mpie <= mstatus_mie;
				mstatus_mie <= 1'b0;
			end
		end else if (wen && addr == MSTATUS) begin
			{mstatus_mpie, mstatus_mie} <= {wdata_update[7], wdata_update[3]};
		end
	end
end

reg [XLEN-1:0] mscratch;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mscratch <= X0;
	end else if (CSR_M_TRAP) begin
		if (wen && addr == MSCRATCH)
			mscratch <= wdata_update;
	end
end

// Trap vector base
reg  [XLEN-1:0] mtvec_reg;
wire [XLEN-1:0] mtvec = mtvec_reg & ({XLEN{1'b1}} << 2);
wire            irq_vector_enable = mtvec_reg[0];

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mtvec_reg <= MTVEC_INIT;
	end else if (CSR_M_TRAP) begin
		if (wen && addr == MTVEC)
			mtvec_reg <= update_nonconst(mtvec_reg, MTVEC_WMASK);
	end
end

// Exception program counter
reg [XLEN-1:0] mepc;
// mepc only holds values aligned to instruction alignment
localparam MEPC_MASK = {{XLEN-2{1'b1}}, |EXTENSION_C, 1'b0};

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mepc <= X0;
	end else if (CSR_M_TRAP) begin
		if (trap_enter_vld && trap_enter_rdy && except != EXCEPT_MRET && !debug_suppresses_trap_update) begin
			mepc <= mepc_in & MEPC_MASK;
		end else if (wen && addr == MEPC) begin
			mepc <= wdata_update & MEPC_MASK;
		end
	end
end

// Interrupt enable (reserved bits are tied to 0)
reg [XLEN-1:0] mie;
localparam MIE_WMASK = 32'h00000888; // meie, mtie, msie

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mie <= X0;
	end else if (CSR_M_TRAP) begin
		if (wen && addr == MIE)
			mie <= update_nonconst(mie, MIE_WMASK);
	end
end

wire mie_meie = mie[11];

// Interrupt status ("pending") register, handled later
wire [XLEN-1:0] mip;
// None of the bits we implement are directly writeable.
// MSIP is only writeable by a "platform-defined" mechanism, and we don't implement
// one!

// Trap cause registers. The non-constant bits can be written by software,
// and update automatically on trap entry. (bits 30:0 are WLRL, so we tie most off)
reg        mcause_irq;
reg  [5:0] mcause_code;
wire       mcause_irq_next;
wire [5:0] mcause_code_next;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mcause_irq <= 1'b0;
		mcause_code <= 6'h0;
	end else if (CSR_M_TRAP) begin
		if (trap_enter_vld && trap_enter_rdy && except != EXCEPT_MRET && !debug_suppresses_trap_update) begin
			mcause_irq <= mcause_irq_next;
			mcause_code <= mcause_code_next;
		end else if (wen && addr == MCAUSE) begin
			{mcause_irq, mcause_code} <= {wdata_update[31], wdata_update[5:0]};
		end
	end
end

// Custom external interrupt enable registers (would be at top of mie, but that
// only leaves room for 16 external interrupts)

localparam N_IRQ_REG0 = NUM_IRQ >= 32  ? 32 :                     NUM_IRQ     ;
localparam N_IRQ_REG1 = NUM_IRQ >= 64  ? 32 : NUM_IRQ <= 32 ? 0 : NUM_IRQ - 32;
localparam N_IRQ_REG2 = NUM_IRQ >= 96  ? 32 : NUM_IRQ <= 64 ? 0 : NUM_IRQ - 64;
localparam N_IRQ_REG3 = NUM_IRQ >= 128 ? 32 : NUM_IRQ <= 96 ? 0 : NUM_IRQ - 96;

localparam MEIE0_WMASK = ~({XLEN{1'b1}} << N_IRQ_REG0);
localparam MEIE1_WMASK = ~({XLEN{1'b1}} << N_IRQ_REG1);
localparam MEIE2_WMASK = ~({XLEN{1'b1}} << N_IRQ_REG2);
localparam MEIE3_WMASK = ~({XLEN{1'b1}} << N_IRQ_REG3);

reg [XLEN-1:0] meie0;
reg [XLEN-1:0] meie1;
reg [XLEN-1:0] meie2;
reg [XLEN-1:0] meie3;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		meie0 <= X0;
		meie1 <= X0;
		meie2 <= X0;
		meie3 <= X0;
	end else if (wen && addr == MEIE0) begin
		meie0 <= update_nonconst(meie0, MEIE0_WMASK);
	end else if (wen && addr == MEIE1) begin
		meie1 <= update_nonconst(meie1, MEIE1_WMASK);
	end else if (wen && addr == MEIE2) begin
		meie2 <= update_nonconst(meie2, MEIE2_WMASK);
	end else if (wen && addr == MEIE3) begin
		meie3 <= update_nonconst(meie3, MEIE3_WMASK);
	end
end

// Assigned later:
wire [XLEN-1:0] meip0;
wire [XLEN-1:0] meip1;
wire [XLEN-1:0] meip2;
wire [XLEN-1:0] meip3;
wire [6:0] mlei;

// ----------------------------------------------------------------------------
// Counters

reg mcountinhibit_cy;
reg mcountinhibit_ir;

reg [XLEN-1:0] mcycleh;
reg [XLEN-1:0] mcycle;
reg [XLEN-1:0] minstreth;
reg [XLEN-1:0] minstret;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		mcycleh <= X0;
		mcycle <= X0;
		minstreth <= X0;
		minstret <= X0;
		// Counters inhibited by default to save energy
		mcountinhibit_cy <= 1'b1;
		mcountinhibit_ir <= 1'b1;
	end else if (CSR_COUNTER) begin
		// Optionally hold the top (2 * XLEN - W_COUNTER) bits constant to
		// save gates (noncompliant if enabled)
		if (!(mcountinhibit_cy || debug_mode))
			{mcycleh, mcycle} <= (({mcycleh, mcycle} + 1'b1) & ~({2*XLEN{1'b1}} << W_COUNTER))
				| ({mcycleh, mcycle} & ({2*XLEN{1'b1}} << W_COUNTER));
		if (!(mcountinhibit_ir || debug_mode) && instr_ret)
			{minstreth, minstret} <= (({minstreth, minstret} + 1'b1) & ~({2*XLEN{1'b1}} << W_COUNTER))
				| ({minstreth, minstret} & ({2*XLEN{1'b1}} << W_COUNTER));
		if (wen) begin
			if (addr == MCYCLEH)
				mcycleh <= wdata_update;
			if (addr == MCYCLE)
				mcycle <= wdata_update;
			if (addr == MINSTRETH)
				minstreth <= wdata_update;
			if (addr == MINSTRET)
				minstret <= wdata_update;
			if (addr == MCOUNTINHIBIT) begin
				{mcountinhibit_ir, mcountinhibit_cy} <= {wdata_update[2], wdata_update[0]};
			end
		end
	end
end

// ----------------------------------------------------------------------------
// Debug-mode CSRs

// The following DCSR bits are read/writable as normal:
// - ebreakm (bit 15)
// - step (bit 2)
// The following are read-only volatile:
// - cause (bits 8:6)
// All others are hardwired constants.

reg dcsr_ebreakm;
reg dcsr_step;
reg [2:0] dcsr_cause;
wire [2:0] dcause_next;

localparam DCSR_CAUSE_EBREAK  = 3'h1;
localparam DCSR_CAUSE_TRIGGER = 3'h2;
localparam DCSR_CAUSE_HALTREQ = 3'h3;
localparam DCSR_CAUSE_STEP    = 3'h4;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dcsr_ebreakm <= 1'b0;
		dcsr_step <= 1'b0;
		dcsr_cause <= 3'h0;
	end else if (DEBUG_SUPPORT) begin
		if (debug_mode && wen && addr == DCSR) begin
			{dcsr_ebreakm, dcsr_step} <= {wdata_update[15], wdata_update[2]};
		end
		if (enter_debug_mode) begin
			dcsr_cause <= dcause_next;
		end
	end
end

reg [XLEN-1:0] dpc;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dpc <= X0;
	end else if (DEBUG_SUPPORT) begin
		if (enter_debug_mode)
			dpc <= mepc_in;
		else if (debug_mode && wen && addr == DPC)
			// 1 or 2 LSBs are hardwired to 0, depending on IALIGN.
			dpc <= wdata_update & (~X0 << 2 - EXTENSION_C);
	end
end

assign dbg_data0_wdata = wdata;
assign dbg_data0_wen = debug_mode && wen && addr == DMDATA0;

// ----------------------------------------------------------------------------
// Read port + detect addressing of unmapped CSRs
// ----------------------------------------------------------------------------

reg decode_match;

always @ (*) begin
	decode_match = 1'b0;
	rdata = {XLEN{1'b0}};
	case (addr)

    // ------------------------------------------------------------------------
	// Mandatory CSRs

	MISA: if (CSR_M_MANDATORY) begin
		// WARL, so it is legal to be tied constant
		decode_match = 1'b1;
		rdata = {
			2'h1,              // MXL: 32-bit
			{XLEN-28{1'b0}},   // WLRL

			2'd0,              // Z, Y, no
			|CSR_M_TRAP,       // X is set for our non-standard interrupt enable CSRs
			10'd0,             // W...N, no
			|EXTENSION_M,
			3'd0,              // L...J, no
			1'b1,              // Integer ISA
			5'd0,              // H...D, no
			|EXTENSION_C,
			1'b0,
			|EXTENSION_A
		};
	end
	MVENDORID: if (CSR_M_MANDATORY) begin
		decode_match = !wen_soon; // MRO
		rdata = MVENDORID_VAL;
	end
	MARCHID: if (CSR_M_MANDATORY) begin
		decode_match = !wen_soon; // MRO
		// Hazard3's open source architecture ID
		rdata = 32'd27;
	end
	MIMPID: if (CSR_M_MANDATORY) begin
		decode_match = !wen_soon; // MRO
		rdata = MIMPID_VAL;
	end
	MHARTID: if (CSR_M_MANDATORY) begin
		decode_match = !wen_soon; // MRO
		rdata = MHARTID_VAL;
	end

	MCONFIGPTR: if (CSR_M_MANDATORY) begin
		decode_match = !wen_soon; // MRO
		rdata = MCONFIGPTR_VAL;
	end

	MSTATUS: if (CSR_M_MANDATORY || CSR_M_TRAP) begin
		decode_match = 1'b1;
		rdata = {
			1'b0,    // Never any dirty state besides GPRs
			8'd0,    // (WPRI)
			1'b0,    // TSR (Trap SRET), tied 0 if no S mode.
			1'b0,    // TW (Timeout Wait), tied 0 if only M mode.
			1'b0,    // TVM (trap virtual memory), tied 0 if no S mode.
			1'b0,    // MXR (Make eXecutable Readable), tied 0 if not S mode.
			1'b0,    // SUM, tied 0, we have no S or U mode
			1'b0,    // MPRV (modify privilege), tied 0 if no U mode
			4'd0,    // XS, FS always "off" (no extension state to clear!)
			2'b11,   // MPP (M-mode previous privilege), we are always M-mode
			2'd0,    // (WPRI)
			1'b0,    // SPP, tied 0 if S mode not supported
			mstatus_mpie,
			3'd0,    // No S, U
			mstatus_mie,
			3'd0     // No S, U
		};
	end

	// MSTATUSH is all zeroes (fields are MBE and SBE, which are zero because
	// we are pure little-endian.) Prior to priv-1.12 MSTATUSH could be left
	// unimplemented in this case, but now it must be decoded even if
	// hardwired to 0.
	MSTATUSH: if (CSR_M_MANDATORY || CSR_M_TRAP) begin
		decode_match = 1'b1;
	end

	// MEDELEG, MIDELEG should not exist for M-only implementations. Will raise
	// illegal instruction exception if accessed.

    // ------------------------------------------------------------------------
	// Trap-handling CSRs

	// This is a 32 bit synthesised register with set/clear/write/read, don't
	// turn it on unless we really have to
	MSCRATCH: if (CSR_M_TRAP && CSR_M_MANDATORY) begin
		decode_match = 1'b1;
		rdata = mscratch;
	end

	MEPC: if (CSR_M_TRAP) begin
		decode_match = 1'b1;
		rdata = mepc;
	end

	MCAUSE: if (CSR_M_TRAP) begin
		decode_match = 1'b1;
		rdata = {
			mcause_irq,      // Sign bit is 1 for IRQ, 0 for exception
			{26{1'b0}},      // Padding
			mcause_code[4:0] // Enough for 16 external IRQs, which is all we have room for in mip/mie
		};
	end

	MTVAL: if (CSR_M_TRAP) begin
		decode_match = 1'b1;
		// Hardwired to 0
	end

	MIE: if (CSR_M_TRAP) begin
		decode_match = 1'b1;
		rdata = mie;
	end

	MIP: if (CSR_M_TRAP) begin
		// Writes are permitted, but ignored.
		decode_match = 1'b1;
		rdata = mip;
	end

	MTVEC: if (CSR_M_TRAP) begin
		decode_match = 1'b1;
		rdata = {
			mtvec[XLEN-1:2],  // BASE
			1'b0,             // Reserved mode bit gets WARL'd to 0
			irq_vector_enable // MODE is vectored (2'h1) or direct (2'h0)
		};
	end

    // ------------------------------------------------------------------------
	// Counter CSRs

	// Get the tied WARLs out the way first
	MHPMCOUNTER3:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER4:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER5:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER6:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER7:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER8:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER9:   if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER10:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER11:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER12:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER13:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER14:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER15:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER16:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER17:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER18:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER19:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER20:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER21:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER22:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER23:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER24:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER25:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER26:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER27:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER28:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER29:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER30:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER31:  if (CSR_COUNTER) begin decode_match = 1'b1; end

	MHPMCOUNTER3H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER4H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER5H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER6H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER7H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER8H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER9H:  if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER10H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER11H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER12H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER13H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER14H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER15H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER16H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER17H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER18H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER19H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER20H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER21H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER22H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER23H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER24H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER25H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER26H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER27H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER28H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER29H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER30H: if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMCOUNTER31H: if (CSR_COUNTER) begin decode_match = 1'b1; end

	MHPMEVENT3:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT4:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT5:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT6:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT7:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT8:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT9:     if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT10:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT11:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT12:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT13:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT14:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT15:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT16:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT17:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT18:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT19:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT20:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT21:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT22:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT23:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT24:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT25:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT26:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT27:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT28:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT29:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT30:    if (CSR_COUNTER) begin decode_match = 1'b1; end
	MHPMEVENT31:    if (CSR_COUNTER) begin decode_match = 1'b1; end

	MCOUNTINHIBIT:  if (CSR_COUNTER) begin
		decode_match = 1'b1;
		rdata = {
			29'd0,
			mcountinhibit_ir,
			1'b0,
			mcountinhibit_cy
		};
	end

	MCYCLE: if (CSR_COUNTER) begin
		decode_match = 1'b1;
		rdata = mcycle;
	end
	MINSTRET: if (CSR_COUNTER) begin
		decode_match = 1'b1;
		rdata = minstret;
	end

	MCYCLEH: if (CSR_COUNTER) begin
		decode_match = 1'b1;
		rdata = mcycleh;
	end
	MINSTRETH: if (CSR_COUNTER) begin
		decode_match = 1'b1;
		rdata = minstreth;
	end

	// ------------------------------------------------------------------------
	// Trigger Module CSRs

	// If triggers aren't supported, OpenOCD expects the following:
	// - tselect must be present
	// - tselect must raise an exception when written to
	// Otherwise it returns an error instead of 0 count when enumerating triggers
	TSELECT: if (DEBUG_SUPPORT) begin
		decode_match = !wen_soon;
	end

	// ------------------------------------------------------------------------
	// Debug CSRs

	DCSR: if (DEBUG_SUPPORT && debug_mode) begin
		decode_match = 1'b1;
		rdata = {
			4'h4,         // xdebugver = 4, for 0.13.2 debug spec
			12'd0,        // reserved
			dcsr_ebreakm,
			3'h0,         // No other modes besides M to break from
			1'b0,         // stepie = 0, no interrupts in single-step mode
			1'b1,         // stopcount = 1, no counter increment in debug mode
			1'b1,         // stoptime = 0, no core-local timer increment in debug mode
			dcsr_cause,
			1'b0,         // reserved
			1'b0,         // mprven = 0, we don't have MPRV support
			1'b0,         // nmip = 0, we have no NMI
			dcsr_step,
			2'h3          // prv = 3, we only have M mode
		};
	end

	DPC: if (DEBUG_SUPPORT && debug_mode) begin
		decode_match = 1'b1;
		rdata = dpc;
	end

	DMDATA0: if (DEBUG_SUPPORT && debug_mode) begin
		decode_match = 1'b1;
		rdata = dbg_data0_rdata;
	end

    // ------------------------------------------------------------------------
	// Custom CSRs

	MEIE0: if (CSR_M_TRAP && N_IRQ_REG0 > 0) begin
		decode_match = 1'b1;
		rdata = meie0;
	end

	MEIE1: if (CSR_M_TRAP && N_IRQ_REG1 > 0) begin
		decode_match = 1'b1;
		rdata = meie1;
	end

	MEIE2: if (CSR_M_TRAP && N_IRQ_REG2 > 0) begin
		decode_match = 1'b1;
		rdata = meie2;
	end

	MEIE3: if (CSR_M_TRAP && N_IRQ_REG3 > 0) begin
		decode_match = 1'b1;
		rdata = meie3;
	end

	MEIP0: if (CSR_M_TRAP && N_IRQ_REG0 > 0) begin
		decode_match = !wen_soon;
		rdata = meip0;
	end

	MEIP1: if (CSR_M_TRAP && N_IRQ_REG1 > 0) begin
		decode_match = !wen_soon;
		rdata = meip1;
	end

	MEIP2: if (CSR_M_TRAP && N_IRQ_REG2 > 0) begin
		decode_match = !wen_soon;
		rdata = meip2;
	end

	MEIP3: if (CSR_M_TRAP && N_IRQ_REG3 > 0) begin
		decode_match = !wen_soon;
		rdata = meip3;
	end

	MLEI: if (CSR_M_TRAP) begin
		decode_match = !wen_soon;
		rdata = {{XLEN-9{1'b0}}, mlei, 2'b00};
	end

	default: begin end
	endcase
end

assign illegal = (wen_soon || ren_soon) && !decode_match;

// ----------------------------------------------------------------------------
// Debug run/halt

// req_resume_prev is to cut an in->out path from request to trap addr.
reg have_just_reset;
reg step_halt_req;
reg dbg_req_resume_prev;
reg dbg_req_halt_prev;
reg pending_dbg_resume_prev;

wire pending_dbg_resume = (pending_dbg_resume_prev || dbg_req_resume_prev) && debug_mode;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		have_just_reset <= |DEBUG_SUPPORT;
		step_halt_req <= 1'b0;
		dbg_req_resume_prev <= 1'b0;
		dbg_req_halt_prev <= 1'b0;
		pending_dbg_resume_prev <= 1'b0;
	end else if (DEBUG_SUPPORT) begin
		if (instr_ret)
			have_just_reset <= 1'b0;

		// Just a delayed version of the request from outside of the core.
		// Delay is fine because the DM awaits ack before deasserting.
		dbg_req_resume_prev <= dbg_req_resume;
		dbg_req_halt_prev <= dbg_req_halt;

		if (debug_mode) begin
			step_halt_req <= 1'b0;
		end else if (dcsr_step && (instr_ret || (trap_enter_vld && trap_enter_rdy))) begin
			// Note exception entry is also considered a step -- in this case
			// we are supposed to take the trap and then break to debug mode
			// before executing the first trap instruction. *IRQ* entry does
			// not occur when step is 1 (because we hardwire dcsr.stepie to 0)
			step_halt_req <= 1'b1;
		end

		pending_dbg_resume_prev <= pending_dbg_resume;
	end
end

// We can enter the halted state in an IRQ-like manner (squeeze in between the
// instructions in stage 2 and stage 3) or in an exception-like manner
// (replace the instruction in stage 3).
//
// Halt request and step-break are IRQ-like. We need to be careful when a halt
// request lines up with an instruction in M which either has generated an
// exception (e.g. an ecall) or may yet generate an exception (a load). In
// this case the correct thing to do is to:
//
// - Squash whatever instruction may be in X, and inhibit X PC increment
// - Wait until after the exception entry is taken (or the load/store
//   completes successfully)
// - Immediately trigger an IRQ-like debug entry.
//
// This ensures the debugger sees mcause/mepc set correctly, with dpc pointing
// to the handler entry point, if the instruction excepts.

wire exception_req_any;
wire halt_delayed_by_exception = exception_req_any || loadstore_dphase_pending;

// This would also include triggers, if/when those are implemented:
wire want_halt_except = DEBUG_SUPPORT && !debug_mode && (
	dcsr_ebreakm && except == EXCEPT_EBREAK
);

// Note exception-like causes (trigger, ebreak) are higher priority than
// IRQ-like.
//
// We must mask halt_req with delay_irq_entry (true on cycle 2 and beyond of
// load/store address phase) because at that point we can't suppress the bus
// access..
wire want_halt_irq_if_no_exception = DEBUG_SUPPORT && !debug_mode && !want_halt_except && (
	(dbg_req_halt_prev && !delay_irq_entry) ||
	(dbg_req_halt_on_reset && have_just_reset) ||
	step_halt_req
);

// Exception (or potential exception due to load/store) in M delays halt
// entry. The halt intention still blocks X, so we can't get blocked forever
// by a string of load/stores. This is just here to get sequencing between an
// exception (or potential exception) in M, and debug mode entry.
wire want_halt_irq = want_halt_irq_if_no_exception && !halt_delayed_by_exception;

assign dcause_next =
	// Trigger would be highest priority if implemented
	except == EXCEPT_EBREAK                                         ? 3'h1 : // ebreak (priority 3)
	dbg_req_halt_prev || (dbg_req_halt_on_reset && have_just_reset) ? 3'h3 : // halt or reset-halt (priority 1, 2)
	                                                                  3'h4;  // single-step (priority 0)

assign enter_debug_mode = !debug_mode && (want_halt_irq || want_halt_except) && trap_enter_rdy;

assign exit_debug_mode = debug_mode && pending_dbg_resume && trap_enter_rdy;

// Report back to DM instruction injector to tell it its instruction sequence
// has finished (ebreak) or crashed out
assign dbg_instr_caught_ebreak = debug_mode && except == EXCEPT_EBREAK && trap_enter_rdy;

// Note we exclude ebreak from here regardless of dcsr.ebreakm, since we are
// already in debug mode at this point
assign dbg_instr_caught_exception = debug_mode && except != EXCEPT_NONE && except != EXCEPT_EBREAK && trap_enter_rdy;

// ----------------------------------------------------------------------------
// Trap request generation

reg [NUM_IRQ-1:0] irq_r;
reg irq_software_r;
reg irq_timer_r;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		irq_r <= {NUM_IRQ{1'b0}};
		irq_software_r <= 1'b0;
		irq_timer_r <= 1'b0;
	end else begin
		irq_r <= irq;
		irq_software_r <= irq_software;
		irq_timer_r <= irq_timer;
	end
end

localparam MAX_IRQ = 128;
wire [MAX_IRQ-1:0] meip = {{MAX_IRQ-NUM_IRQ{1'b0}}, irq_r};
wire [MAX_IRQ-1:0] meie = {meie3, meie2, meie1, meie0};

assign {meip3, meip2, meip1, meip0} = meip;

wire external_irq_pending = |(meie & meip);

assign mip = {
	20'h0,                // Reserved
	external_irq_pending, // meip, Global pending bit for external IRQs
	3'h0,                 // Reserved
	irq_timer_r,          // mtip, interrupt from memory-mapped timer peripheral
	3'h0,                 // Reserved
	irq_software_r,       // msip, software interrupt from memory-mapped register
	3'h0                  // Reserved
};

wire irq_active = |(mip & mie) && mstatus_mie && !dcsr_step;

// WFI clear respects individual interrupt enables but ignores mstatus.mie.
// Additionally, wfi is treated as a nop during single-stepping and D-mode.
assign wfi_stall_clear = |(mip & mie) || dcsr_step || debug_mode || want_halt_irq_if_no_exception;

wire [6:0] external_irq_num;
assign mlei = external_irq_num;

hazard3_priority_encode #(
	.W_REQ (MAX_IRQ)
) mlei_priority_encode (
	.req (meie & meip),
	.gnt (external_irq_num)
);

// Priority order from priv spec: external > software > timer
wire [3:0] standard_irq_num =
	mip[11] && mie[11] ? 4'd11 :
	mip[3]  && mie[3]  ? 4'd3  :
	mip[7]  && mie[7]  ? 4'd7  : 4'd0;

// ebreak may be treated as a halt-to-debugger or a regular M-mode exception,
// depending on dcsr.ebreakm.
assign exception_req_any = except != EXCEPT_NONE && !(except == EXCEPT_EBREAK && dcsr_ebreakm);

wire [5:0] mcause_irq_num =	irq_active ? {2'h0, standard_irq_num} : 6'd0;

wire [5:0] vector_sel =	!exception_req_any && irq_vector_enable ? mcause_irq_num : 6'd0;

assign trap_addr =
	except == EXCEPT_MRET ? mepc :
	pending_dbg_resume    ? dpc  : mtvec | {24'h0, vector_sel, 2'h0};

// Check for exception-like or IRQ-like trap entry; any debug mode entry takes
// priority over any regular trap.
assign trap_is_irq = DEBUG_SUPPORT && (want_halt_except || want_halt_irq) ?
	!want_halt_except : !exception_req_any;

// When there is a loadstore dphase pending, we block off the IRQ trap
// request, but still assert the trap_enter_soon flag. This blocks issue of
// further load/stores which have not yet been locked into aphase, so the IRQ
// can eventually go through. It's not safe to enter an IRQ when a dphase is
// in progress, because that dphase could subsequently except, and sample the
// IRQ vector PC instead of the load/store instruction PC.

// delay_irq_entry also applies to IRQ-like debug entries.
assign trap_enter_vld =
	CSR_M_TRAP && (exception_req_any ||
		!delay_irq_entry && !debug_mode && irq_active && !loadstore_dphase_pending) ||
	DEBUG_SUPPORT && (
		(!delay_irq_entry && want_halt_irq) || want_halt_except || pending_dbg_resume);

assign trap_enter_soon = trap_enter_vld || (
	|DEBUG_SUPPORT && want_halt_irq_if_no_exception ||
	!delay_irq_entry && !debug_mode && irq_active && loadstore_dphase_pending
);

assign mcause_irq_next = !exception_req_any;
assign mcause_code_next = exception_req_any ? {2'h0, except} : mcause_irq_num;

// ----------------------------------------------------------------------------
// Properties

`ifdef FORMAL

// Keep track of whether we are in a trap (only for formal property purposes)
reg in_trap;

always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		in_trap <= 1'b0;
	else
		in_trap <= (in_trap || (trap_enter_vld && trap_enter_rdy))
			&& !(trap_enter_vld && trap_enter_rdy && except == EXCEPT_MRET);

always @ (posedge clk) begin
`ifdef RISCV_FORMAL
	// Assume there are no nested exceptions, to stop riscv-formal from doing
	// annoying things like stopping instructions from retiring by repeatedly
	// feeding in invalid instructions
	if (in_trap)
		assume(except == EXCEPT_NONE || except == EXCEPT_MRET);

	// Assume IRQs are not deasserted on cycles where exception entry does not
	// take place
	if (!trap_enter_rdy)
		assume(~|(irq_r & ~irq));
`endif

	// Make sure CSR accesses are flushed
	if (trap_enter_vld && trap_enter_rdy)
		assert(!(wen || ren));

	// Writing to CSR on cycle after trap entry -- should be impossible, a CSR
	// access instruction should have been flushed or moved down to stage 3, and
	// no fetch could have arrived by now
	if ($past(trap_enter_vld && trap_enter_rdy))
		assert(!wen);

	// Should be impossible to get into the trap and exit immediately:
	if (in_trap && !$past(in_trap))
		assert(except != EXCEPT_MRET);

	// Should be impossible to get to another mret so soon after exiting:
	if ($past(except == EXCEPT_MRET && trap_enter_vld && trap_enter_rdy))
		assert(except != EXCEPT_MRET);

	// Must be impossible to enter two traps on consecutive cycles. Most importantly:
	//
	// - IRQ -> Except: no new instruction could have been fetched by this point,
	//   and an exception by e.g. a left-behind store data phase would sample the
	//   wrong PC.
	//
	// - Except -> IRQ: would need to re-set mstatus.mie first, shouldn't happen
	//
	// Sole exclusion is mret. We can return from an interrupt/exception and take
	// a new interrupt on the next cycle.

	if ($past(trap_enter_vld && trap_enter_rdy && except != EXCEPT_MRET))
		assert(!(trap_enter_vld && trap_enter_rdy));

	// Just to stress that this is the the only case:
	if (trap_enter_vld && trap_enter_rdy && $past(trap_enter_vld && trap_enter_rdy))
		assert($past(except == EXCEPT_MRET));

	if (rst_n && $past(trap_enter_vld && !trap_enter_rdy && !trap_is_irq)) begin
		// Exception which didn't go through should not disappear
		assert(trap_enter_vld);
		// Exception should not be replaced by IRQ
		assert(!trap_is_irq);
	end

end

`endif

endmodule
