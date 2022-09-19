-- #################################################################################################
-- # << neorv32-riscof - RISCOF Testbench for risc-arch-test Verification >>                       #
-- # ********************************************************************************************* #
-- # Minimal NEORV32 CPU testbench for running the RISCOF-base architecture test framework.        #
-- # The simulation mode of UART0 is used to dump processing data to a file.                       #
-- #                                                                                               #
-- # An external IMEM (RAM!) is initialized by a plain ASCII HEX file. The IMEM is split into four #
-- # memory modules of 512kB each using variables of type bit_vector to minimize memory footprint. #
-- # These hacks are requires since GHDL has problems with handling large objects.                 #
-- # -> https://github.com/ghdl/ghdl/issues/1592                                                   #
-- # The maximum executable size currently comes from the JAL test (~1.7MB).                       #
-- #                                                                                               #
-- # Furthermore, the testbench features simulation triggers:                                      #
-- # - machine software interrupt (MSI)                                                            #
-- # - machine external interrupt (MEI)                                                            #
-- # - most important: trigger end of simulation using VHDL08's "finish" statement                 #
-- # ********************************************************************************************* #
-- # https://github.com/stnolting/neorv32-riscof                               (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;
use std.textio.all;
use std.env.finish;

entity neorv32_riscof_tb is
  generic (
    IMEM_FILE : string;           -- memory initialization file (*.hex)
    RISCV_B   : boolean := false; -- bit-manipulation ISA extension
    RISCV_C   : boolean := false; -- compressed ISA extension
    RISCV_E   : boolean := false; -- embedded ISA extension
    RISCV_M   : boolean := false; -- hardware mul/div ISA extension
    RISCV_U   : boolean := false  -- user-mode ISA extension
  );
end neorv32_riscof_tb;

architecture neorv32_riscof_tb_rtl of neorv32_riscof_tb is

  -- IMEM memory type --
  type imem_t is array (natural range <>) of bit_vector(31 downto 0); -- memory with 32-bit entries

  -- Initialize imem_t array from ASCII HEX file (starting at file offset 'start') --
  impure function init_imem_hex(file_name : string; start : natural; num_words : natural) return imem_t is
    file     text_file   : text open read_mode is file_name;
    variable text_line_v : line;
    variable mem_v       : imem_t(0 to num_words-1);
    variable i_abs_v     : natural;
    variable i_rel_v     : natural;
    variable char_v      : character;
    variable data_v      : std_ulogic_vector(31 downto 0);
  begin
    mem_v := (others => (others => '0'));
    i_abs_v := 0;
    i_rel_v := 0;
    while (endfile(text_file) = false) and (i_abs_v < ((start/4) + num_words)) loop
      readline(text_file, text_line_v);
      if (i_abs_v >= (start/4)) then -- begin initialization at defined start offset
        -- construct one 32-bit word --
        data_v := (others => '0');
        for i in 7 downto 0 loop -- 32-bit = 8 hex chars
          read(text_line_v, char_v); -- get one hex char
          data_v(i*4+3 downto i*4) := hexchar_to_stdulogicvector_f(char_v);
        end loop; -- i
        -- store according byte to memory image --
        mem_v(i_rel_v) := to_bitvector(data_v);
        i_rel_v := i_rel_v + 1; -- local pointer (for the current IMEM module)
      end if;
      i_abs_v := i_abs_v + 1; -- global pointer (for the HEX source file)
    end loop; -- not end of file
    return mem_v;
  end function init_imem_hex;

  -- external IMEM (initialized from file); size of one module --
  constant imem_size_c : natural := 512*1024; -- size in bytes (experimental maximum for GHDL)

  -- generators --
  signal clk_gen, rst_gen : std_ulogic := '0';

  -- Wishbone bus --
  type wishbone_t is record
    addr  : std_ulogic_vector(31 downto 0); -- address
    wdata : std_ulogic_vector(31 downto 0); -- master write data
    rdata : std_ulogic_vector(31 downto 0); -- master read data
    we    : std_ulogic; -- write enable
    sel   : std_ulogic_vector(03 downto 0); -- byte enable
    stb   : std_ulogic; -- strobe
    cyc   : std_ulogic; -- valid cycle
    ack   : std_ulogic; -- transfer acknowledge
  end record;
  signal wb_cpu : wishbone_t;

begin

  -- Clock/Reset Generator ------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  clk_gen <= not clk_gen after 5 ns;
  rst_gen <= '0', '1' after 100 ns;


  -- The Core of the Problem ----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neorv32_top_inst: neorv32_top
  generic map (
    -- General --
    CLOCK_FREQUENCY              => 0, -- irrelevant
    HW_THREAD_ID                 => 0,
    INT_BOOTLOADER_EN            => false,
    -- RISC-V CPU Extensions --
    CPU_EXTENSION_RISCV_B        => RISCV_B,
    CPU_EXTENSION_RISCV_C        => RISCV_C,
    CPU_EXTENSION_RISCV_E        => RISCV_E,
    CPU_EXTENSION_RISCV_M        => RISCV_M,
    CPU_EXTENSION_RISCV_U        => RISCV_U,
    CPU_EXTENSION_RISCV_Zicsr    => true,
    CPU_EXTENSION_RISCV_Zicntr   => true,
    CPU_EXTENSION_RISCV_Zifencei => true,
    -- Extension Options --
    FAST_MUL_EN                  => true,
    FAST_SHIFT_EN                => true,
    -- Internal Instruction memory --
    MEM_INT_IMEM_EN              => false,
    -- Internal Data memory --
    MEM_INT_DMEM_EN              => false,
    -- External memory interface --
    MEM_EXT_EN                   => true,
    MEM_EXT_TIMEOUT              => 16,
    MEM_EXT_PIPE_MODE            => true,
    MEM_EXT_BIG_ENDIAN           => false,
    MEM_EXT_ASYNC_RX             => true,
    MEM_EXT_ASYNC_TX             => true,
    -- Processor peripherals --
    IO_MTIME_EN                  => true,
    IO_UART0_EN                  => true
  )
  port map (
    -- Global control --
    clk_i    => clk_gen,
    rstn_i   => rst_gen,
    -- Wishbone bus interface (available if MEM_EXT_EN = true) --
    wb_tag_o => open,
    wb_adr_o => wb_cpu.addr,
    wb_dat_i => wb_cpu.rdata,
    wb_dat_o => wb_cpu.wdata,
    wb_we_o  => wb_cpu.we,
    wb_sel_o => wb_cpu.sel,
    wb_stb_o => wb_cpu.stb,
    wb_cyc_o => wb_cpu.cyc,
    wb_ack_i => wb_cpu.ack,
    wb_err_i => '0'
  );


  -- External IMEM --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  ext_imem_rw: process(clk_gen)
    -- initialize memory modules from HEX file --
    variable imem0_v : imem_t(0 to imem_size_c/4-1) := init_imem_hex(IMEM_FILE, 0*imem_size_c, imem_size_c/4);
    variable imem1_v : imem_t(0 to imem_size_c/4-1) := init_imem_hex(IMEM_FILE, 1*imem_size_c, imem_size_c/4);
    variable imem2_v : imem_t(0 to imem_size_c/4-1) := init_imem_hex(IMEM_FILE, 2*imem_size_c, imem_size_c/4);
    variable imem3_v : imem_t(0 to imem_size_c/4-1) := init_imem_hex(IMEM_FILE, 3*imem_size_c, imem_size_c/4);
  begin
    if rising_edge(clk_gen) then
      -- handshake --
      wb_cpu.ack <= wb_cpu.cyc and wb_cpu.stb;

      -- write access --
      if ((wb_cpu.cyc and wb_cpu.stb and wb_cpu.we) = '1') then
        for i in 0 to 3 loop
          if (wb_cpu.sel(i) = '1') then -- byte-wide access
            case wb_cpu.addr(index_size_f(imem_size_c/4)+3 downto index_size_f(imem_size_c/4)+2) is -- split logical IMEM into 4 *physical* memories
              when "00" => imem0_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := to_bitvector(wb_cpu.wdata(7+i*8 downto 0+i*8));
              when "01" => imem1_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := to_bitvector(wb_cpu.wdata(7+i*8 downto 0+i*8));
              when "10" => imem2_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := to_bitvector(wb_cpu.wdata(7+i*8 downto 0+i*8));
              when "11" => imem3_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := to_bitvector(wb_cpu.wdata(7+i*8 downto 0+i*8));
              when others => NULL;
            end case;
          end if;
        end loop; -- i
      end if;

      -- read access --
      if ((wb_cpu.cyc and wb_cpu.stb and (not wb_cpu.we)) = '1') then
        case wb_cpu.addr(index_size_f(imem_size_c/4)+3 downto index_size_f(imem_size_c/4)+2) is -- split logical IMEM into 4 *physical* memories
          when "00" => wb_cpu.rdata <= to_stdulogicvector(imem0_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))); -- word aligned
          when "01" => wb_cpu.rdata <= to_stdulogicvector(imem1_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))); -- word aligned
          when "10" => wb_cpu.rdata <= to_stdulogicvector(imem2_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))); -- word aligned
          when "11" => wb_cpu.rdata <= to_stdulogicvector(imem3_v(to_integer(unsigned(wb_cpu.addr(index_size_f(imem_size_c/4)+1 downto 2))))); -- word aligned
          when others => NULL;
        end case;
      end if;
    end if;
  end process ext_imem_rw;


  -- Simulation Triggers --------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  sim_triggers: process(clk_gen)
  begin
    if rising_edge(clk_gen) then
      if (wb_cpu.cyc = '1') and (wb_cpu.stb = '1') and (wb_cpu.we = '1') and (wb_cpu.addr = x"F0000000") then
        -- end simulation --
        if (wb_cpu.wdata = x"CAFECAFE") then
          assert false report "Finishing Simulation." severity warning;
          finish; -- VHDL08+ only!
        -- machine software interrupt (MSI) --
        elsif (wb_cpu.wdata = x"55555555") then
          NULL; -- TODO
        -- machine external interrupt (MEI) --
        elsif (wb_cpu.wdata = x"EEEEEEEE") then
          NULL; -- TODO
        end if;
      end if;
    end if;
  end process sim_triggers;


end neorv32_riscof_tb_rtl;