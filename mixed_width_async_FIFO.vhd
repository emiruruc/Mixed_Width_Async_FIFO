--------------------------------------------------------------------------------
-- Mixed-width asynchronous FIFO
-- Author : Emir Uruç
--
-- Dual-clock FIFO whose write and read ports have different data widths
-- (e.g. 8-bit write / 32-bit read, 32-bit write / 8-bit read, or equal widths).
-- Data is stored in 2**narrow_addr locations of the narrower width. The wider
-- port moves R = wide_width / narrow_width consecutive locations per access.
--
-- How it works
--   * Each side keeps a binary pointer with one extra wrap bit. The wide-side
--     pointer counts wide words, so it steps by 1 and its Gray code changes
--     only one bit per step.
--   * Gray pointers cross to the other clock domain through an N-stage
--     synchronizer, are converted back to binary, and only then scaled to
--     narrow-word units (x R) for comparison. Scaling before the Gray
--     conversion would change two bits per step and break the CDC rule.
--   * full  is computed in the write clock domain (own write pointer vs.
--     synchronized read pointer); empty is computed in the read clock domain.
--
--
-- Behaviour
--   * A write is accepted when en_wr = '1' and full = '0'; a read when
--     en_rd = '1' and empty = '0'. Other requests are ignored.
--   * dout is registered: the data appears one clock after an accepted read.s
--   * Word order: the first narrow word written is the least significant part
--     of the wide word (on both the write and the read side).
--   * A wide write needs R free locations (otherwise full); a wide read needs
--     R stored locations (otherwise empty). A partly filled wide word is
--     never flushed.
--
-- Limitations / constraints
--   * The width ratio must be a power of two and the wide width a multiple of
--     the narrow width (R = 1, 2, 4, 8, ...). 
--   * Narrow_addr should be larger than log2(R); very small values and N < 2 were
--     not tested.
--   * Depth is 2**narrow_addr narrow words (e.g. 16 bytes = 4 words of 32 bit).
--   * rst_wr and rst_rd are independent: assert them together and hold them
--     for several cycles of both clocks before the first access.
--   * Several locations are accessed per clock, so the memory is likely
--     implemented in distributed RAM / registers rather than block RAM.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mixed_width_async_FIFO is
    generic (
        wr_width    : integer := 8;   -- write data width in bits
        rd_width    : integer := 32;  -- read data width in bits
        narrow_addr : integer := 4;   -- depth = 2**narrow_addr narrow words (4 -> 16 locations)
        N           : integer := 3    -- number of synchronizer flip-flop stages
    );
    port (
        -- Write port (clk_wr domain)
        clk_wr : in  std_logic;
        rst_wr : in  std_logic;
        en_wr  : in  std_logic;
        din    : in  std_logic_vector(wr_width-1 downto 0);
        full   : out std_logic;

        -- Read port (clk_rd domain)
        clk_rd : in  std_logic;
        rst_rd : in  std_logic;
        en_rd  : in  std_logic;
        dout   : out std_logic_vector(rd_width-1 downto 0);
        empty  : out std_logic
    );
end mixed_width_async_FIFO;


architecture Behavioral of mixed_width_async_FIFO is

    ----------------------------------------------------------------------------
    -- Helper functions
    ----------------------------------------------------------------------------

    -- Width ratio R between the wide and the narrow side (1 when equal)
    function R_value (
        wr_width : in integer;
        rd_width : in integer
    )
        return integer is
        variable r : integer := 0;
    begin
        if (wr_width < rd_width) then
            r := rd_width / wr_width;
        elsif (wr_width > rd_width) then
            r := wr_width / rd_width;
        else -- equal widths
            r := 1;
        end if;
        return r;
    end function;


    -- Width of the narrower side (= width of one RAM location)
    function narrow_value (
        wr_width : in integer;
        rd_width : in integer
    )
        return integer is
        variable narrow : integer := 0;
    begin
        if (wr_width < rd_width) then
            narrow := wr_width;
        elsif (wr_width > rd_width) then
            narrow := rd_width;
        else
            narrow := wr_width;
        end if;
        return narrow;
    end function;


    -- log2(x), rounded up
    function log2 (
        x : positive)
        return natural is
        variable i : natural;
    begin
        i := 0;
        while (2**i < x) and i < 31 loop
            i := i + 1;
        end loop;
        return i;
    end function;


    -- Gray -> binary conversion (works for any vector width)
    function gray_to_bin (
        gray : in unsigned
    )
        return unsigned is
        variable bin : unsigned(gray'range);
    begin
        bin(gray'high) := gray(gray'high);

        for i in gray'high-1 downto gray'low loop
            bin(i) := bin(i+1) xor gray(i);
        end loop;
        return bin;
    end function;


    ----------------------------------------------------------------------------
    -- Derived constants
    ----------------------------------------------------------------------------

    constant r_val        : integer := R_value(wr_width, rd_width);       -- width ratio R
    constant narrow_width : integer := narrow_value(wr_width, rd_width);  -- width of one RAM location
    constant log_r_val    : integer := log2(r_val);                       -- log2(R)
    constant wide_addr    : integer := narrow_addr - log_r_val;           -- address bits of the wide side

    constant is_wr_narrow : boolean := (wr_width < rd_width) or (wr_width = rd_width);

    -- Address bits of each pointer (the signals add one extra wrap bit).
    -- The wide side counts wide words, so it needs log2(R) bits less.
    constant wr_ptr_addr : integer := narrow_addr when is_wr_narrow else wide_addr;
    constant rd_ptr_addr : integer := wide_addr   when is_wr_narrow else narrow_addr;


    ----------------------------------------------------------------------------
    -- Memory
    ----------------------------------------------------------------------------

    type ram_type is array (0 to (2**narrow_addr)-1) of std_logic_vector(narrow_width-1 downto 0);
    signal ram : ram_type := (others => (others => '0'));


    ----------------------------------------------------------------------------
    -- Pointers (own clock domain)
    ----------------------------------------------------------------------------

    signal wr_ptr_bin       : unsigned(wr_ptr_addr downto 0) := (others => '0');
    signal wr_ptr_bin_next  : unsigned(wr_ptr_addr downto 0) := (others => '0');
    signal wr_ptr_gray      : unsigned(wr_ptr_addr downto 0) := (others => '0');
    signal wr_ptr_gray_next : unsigned(wr_ptr_addr downto 0) := (others => '0');

    signal rd_ptr_bin       : unsigned(rd_ptr_addr downto 0) := (others => '0');
    signal rd_ptr_bin_next  : unsigned(rd_ptr_addr downto 0) := (others => '0');
    signal rd_ptr_gray      : unsigned(rd_ptr_addr downto 0) := (others => '0');
    signal rd_ptr_gray_next : unsigned(rd_ptr_addr downto 0) := (others => '0');

    -- Own pointer expressed in narrow-word units (used for addressing and flags)
    signal wr_ptr_bin_fe_scaled : unsigned(narrow_addr downto 0) := (others => '0');
    signal rd_ptr_bin_fe_scaled : unsigned(narrow_addr downto 0) := (others => '0');


    ----------------------------------------------------------------------------
    -- Clock domain crossing
    ----------------------------------------------------------------------------

    -- Synchronizer chains (index N-1 is the input, index 0 the output)
    type reg_1 is array (0 to N-1) of unsigned(wr_ptr_addr downto 0);
    signal wr_to_rd_sync_reg : reg_1 := (others => (others => '0'));

    type reg_2 is array (0 to N-1) of unsigned(rd_ptr_addr downto 0);
    signal rd_to_wr_sync_reg : reg_2 := (others => (others => '0'));

    -- Synchronized Gray pointer from the other domain and its binary value
    signal wr_ptr_gray_sync : unsigned(wr_ptr_addr downto 0) := (others => '0');
    signal rd_ptr_gray_sync : unsigned(rd_ptr_addr downto 0) := (others => '0');
    signal wr_gray_to_bin   : unsigned(wr_ptr_addr downto 0) := (others => '0');
    signal rd_gray_to_bin   : unsigned(rd_ptr_addr downto 0) := (others => '0');

    -- Synchronized pointer of the wide side in narrow-word units
    signal rd_gray_to_bin_scaled : unsigned(narrow_addr downto 0) := (others => '0');
    signal wr_gray_to_bin_scaled : unsigned(narrow_addr downto 0) := (others => '0');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of wr_to_rd_sync_reg : signal is "TRUE";
    attribute ASYNC_REG of rd_to_wr_sync_reg : signal is "TRUE";


    ----------------------------------------------------------------------------
    -- Occupancy and flags
    ----------------------------------------------------------------------------

    signal difference      : unsigned(narrow_addr downto 0) := (others => '0');  -- stored narrow words (wr - rd)
    signal r_greater_check : boolean := false;                                   -- at least R words stored
    signal r_space         : unsigned(narrow_addr downto 0) := (others => '0');  -- free narrow words
    signal r_space_check   : boolean := false;                                   -- at least R words free
    signal wr_fill         : unsigned(narrow_addr downto 0) := (others => '0');  -- stored narrow words, seen by the write side (wr < rd)

    signal full_o  : std_logic := '0';
    signal empty_i : std_logic := '0';


begin

    ----------------------------------------------------------------------------
    -- 1) Next pointer values and Gray encoding
    --    The pointer only advances on an accepted access.
    --    Gray = binary xor (binary >> 1); the MSB stays the same.
    ----------------------------------------------------------------------------

    wr_ptr_bin_next  <= wr_ptr_bin + 1 when (en_wr = '1' and full_o = '0') else wr_ptr_bin;
    wr_ptr_gray_next <= wr_ptr_bin_next xor ('0' & wr_ptr_bin_next(wr_ptr_addr downto 1));

    rd_ptr_bin_next  <= rd_ptr_bin + 1 when (en_rd = '1' and empty_i = '0') else rd_ptr_bin;
    rd_ptr_gray_next <= rd_ptr_bin_next xor ('0' & rd_ptr_bin_next(rd_ptr_addr downto 1));


    ----------------------------------------------------------------------------
    -- 2) Clock domain crossing: Gray pointers through N-stage synchronizers
    ----------------------------------------------------------------------------

    P_WR_TO_RD : process(clk_rd) begin
        if (rising_edge(clk_rd)) then
            if (rst_rd = '1') then
                wr_to_rd_sync_reg <= (others => (others => '0'));
            else
                wr_to_rd_sync_reg(N-1) <= wr_ptr_gray;
                for i in 0 to N-2 loop
                    wr_to_rd_sync_reg(i) <= wr_to_rd_sync_reg(i+1);
                end loop;
            end if;
        end if;
    end process P_WR_TO_RD;

    wr_ptr_gray_sync <= wr_to_rd_sync_reg(0);


    P_RD_TO_WR : process(clk_wr) begin
        if (rising_edge(clk_wr)) then
            if (rst_wr = '1') then
                rd_to_wr_sync_reg <= (others => (others => '0'));
            else
                rd_to_wr_sync_reg(N-1) <= rd_ptr_gray;
                for i in 0 to N-2 loop
                    rd_to_wr_sync_reg(i) <= rd_to_wr_sync_reg(i+1);
                end loop;
            end if;
        end if;
    end process P_RD_TO_WR;

    rd_ptr_gray_sync <= rd_to_wr_sync_reg(0);


    ----------------------------------------------------------------------------
    -- 3) Synchronized Gray pointers back to binary (receiving domain)
    ----------------------------------------------------------------------------

    wr_gray_to_bin <= gray_to_bin(wr_ptr_gray_sync);
    rd_gray_to_bin <= gray_to_bin(rd_ptr_gray_sync);


    ----------------------------------------------------------------------------
    -- 4) Scaling to narrow-word units (the wide pointer is multiplied by R,
    --    i.e. log2(R) zeros are appended). This happens after the crossing.
    ----------------------------------------------------------------------------

    -- Own (local) pointers
    GEN_SCALE_1 : if (wr_width < rd_width) generate
        rd_ptr_bin_fe_scaled <= rd_ptr_bin & unsigned'(log_r_val-1 downto 0 => '0');
        wr_ptr_bin_fe_scaled <= wr_ptr_bin;
    end generate GEN_SCALE_1;

    GEN_SCALE_2 : if (wr_width > rd_width) generate
        wr_ptr_bin_fe_scaled <= wr_ptr_bin & unsigned'(log_r_val-1 downto 0 => '0');
        rd_ptr_bin_fe_scaled <= rd_ptr_bin;
    end generate GEN_SCALE_2;

    GEN_SCALE_3 : if (wr_width = rd_width) generate
        wr_ptr_bin_fe_scaled <= wr_ptr_bin; -- no scaling, it would also be rd_ptr_bin
        rd_ptr_bin_fe_scaled <= rd_ptr_bin; -- no scaling, it would also be wr_ptr_bin
    end generate GEN_SCALE_3;

    -- Synchronized pointers coming from the wide side
    --   case 1: wr_fill = stored words as seen by the write side
    --   case 2: scaled write pointer, compared with rd_ptr_bin for empty
    GEN_SYNC_SCALE_1 : if (wr_width < rd_width) generate
        rd_gray_to_bin_scaled <= rd_gray_to_bin & unsigned'(log_r_val-1 downto 0 => '0');
        wr_fill               <= wr_ptr_bin - rd_gray_to_bin_scaled;
    end generate GEN_SYNC_SCALE_1;

    GEN_SYNC_SCALE_2 : if (wr_width > rd_width) generate
        wr_gray_to_bin_scaled <= wr_gray_to_bin & unsigned'(log_r_val-1 downto 0 => '0');
    end generate GEN_SYNC_SCALE_2;


    ----------------------------------------------------------------------------
    -- 5) Occupancy in narrow words (write pointer - read pointer)
    --    case 1: computed in the read domain (used for empty)
    --    case 2: computed in the write domain (used for full)
    --    case 3: not needed, flags use a direct Gray comparison
    ----------------------------------------------------------------------------

    GEN_R_CHECK_1 : if (wr_width < rd_width) generate
        difference <= wr_gray_to_bin - rd_ptr_bin_fe_scaled;
    end generate GEN_R_CHECK_1;

    GEN_R_CHECK_2 : if (wr_width > rd_width) generate
        difference <= wr_ptr_bin_fe_scaled - rd_gray_to_bin;
    end generate GEN_R_CHECK_2;

    GEN_R_CHECK_3 : if (wr_width = rd_width) generate
        difference <= (others => '0');
    end generate GEN_R_CHECK_3;

    r_greater_check <= true when (difference >= r_val) else false;

    r_space         <= to_unsigned(2**narrow_addr, narrow_addr+1) - difference;
    r_space_check   <= true when (r_space >= r_val) else false;


    ----------------------------------------------------------------------------
    -- 6) Full / empty flags
    --    full  : write clock domain (own write pointer, synchronized read pointer)
    --    empty : read clock domain  (own read pointer, synchronized write pointer)
    ----------------------------------------------------------------------------

    -- Write narrow, read wide
    GEN_FULL_EMPTY_CHECK1 : if (wr_width < rd_width) generate
        full_o  <= '1' when wr_fill(narrow_addr) = '1' else '0';  -- all 2**narrow_addr locations used
        empty_i <= '1' when not r_greater_check else '0';         -- fewer than R words stored
    end generate GEN_FULL_EMPTY_CHECK1;

    -- Write wide, read narrow
    GEN_FULL_EMPTY_CHECK2 : if (wr_width > rd_width) generate
        full_o  <= '1' when NOT r_space_check else '0';           -- fewer than R locations free
        empty_i <= '1' when rd_ptr_bin = wr_gray_to_bin_scaled else '0';
    end generate GEN_FULL_EMPTY_CHECK2;

    -- Equal widths: classic Gray-code comparison
    GEN_FULL_EMPTY_CHECK3 : if (wr_width = rd_width) generate
        full_o  <= '1' when wr_ptr_gray = (not rd_ptr_gray_sync(narrow_addr downto narrow_addr-1) &
                                           rd_ptr_gray_sync(narrow_addr-2 downto 0))
                   else '0';
        empty_i <= '1' when rd_ptr_gray = wr_ptr_gray_sync else '0';
    end generate GEN_FULL_EMPTY_CHECK3;

    full  <= full_o;
    empty <= empty_i;


    ----------------------------------------------------------------------------
    -- 7) Memory access and pointer registers
    ----------------------------------------------------------------------------

    -- Write narrow (one location), read wide (R locations at once)
    GEN_RD_WIDE : if (wr_width < rd_width) generate

        P_WRITE_NARROW : process(clk_wr) begin
            if (rising_edge(clk_wr)) then
                if (rst_wr = '1') then
                    wr_ptr_bin  <= (others => '0');
                    wr_ptr_gray <= (others => '0');
                elsif (en_wr = '1' and full_o = '0') then
                    wr_ptr_bin  <= wr_ptr_bin_next;
                    wr_ptr_gray <= wr_ptr_gray_next;
                    ram(to_integer(wr_ptr_bin(narrow_addr-1 downto 0))) <= din;
                end if;
            end if;
        end process P_WRITE_NARROW;

        P_READ_WIDE : process(clk_rd) begin
            if (rising_edge(clk_rd)) then
                if (rst_rd = '1') then
                    rd_ptr_bin  <= (others => '0');
                    rd_ptr_gray <= (others => '0');
                    dout        <= (others => '0');
                elsif (en_rd = '1' and empty_i = '0') then
                    rd_ptr_bin  <= rd_ptr_bin_next;
                    rd_ptr_gray <= rd_ptr_gray_next;
                    for i in 0 to r_val-1 loop
                        dout((i+1)*narrow_width - 1 downto i*narrow_width) <=
                            ram(to_integer(rd_ptr_bin_fe_scaled(narrow_addr-1 downto 0) + to_unsigned(i, narrow_addr)));
                    end loop;
                end if;
            end if;
        end process P_READ_WIDE;

    end generate GEN_RD_WIDE;


    -- Write wide (R locations at once), read narrow (one location)
    GEN_WR_WIDE : if (wr_width > rd_width) generate

        P_WRITE_WIDE : process(clk_wr) begin
            if (rising_edge(clk_wr)) then
                if (rst_wr = '1') then
                    wr_ptr_bin  <= (others => '0');
                    wr_ptr_gray <= (others => '0');
                elsif (en_wr = '1' and full_o = '0') then
                    wr_ptr_bin  <= wr_ptr_bin_next;
                    wr_ptr_gray <= wr_ptr_gray_next;
                    for i in 0 to r_val-1 loop
                        ram(to_integer(wr_ptr_bin_fe_scaled(narrow_addr-1 downto 0) + to_unsigned(i, narrow_addr))) <=
                            din((i+1)*narrow_width - 1 downto i*narrow_width);
                    end loop;
                end if;
            end if;
        end process P_WRITE_WIDE;

        P_READ_NARROW : process(clk_rd) begin
            if (rising_edge(clk_rd)) then
                if (rst_rd = '1') then
                    rd_ptr_bin  <= (others => '0');
                    rd_ptr_gray <= (others => '0');
                    dout        <= (others => '0');
                elsif (en_rd = '1' and empty_i = '0') then
                    rd_ptr_bin  <= rd_ptr_bin_next;
                    rd_ptr_gray <= rd_ptr_gray_next;
                    dout        <= ram(to_integer(rd_ptr_bin(narrow_addr-1 downto 0)));
                end if;
            end if;
        end process P_READ_NARROW;

    end generate GEN_WR_WIDE;


    -- Equal widths
    GEN_EQUAL : if (wr_width = rd_width) generate

        P_WRITE : process(clk_wr) begin
            if (rising_edge(clk_wr)) then
                if (rst_wr = '1') then
                    wr_ptr_bin  <= (others => '0');
                    wr_ptr_gray <= (others => '0');
                elsif (en_wr = '1' and full_o = '0') then
                    wr_ptr_bin  <= wr_ptr_bin_next;
                    wr_ptr_gray <= wr_ptr_gray_next;
                    ram(to_integer(wr_ptr_bin(narrow_addr-1 downto 0))) <= din;
                end if;
            end if;
        end process P_WRITE;

        P_READ : process(clk_rd) begin
            if (rising_edge(clk_rd)) then
                if (rst_rd = '1') then
                    rd_ptr_bin  <= (others => '0');
                    rd_ptr_gray <= (others => '0');
                    dout        <= (others => '0');
                elsif (en_rd = '1' and empty_i = '0') then
                    rd_ptr_bin  <= rd_ptr_bin_next;
                    rd_ptr_gray <= rd_ptr_gray_next;
                    dout        <= ram(to_integer(rd_ptr_bin(narrow_addr-1 downto 0)));
                end if;
            end if;
        end process P_READ;

    end generate GEN_EQUAL;

end Behavioral;