library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_mixed_FIFO_3 is
generic(
wr_width    : integer := 32;
rd_width    : integer := 8;
narrow_addr : integer := 4; 
N           : integer := 3
);  
end tb_mixed_FIFO_3;

architecture Behavioral of tb_mixed_FIFO_3 is

-- COMPONENT DECLARATION
component mixed_width_async_FIFO is
generic (
	wr_width    : integer := 32;
	rd_width    : integer := 8;
	narrow_addr : integer := 4;   
    N           : integer := 3    
);
port (
    clk_wr : in  std_logic;
    rst_wr : in  std_logic;
	en_wr  : in  std_logic;
	din    : in  std_logic_vector(wr_width-1 downto 0);
    full   : out std_logic;
    clk_rd : in  std_logic;
    rst_rd : in  std_logic;
    en_rd  : in  std_logic;
    dout   : out std_logic_vector(rd_width-1 downto 0);
    empty  : out std_logic
);
end component;
 
signal     clk_wr       : std_logic := '0';
signal     rst_wr       : std_logic := '0';
signal     en_wr        : std_logic := '0';
signal     din          : std_logic_vector(wr_width-1 downto 0) := (others => '0');
signal     full         : std_logic := '0';
signal     clk_rd       : std_logic := '0'; 
signal     rst_rd       : std_logic := '0';
signal     en_rd        : std_logic := '0';
signal     dout         : std_logic_vector(rd_width-1 downto 0) := (others => '0');
signal     empty        : std_logic := '0';



constant c_clk100mperiod : time := 10 ns;
constant c_clk133mperiod : time := 7.5 ns;


begin


DUT : mixed_width_async_FIFO
generic map(
wr_width       => wr_width      ,      
rd_width       => rd_width      ,
narrow_addr    => narrow_addr   ,
N              => N             
)
port map(
clk_wr         => clk_wr        ,
rst_wr         => rst_wr        ,
en_wr          => en_wr         ,
din            => din           ,
full           => full          ,
clk_rd         => clk_rd        ,
rst_rd         => rst_rd        ,
en_rd          => en_rd         ,
dout           => dout          ,
empty          => empty  
);

P_CLK_WR : process begin

clk_wr <= '0';
wait for c_clk100mperiod/2;
clk_wr <= '1';
wait for c_clk100mperiod/2;

end process P_CLK_WR;


P_CLK_RD : process begin

clk_rd <= '0';
wait for c_clk133mperiod/2;
clk_rd <= '1';
wait for c_clk133mperiod/2;

end process P_CLK_RD;


P_STIMULI : process begin

    -- Reset both domains
    rst_wr <= '1';
    rst_rd <= '1';
    wait for 100 ns;
    wait until falling_edge(clk_wr);
    rst_wr <= '0';
    rst_rd <= '0';



	wait until falling_edge(clk_wr);
	en_wr <= '1';
	din   <= x"04030201";
	wait until rising_edge(clk_wr);
	en_wr <= '0';
	
	wait until falling_edge(clk_wr);
	en_wr <= '1';
	din   <= x"08070605";
	wait until rising_edge(clk_wr);
	en_wr <= '0';
	
	wait until falling_edge(clk_wr);
	en_wr <= '1';
	din   <= x"0C0B0A09";
	wait until rising_edge(clk_wr);
	en_wr <= '0';
	
	wait until falling_edge(clk_wr);
	en_wr <= '1';
	din   <= x"100F0E0D";
	wait until rising_edge(clk_wr);
	en_wr <= '0';
	
	wait until falling_edge(clk_wr);
	en_wr <= '1';
	din   <= x"FFFFFFFF";
	wait until rising_edge(clk_wr);
	en_wr <= '0';
		

    wait for 100 ns;  


    for i in 0 to 15 loop 
		wait until falling_edge(clk_rd);
		en_rd <= '1';
		wait until rising_edge(clk_rd);
		en_rd <= '0';
	end loop;

    wait for 200 ns;

    assert false
    report "SIM DONE"
    severity failure;



end process P_STIMULI;

end Behavioral;