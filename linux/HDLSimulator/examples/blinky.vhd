-- LED blinker: toggles led every HALF_PERIOD clock cycles.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity blinky is
    generic (
        HALF_PERIOD : natural := 25_000_000
    );
    port (
        clk   : in  std_logic;
        rst_n : in  std_logic;
        led   : out std_logic
    );
end entity;

architecture rtl of blinky is
    signal count : unsigned(31 downto 0) := (others => '0');
    signal state : std_logic := '0';
begin
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            count <= (others => '0');
            state <= '0';
        elsif rising_edge(clk) then
            if count = HALF_PERIOD - 1 then
                count <= (others => '0');
                state <= not state;
            else
                count <= count + 1;
            end if;
        end if;
    end process;

    led <= state;
end architecture;
