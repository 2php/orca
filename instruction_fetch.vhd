

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;


library work;
use work.rv_components.all;
use work.utils.all;

entity instruction_fetch is
  generic (
    REGISTER_SIZE    : positive;
    INSTRUCTION_SIZE : positive;
    RESET_VECTOR     : natural);
  port (
    clk   : in std_logic;
    reset : in std_logic;
    stall : in std_logic;

    branch_pred : in std_logic_vector(REGISTER_SIZE*2+3-1 downto 0);

    instr_out       : out std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
    pc_out          : out std_logic_vector(REGISTER_SIZE-1 downto 0);
    br_taken        : out std_logic;
    valid_instr_out : out std_logic;

    read_address   : out std_logic_vector(REGISTER_SIZE-1 downto 0);
    read_en        : out std_logic;
    read_data      : in  std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
    read_datavalid : in  std_logic;
    read_wait      : in  std_logic
    );

end entity instruction_fetch;

architecture rtl of instruction_fetch is

  signal correction      : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal correction_en   : std_logic;
  signal program_counter : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal generated_pc    : std_logic_vector(REGISTER_SIZE -1 downto 0);
  signal address         : std_logic_vector(REGISTER_SIZE -1 downto 0);

  signal instr : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);

  signal valid_instr : std_logic;

  signal saved_instr_out       : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
  signal saved_pc_out          : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal saved_next_pc_out     : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal saved_valid_instr_out : std_logic;

  constant BRANCH_PREDICTORS : natural := 2**8;
  signal pc_corr             : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal pc_corr_en          : std_logic;

begin  -- architecture rtl
  pc_corr    <= branch_get_tgt(branch_pred);
  pc_corr_en <= branch_get_flush(branch_pred);

  assert program_counter(1 downto 0) = "00" report "BAD INSTRUCTION ADDRESS" severity error;

  read_en <= not reset;

  latch_pc : process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        program_counter <= std_logic_vector(to_signed(RESET_VECTOR, REGISTER_SIZE));
        correction_en   <= '0';
      else
        if pc_corr_en = '1' then
          correction_en <= '1';
          correction    <= pc_corr;
        elsif read_datavalid = '1' then
          correction_en <= '0';
        end if;
        program_counter <= address;
      end if;
    end if;  -- clock
  end process;

  address <= program_counter when read_datavalid = '0' or stall = '1' else
             correction when correction_en = '1' else
             generated_pc;


--unpack instruction
  instr <= read_data;

  valid_instr <= read_datavalid and not correction_en and not stall;




  nuse_BP : if BRANCH_PREDICTORS = 0 generate
    --No branch prediction
    process(clk)
    begin
      if rising_edge(clk) then
        generated_pc <= std_logic_vector(signed(address) + 4);
        br_taken     <= '0';
      end if;
    end process;
--    generated_pc <= std_logic_vector(signed(program_counter) + 4);
  end generate nuse_BP;

  use_BP : if BRANCH_PREDICTORS > 0 generate
    constant INDEX_SIZE : integer := log2(BRANCH_PREDICTORS);
    constant TAG_SIZE   : integer := REGISTER_SIZE-2-INDEX_SIZE;

    type tbt_type is array(BRANCH_PREDICTORS-1 downto 0) of std_logic_vector(REGISTER_SIZE+TAG_SIZE+1 -1 downto 0);
    signal branch_tbt       : tbt_type := (others => (others => '0'));
    signal prediction_match : std_logic;
    signal branch_taken     : std_logic;
    signal branch_pc        : std_logic_vector(REGISTER_SIZE-1 downto 0);
    signal branch_tgt       : std_logic_vector(REGISTER_SIZE-1 downto 0);
    signal branch_flush     : std_logic;
    signal branch_en        : std_logic;
    signal tbt_raddr        : integer;
    signal tbt_waddr        : integer;

  begin
    branch_tgt   <= branch_get_tgt(branch_pred);
    branch_pc    <= branch_get_pc(branch_pred);
    branch_taken <= branch_get_taken(branch_pred);
    branch_flush <= branch_get_flush(branch_pred);
    branch_en    <= branch_get_enable(branch_pred);

    tbt_raddr <= 0 when BRANCH_PREDICTORS = 1 else
                 to_integer(unsigned(address(INDEX_SIZE+2-1 downto 2)));
    tbt_waddr <= 0 when BRANCH_PREDICTORS = 1 else
                 to_integer(unsigned(branch_pc(INDEX_SIZE+2-1 downto 2)));

    process(clk)

      variable tbt_entry  : std_logic_vector(branch_tbt(0)'range);
      variable tbt_tag    : std_logic_vector(TAG_SIZE-1 downto 0);
      variable tbt_target : std_logic_vector(REGISTER_SIZE -1 downto 0);
      variable tbt_taken  : std_logic;
      variable addr_tag   : std_logic_vector(TAG_SIZE-1 downto 0);
    begin
      if rising_edge(clk) then
        tbt_entry := branch_tbt(tbt_raddr);
        if branch_en = '1' then
          branch_tbt(tbt_waddr) <= branch_taken &branch_pc(INDEX_SIZE+2+TAG_SIZE-1 downto INDEX_SIZE+2) & branch_tgt;
        end if;

        tbt_tag    := tbt_entry(REGISTER_SIZE+TAG_SIZE-1 downto REGISTER_SIZE);
        tbt_target := tbt_entry(REGISTER_SIZE-1 downto 0);
        tbt_taken  := tbt_entry(tbt_entry'left);
        addr_tag   := address(INDEX_SIZE+2+TAG_SIZE-1 downto INDEX_SIZE+2);

        prediction_match <= '0';
        if tbt_tag = addr_tag then
          prediction_match <= '1';
        end if;

        if tbt_tag = addr_tag and tbt_taken = '1' then
          generated_pc <= tbt_target;
          br_taken     <= '1';
        else
          generated_pc <= std_logic_vector(signed(address) + 4);
          br_taken     <= '0';
        end if;
      end if;
    end process;

  end generate use_BP;



  instr_out <= instr;
  pc_out    <= program_counter;
--  next_pc_out <= generated_pc;

  valid_instr_out <= valid_instr;

  read_address <= address;

  process(clk)
  begin
    if rising_edge(clk) then
      if stall = '0' then
        saved_instr_out       <= instr;
        saved_pc_out          <= program_counter;
        saved_next_pc_out     <= generated_pc;
        saved_valid_instr_out <= valid_instr;
      end if;
    end if;
  end process;
end architecture rtl;
