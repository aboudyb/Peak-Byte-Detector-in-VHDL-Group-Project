library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.common_pack.all;

entity dataConsume is
  	port (
	    clk:		  in std_logic;                               -- 100MHz clock
		reset:		  in std_logic;                               -- synchronous high reset
		start:        in std_logic;                               -- goes high to signal data transfer
		numWords_bcd: in BCD_ARRAY_TYPE(2 downto 0);              -- number of bytes to process 
		ctrlIn:       in std_logic;                               -- changes if data ready in dataGen
		ctrlOut:      out std_logic;                              -- change to request data from dataGen
		data:         in std_logic_vector(7 downto 0);            -- incomming byte from dataGen
		dataReady:    out std_logic;                              -- asssert high to tell command processor a new byte is ready on the byte line
		byte:         out std_logic_vector(7 downto 0);           -- put new byte from data gen here to pass to command processor 
		seqDone:      out std_logic;                              -- asserted high when the number of bytes as specified by numWords has been processed 
		maxIndex:     out BCD_ARRAY_TYPE(2 downto 0);             -- contains the index of the peak
		dataResults:  out CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1) -- index 3 holds the peak
  	);
end dataConsume;

architecture Behavioral of dataConsume is
-- signal declarations
    type state_type is (initial, dataRequest, dataProcess, finalByte, shiftZero, sequenceDone, resetState, idle1, idle2, idle3);
    signal curState, nextState: state_type;
    signal dataMax, dataReg: CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1);
    signal shiftEn, countEn, countRst, indexEn, indexRst, shiftRst, compRst, shift0, ctrlEn, ctrlEnDetected, ctrlRst, ctrlInDetected, ctrlInReg, ctrlOReg, startReg, startDetected: std_ulogic;
    signal counter, numWords: integer;
    signal index : BCD_ARRAY_TYPE(2 downto 0);
    
begin
    
    dataShift: process(clk) -- 7 register right shifter to "pull in" newest byte from dataGen
        variable dataTemp: CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1);
    begin
        if clk'event and clk = '1' then
            if shiftRst = '1' then
                for i in 0 to 6 loop
                    dataTemp(i) := "00000000";
                end loop;
            elsif shiftEn = '1' then
                for i in 0 to 5 loop
                    dataTemp(i) := dataTemp(i+1);
                end loop;
                if shift0 = '0' then
                    dataTemp(6) := data;
                else
                    dataTemp(6) := "00000000";
                end if;
            end if;
        end if;
        dataReg <= dataTemp;
    end process;
     
     dataCompare: process(clk) -- compares currently held peak to incoming byte
     begin
        if clk = '1' and clk'event then
            if compRst = '1' then
                for i in 0 to 6 loop
                    dataMax(i) <= "00000000";
                end loop; 
            
            elsif dataReg(3) > dataMax(3) then
                dataMax <= dataReg;
                maxIndex <= index;
                
            end if;
        end if; 
     end process; 
     
     count: process(clk) -- simple incremental counter
        variable count: integer;
     begin
     if clk'event and clk = '1' then
        if countRst = '1' then
            count := 0;
        elsif countEn = '1' then
            count := count + 1;
        end if;
     end if;
     counter <= count;
     end process; 
     
     indexCount: process(clk) -- incremental counter, counts in BCD to prevent conversion of int to BCD 
        variable indexVar: BCD_ARRAY_TYPE(2 downto 0);
        variable hundred, ten, unit : integer;
     begin
     if clk'event and clk = '1' then
        if indexRst = '1' then
            for i in 0 to 2 loop
                indexVar(i) := "0000";
            end loop;
            hundred := 0;
            ten := 0;
            unit := -4;
        
        elsif indexEn = '1' then
            unit := unit + 1;
            if unit = 10 then
                unit := 0;
                ten := ten + 1;
                if ten = 10 then
                    ten := 0;
                    hundred := hundred + 1;
                end if;
            end if;
        end if;
        indexVar(2) := std_logic_vector(TO_UNSIGNED(hundred, 4));
        indexVar(1) := std_logic_vector(TO_UNSIGNED(ten, 4));
        indexVar(0) := std_logic_vector(TO_UNSIGNED(unit, 4));
     end if;
     index <= indexVar;
     end process; 

     BCD_to_int: process(numWords_bcd) -- converts numWords_bcd to integer that we can work on logically 
        variable hundreds, tens, ones: integer;
     begin
        hundreds := TO_INTEGER(unsigned(numWords_bcd(2)))*100;
        tens := TO_INTEGER(unsigned(numWords_bcd(1)))*10;
        ones := TO_INTEGER(unsigned(numWords_bcd(0)));
        numWords <= hundreds + tens + ones;
     end process;
     
     ctrlO: process(clk) -- used to correctly output ctrlOut as it uses two-phase signalling 
        variable ctrlVar: std_ulogic;
     begin
     if clk'event and clk = '1' then
        if ctrlRst = '1' then
            ctrlVar := '0';
        elsif ctrlEnDetected = '1' and ctrlEn = '1' then
            ctrlVar := not ctrlVar;
        end if;
     end if;
     ctrlOut <= ctrlVar;
     end process;
     
     EdgeDetect: process(clk) -- used to detect both rising and falling edges for the two-phase signalling used in dataGen
     begin
        if clk = '1' and clk'event then
            ctrlInReg <= ctrlIn;
            ctrlOReg <= CtrlEn;
        end if;
     end process;
     
     ctrlEnDetected <= ctrlOReg xor CtrlEn;
     ctrlInDetected <= ctrlInReg xor ctrlIn;
   
     seq_state: process(clk) -- progresses onto nextState as defined by the FSM diagram on rising clock edge
     begin      
        if clk'event and clk = '1' then
            if reset = '1' then
                curState <= initial;
            else
                curState <= nextState; 
            end if;
        end if;
     end process; 
    
     combi_out: process(curState, data, dataMax) -- signal output from FSM
     begin
     -- default singal declarations 
       dataReady <= '0';        
       byte <= data;            -- passses the current byte from dataGen to the command processor,  
       seqDone <= '0';
       dataResults <= dataMax;  -- passes the index and 3 bytes either side to the command Processor, only read when seqDone is high
       shiftEn <= '0';          -- used to enable shifter 1 to the right when data is ready to be read
       shiftRst <= '0';         -- used to reset the values stored in shifters registers
       shift0 <= '0';           -- used to shift a "00000000" into the shifter registers
       countEn <= '0';          -- used to increment counter by 1          
       countRst <= '0';         -- used to reset counter synchronous high
       indexEn <= '0';          -- used to increment index counter by 1
       indexRst <= '0';         -- used to reset the index counter
       compRst <= '0';          -- resets the registers that store max index in the data comparison function
       ctrlEn <= '0';           -- used to trigger ctrlOut, driving it either low or high depending on its prior state
       ctrlRst <= '0';          -- resets the ctrlOut signal to low

       case curState is
        when initial =>                 -- initial state, eveything is reset
            shiftRst <= '1';
            compRst <= '1';
            countRst <= '1';
            indexRst <= '1';
            ctrlRst <= '1';
            
        when dataRequest =>             -- requests data from dataGen
            ctrlEn <= '1';
             
             
        when dataProcess =>             -- processses bytes of data
            dataReady <= '1';
            shiftEn <= '1';
            indexEn <= '1';
            countEn <= '1'; 
            
        when finalByte =>               -- processses last byte of data
            dataReady <= '1';
            shiftEn <= '1';
            countRst <= '1';
            indexEn <= '1';
            
        
        when shiftZero =>               -- shifts 0s to check last 3 bytes of data
            shift0 <= '1';
            shiftEn <= '1';
            countEn <= '1';
            indexEn <= '1';
                
        when sequenceDone =>            -- end of data processsing
            seqDone <= '1';
        
        when resetState =>              -- resests all except dataOut 
            shiftRst <= '1';
            compRst <= '1';
            countRst <= '1';
            indexRst <= '1';
                    
        when others =>                  -- when in any state not defined above no signals declarations are required as theyre all used as idle states with no processing required (idle1, idle2, idle3)

       end case;
      end process;      
       
      next_state: process(curState, ctrlInDetected, counter, numWords, start)   -- Progression through FSM
      begin
        case curState is
            
        when initial =>
            if start = '1' then                                                 -- start data retrival cycle when start goes high
                nextState <= dataRequest;
            else
                nextState <= initial;
            end if;
            
        when dataRequest =>
            if ctrlInDetected = '1' and counter < (numWords - 1) then           -- moves to dataProcess unless we have already processed all required bytes
                nextState <= dataProcess;
            elsif ctrlInDetected = '1'  then                                     -- moves to finalByte if all required bytes have been processed
                nextState <= finalByte;
            else
                nextState <= dataRequest;
            end if;
            
        when idle1 =>
            if start = '1' then                                                 -- wait until start goes high, signalling command processor ready for next byte
                nextState <= dataRequest;
            else 
                nextState <= idle1;
            end if;
            
        when dataProcess =>                                                              -- head to idle1 to wait for command processor to finish processing the byte
            nextState <= idle1;
            
        when finalByte =>
            nextState <= idle2;                                                 -- head to idle2 and wait for command processor to be finished
            
        When idle2 =>
            if start = '1' then
                nextState <= shiftZero;                                                -- wait until start goes high, signalling command processor has finished processing the last byte
            else
                nextState <= idle2;
            end if;
                    
        when shiftZero =>                                                          
            if counter > 1 then                                                 -- if the last 3 bytes have been checked head to S6
                nextState <= idle3;
            elsif counter < 2 then                                              -- go to S5 if there are remaining bytes to be checked
                nextState <= sequenceDone;
            else 
                nextState <= shiftZero;
            end if;
            
        when idle3 =>
            nextState <= shiftZero;                                                
            
        when sequenceDone =>
            nextState <= resetState;                                                -- head to reset state at the end of processing 
            
        when resetState =>
            nextState <= dataRequest;
            
        when others =>                                                      -- if we move to an undefined state we go back to the initial state
            nextState <= initial;
            
        end case;
      end process;
end Behavioral;
