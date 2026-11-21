-- Minimal GHDL testbench for the MiSTer a8core (atari800core_simple_sdram).
-- Provides a behavioural 2 MB SDRAM (the Karabas low_memory=4 RAM window),
-- an idle SIO bus and an idle keyboard.  It is the base for the ATR/SIO
-- testbench (tb_atari_numen) and lets us verify that the core boots, that
-- VIDEO_VS/HS run at the PAL rate and that POKEY produces audio.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_atari_core is
	generic
	(
		run_ms : integer := 80
	);
end tb_atari_core;

architecture sim of tb_atari_core is
	constant CLK_PERIOD : time := 35 ns;   -- 28.571 MHz = 16 * 1.79 MHz

	signal clk        : std_logic := '0';
	signal reset      : std_logic := '1';
	signal power_rst  : std_logic := '1';
	signal running    : boolean := true;

	-- core outputs
	signal video_vs, video_hs, video_cs, video_blank, video_pixce : std_logic;
	signal video_burst, video_sof, video_odd : std_logic;
	signal video_r, video_g, video_b : std_logic_vector(7 downto 0);
	signal hblank, vblank : std_logic;
	signal audio_l, audio_r : std_logic_vector(15 downto 0);
	signal kb_scan : std_logic_vector(5 downto 0);
	signal sio_command, sio_txd, sio_clock, sio_motor : std_logic;
	signal porta_out : std_logic_vector(7 downto 0);
	signal emu_flash_req, emu_flash_slave : std_logic;

	-- SDRAM
	signal sdram_req, sdram_complete, sdram_rd, sdram_wr, sdram_refresh : std_logic;
	signal sdram_addr : std_logic_vector(24 downto 0);
	signal sdram_di, sdram_do : std_logic_vector(31 downto 0);
	signal sdram_8, sdram_16, sdram_32 : std_logic;

	constant POKEY_CFG : std_logic_vector(38 downto 0) :=
		"001" & "000" & "01" & '0' & "00" & "00" & "010" & "010" &
		'1' & '1' & '1' & "11" & '0' & '1' & '0' & "10" & "11" &
		"0100" & "11" & '1' & '0';

	signal vs_cnt : integer := 0;
	signal hs_cnt : integer := 0;
	signal audio_nonzero : integer := 0;
	signal last_vs : std_logic := '1';
	signal last_hs : std_logic := '1';
	signal done : boolean := false;
begin
	clk <= not clk after CLK_PERIOD / 2 when running else '0';

	-- ---------------------------------------------------------------- core
	core : entity work.atari800core_simple_sdram
		generic map
		(
			cycle_length => 16,
			video_bits   => 8,
			palette      => 1,
			internal_rom => 1,
			internal_ram => 0,
			low_memory   => 4
		)
		port map
		(
			CLK => clk,
			RESET_N => not reset,
			POWER_RESET => power_rst,

			VIDEO_VS => video_vs,
			VIDEO_HS => video_hs,
			VIDEO_CS => video_cs,
			VIDEO_B => video_b,
			VIDEO_G => video_g,
			VIDEO_R => video_r,
			VIDEO_BLANK => video_blank,
			VIDEO_PIXCE => video_pixce,
			VIDEO_BURST => video_burst,
			VIDEO_START_OF_FIELD => video_sof,
			VIDEO_ODD_LINE => video_odd,
			interlace_field => open,
			interlace => open,
			interlace_enable => '0',

			HBLANK => hblank,
			VBLANK => vblank,

			POKEYMAX_CONFIG => POKEY_CFG,
			AUDIO_L => audio_l,
			AUDIO_R => audio_r,

			JOY1_n => "11111",
			JOY2_n => "11111",
			JOY3_n => "11111",
			JOY4_n => "11111",
			PADDLE0 => to_signed(-128, 8),
			PADDLE1 => to_signed(-128, 8),
			PADDLE2 => to_signed(-128, 8),
			PADDLE3 => to_signed(-128, 8),
			PADDLE4 => to_signed(-128, 8),
			PADDLE5 => to_signed(-128, 8),
			PADDLE6 => to_signed(-128, 8),
			PADDLE7 => to_signed(-128, 8),

			KEYBOARD_RESPONSE => "11",
			KEYBOARD_SCAN => kb_scan,

			SIO_COMMAND => sio_command,
			SIO_RXD => '1',
			SIO_TXD => sio_txd,
			SIO_CLOCK => sio_clock,
			SIO_CLOCK_IN => '1',
			SIO_PROC => '1',
			SIO_IRQ => '1',
			SIO_MOTOR => sio_motor,
			TAPE_AUDIO => x"00",
			ENABLE_179_EARLY => open,
			PORTA_OUT_EXP => porta_out,

			CONSOL_OPTION => '1',
			CONSOL_SELECT => '1',
			CONSOL_START => '1',

			SDRAM_REQUEST => sdram_req,
			SDRAM_REQUEST_COMPLETE => sdram_complete,
			SDRAM_READ_ENABLE => sdram_rd,
			SDRAM_WRITE_ENABLE => sdram_wr,
			SDRAM_ADDR => sdram_addr,
			SDRAM_DO => sdram_do,
			SDRAM_DI => sdram_di,
			SDRAM_32BIT_WRITE_ENABLE => sdram_32,
			SDRAM_16BIT_WRITE_ENABLE => sdram_16,
			SDRAM_8BIT_WRITE_ENABLE => sdram_8,
			SDRAM_REFRESH => sdram_refresh,

			DMA_FETCH => '0',
			DMA_READ_ENABLE => '0',
			DMA_32BIT_WRITE_ENABLE => '0',
			DMA_16BIT_WRITE_ENABLE => '0',
			DMA_8BIT_WRITE_ENABLE => '0',
			DMA_ADDR => (others => '0'),
			DMA_WRITE_DATA => (others => '0'),
			MEMORY_READY_DMA => open,
			DMA_MEMORY_DATA => open,

			RAM_SELECT => "011",  -- 320K RAMBO
			PAL => '1',
			CLIP_SIDES => '0',
			GTIA_XCOLOR => '0',
			RESET_RNMI => '0',
			ATARI800MODE => '0',
			ATARI800MODE_16K => '0',
			PBI_ROM_MODE => '0',
			XEX_LOADER_MODE => '0',
			RTC => (others => '0'),
			CLK_CONF => (others => '0'),
			VBXE_SWITCH => '0',
			VBXE_REG_BASE => '0',
			VBXE_VER_127 => '0',
			VBXE_TURBO => '0',
			VBXE_PALETTE_RGB => (others => '0'),
			VBXE_PALETTE_INDEX => (others => '0'),
			VBXE_PALETTE_COLOR => (others => '0'),

			HALT => '0',
			THROTTLE_COUNT_6502 => "001111",
			emulated_cartridge_select => x"00",
			emulated_cartridge2_select => x"00",
			EMU_FLASH_REQUEST => emu_flash_req,
			EMU_FLASH_SLAVE => emu_flash_slave,
			freezer_enable => '0',
			freezer_activate => '0'
		);

	-- ---------------------------------------------------------------- SDRAM
	-- 2 MB byte-addressed RAM.  The core issues a request, we latch it,
	-- perform the access, then pulse COMPLETE once the request is gone.
	sdram : process(clk)
		type mem_t is array (0 to 2 * 1024 * 1024 - 1) of std_logic_vector(7 downto 0);
		variable mem : mem_t := (others => x"00");
		variable req_d : std_logic := '0';
		variable pending : std_logic := '0';
		variable done_r : std_logic := '0';
		variable a_r : unsigned(24 downto 0);
		variable di_r : std_logic_vector(31 downto 0);
		variable we_r, b8_r, b16_r, b32_r : std_logic;
		variable base : integer;
		variable do_r : std_logic_vector(31 downto 0);
	begin
		if rising_edge(clk) then
			sdram_complete <= '0';
			if sdram_req = '1' and req_d = '0' then
				req_d := '1';
				a_r := unsigned(sdram_addr);
				di_r := sdram_di;
				we_r := sdram_wr;
				b8_r := sdram_8;
				b16_r := sdram_16;
				b32_r := sdram_32;
				pending := '1';
			elsif sdram_req = '0' then
				req_d := '0';
				if pending = '1' then
					base := to_integer(a_r(21 downto 2)) * 4;
					if we_r = '1' then
						if b8_r = '1' then
							mem(to_integer(a_r(21 downto 0))) := di_r(7 downto 0);
						elsif b16_r = '1' then
							mem(base) := di_r(7 downto 0);
							mem(base + 1) := di_r(15 downto 8);
						else
							mem(base) := di_r(7 downto 0);
							mem(base + 1) := di_r(15 downto 8);
							mem(base + 2) := di_r(23 downto 16);
							mem(base + 3) := di_r(31 downto 24);
						end if;
					else
						do_r := mem(base + 3) & mem(base + 2) & mem(base + 1) & mem(base);
						sdram_do <= do_r;
					end if;
					pending := '0';
					done_r := '1';
				elsif done_r = '1' then
					sdram_complete <= '1';
					done_r := '0';
				end if;
			end if;
		end if;
	end process;

	-- ---------------------------------------------------------------- reset
	reset <= '1', '0' after 2 us;
	power_rst <= '1', '0' after 2 us;

	-- ---------------------------------------------------------------- monitor
	mon : process(clk)
	begin
		if rising_edge(clk) then
			if video_vs = '0' and last_vs = '1' then
				vs_cnt <= vs_cnt + 1;
			end if;
			last_vs <= video_vs;
			if video_hs = '0' and last_hs = '1' then
				hs_cnt <= hs_cnt + 1;
			end if;
			last_hs <= video_hs;
			if audio_l /= x"0000" or audio_r /= x"0000" then
				audio_nonzero <= audio_nonzero + 1;
			end if;
		end if;
	end process;

	-- ---------------------------------------------------------------- stop
	stop : process
	begin
		wait for run_ms * 1 ms;
		report "TB: " & integer'image(run_ms) & " ms, VS=" & integer'image(vs_cnt) &
		       " HS=" & integer'image(hs_cnt) &
		       " audio_nonzero=" & integer'image(audio_nonzero) &
		       " sio_cmd=" & std_logic'image(sio_command) &
		       " sio_clk=" & std_logic'image(sio_clock) &
		       " sio_txd=" & std_logic'image(sio_txd) &
		       " vs_state=" & std_logic'image(video_vs) &
		       " hs_state=" & std_logic'image(video_hs);
		done <= true;
		running <= false;
		wait;
	end process;

end sim;
