LIBRARY IEEE;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

USE work.common_pack.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

ENTITY cmdProc IS
  PORT (
    clk : IN STD_LOGIC;
    reset : IN STD_LOGIC;

    -- Rx Signals
    rxNow : IN STD_LOGIC;
    rxData : IN STD_LOGIC_VECTOR (7 DOWNTO 0);
    rxDone : OUT STD_LOGIC;
    ovErr : IN STD_LOGIC;
    framErr : IN STD_LOGIC;

    -- Tx Signals
    txNow : OUT STD_LOGIC;
    txDone : IN STD_LOGIC;
    txData : OUT STD_LOGIC_VECTOR (7 DOWNTO 0);

    -- Data Processor Signals
    start : OUT STD_LOGIC;
    numWords_bcd : OUT BCD_ARRAY_TYPE(2 DOWNTO 0);
    dataReady : IN STD_LOGIC;
    byte : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    maxIndex : IN BCD_ARRAY_TYPE(2 DOWNTO 0);
    dataResults : IN CHAR_ARRAY_TYPE(0 TO RESULT_BYTE_NUM - 1);
    seqDone : IN STD_LOGIC);
END cmdProc;

ARCHITECTURE readCommands OF cmdProc IS
  -- types for states
  TYPE stateTypes IS (
    idle, -- s0
    resetState,

    -- if a
    aWaitDig1,
    aWaitDig2,
    aWaitDig3,
    aSendStartCR,
    aSendStartLB, -- s5
    aSendD1,
    aSendD2,
    aSendDLE,
    aSendEndCR,
    aSendEndLB, -- s10

    lSendStartCR,
    lSendStartLB,
    lSendD1,
    lSendD2,
    lSendDLE, -- s15
    lSendEndCR,
    lSendEndLB,

    pSendStartLB,
    pSendStartCR,
    pSendD1, -- s20
    pSendD2,
    pSendDLE,
    pSendInd1,
    pSendInd2,
    pSendInd3, -- s25
    pSendEndLB,
    pSendEndCR
  );

  SIGNAL currState : stateTypes;
  SIGNAL nextState : stateTypes;

  SIGNAL counter : INTEGER;
  SIGNAL counterIncrement, counterReset : STD_LOGIC;

  SIGNAL lCurrentByte : STD_LOGIC_VECTOR(7 DOWNTO 0);

  SIGNAL txBusyMarker : STD_LOGIC;

  -- rxBuffers
  SIGNAL rxNow_buf : STD_LOGIC;
  SIGNAL rxData_buf : STD_LOGIC_VECTOR (7 DOWNTO 0);
  SIGNAL rxDone_buf : STD_LOGIC;
  SIGNAL ovErr_buf : STD_LOGIC;
  SIGNAL framErr_buf : STD_LOGIC;

  -- txBuffers
  SIGNAL txNow_buf : STD_LOGIC;
  SIGNAL txData_buf : STD_LOGIC_VECTOR (7 DOWNTO 0);
  SIGNAL txDone_buf : STD_LOGIC;

  -- data processor buffers
  SIGNAL start_buf : STD_LOGIC;
  SIGNAL numWords_bcd_buf : BCD_ARRAY_TYPE(2 DOWNTO 0);
  SIGNAL dataReady_buf : STD_LOGIC;
  SIGNAL byte_buf : STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL maxIndex_buf : BCD_ARRAY_TYPE(2 DOWNTO 0);
  SIGNAL dataResults_buf : CHAR_ARRAY_TYPE(0 TO RESULT_BYTE_NUM - 1);
  SIGNAL seqDone_buf : STD_LOGIC;

  -- used to determine if a value is stored
  SIGNAL hasProcessed : STD_LOGIC;
  SIGNAL byteAvail : STD_LOGIC;
  SIGNAL byteFinish : STD_LOGIC;
  SIGNAL byteFinishSet, byteFinishReset : STD_LOGIC;
  SIGNAL byteAvailSet, byteAvailReset : STD_LOGIC;
  SIGNAL hasProcessedSet, hasProcessedReset : STD_LOGIC;
  FUNCTION nibble_to_ascii (nibble : STD_LOGIC_VECTOR(3 DOWNTO 0) := "0000") RETURN STD_LOGIC_VECTOR IS
    VARIABLE asciiVal : STD_LOGIC_VECTOR(7 DOWNTO 0);
  BEGIN
    IF nibble < 10 THEN
      asciiVal := "00110000" + nibble;
    ELSE
      asciiVal := "01000001" + nibble - 10;
    END IF;
    RETURN asciiVal;
  END FUNCTION;

BEGIN
  -- Handles clock changes
  seqClock : PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      txBusyMarker <= txNow_buf OR NOT txDone;
      IF reset = '1' THEN
        currState <= resetState;
      ELSE
        currState <= nextState;
      END IF;
    END IF;
  END PROCESS;

  -----------------------------------------------------
  -- All the buffers and such
  storeDataResults : PROCESS (dataResults)
  BEGIN
    dataResults_buf <= dataResults;
  END PROCESS;

  storeMaxIndex : PROCESS (maxIndex)
  BEGIN
    maxIndex_buf <= maxIndex;
  END PROCESS;

  storeByte : PROCESS (byte)
  BEGIN
    byte_buf <= byte;
  END PROCESS;

  setTxBusy : PROCESS (clk, txNow_buf, txDone)
  BEGIN
    IF rising_edge (clk) THEN
      txBusyMarker <= txNow_buf OR NOT txDone;
    END IF;
  END PROCESS;

  byteAvail_reg : PROCESS (clk, byteAvailSet, byteAvailReset)
  BEGIN
    IF rising_edge(clk) THEN
      IF byteAvailReset = '1' THEN
        byteAvail <= '0';
      ELSIF byteAvailSet = '1' THEN
        byteAvail <= '1';
      END IF;
    END IF;
  END PROCESS;

  hasProcessed_reg : PROCESS (clk, hasProcessedSet, hasProcessedReset)
  BEGIN
    IF rising_edge(clk) THEN
      IF hasProcessedReset = '1' THEN
        hasProcessed <= '0';
      ELSIF hasProcessedSet = '1' THEN
        hasProcessed <= '1';
      END IF;
    END IF;
  END PROCESS;

  byteFinish_reg : PROCESS (clk, byteFinishSet, byteFinishReset)
  BEGIN
    IF rising_edge(clk) THEN
      IF byteFinishReset = '1' THEN
        byteFinish <= '0';
      ELSIF byteFinishSet = '1' THEN
        byteFinish <= '1';
      END IF;
    END IF;
  END PROCESS;

  counter_reg : PROCESS (clk, counterIncrement, counterReset)
  BEGIN
    IF rising_edge(clk) THEN
      IF counterReset = '1' THEN
        counter <= 0;
      ELSIF counterIncrement = '1' THEN
        counter <= counter + 1;
      END IF;
    END IF;
  END PROCESS;

  -- rxBuffers
  rxDoneBuffer : PROCESS (clk, rxDone_buf)
  BEGIN
    IF falling_edge (clk) THEN
      rxDone <= rxDone_buf;
    END IF;
  END PROCESS;

  -- txBuffers
  txNowBuffer : PROCESS (clk, txNow_buf)
  BEGIN
    IF falling_edge (clk) THEN
      txNow <= txNow_buf;
    END IF;
  END PROCESS;

  txDataBuffer : PROCESS (clk, txData_buf)
  BEGIN
    IF falling_edge (clk) THEN
      txData <= txData_buf;
    END IF;
  END PROCESS;

  -- data processor buffers
  startBuffer : PROCESS (clk, start_buf)
  BEGIN
    IF falling_edge (clk) THEN
      start <= start_buf;
    END IF;
  END PROCESS;

  numWords_bcdBuffer : PROCESS (clk, numWords_bcd_buf)
  BEGIN
    IF rising_edge (clk) THEN
      numWords_bcd <= numWords_bcd_buf;
    END IF;
  END PROCESS;
  -----------------------------------------------------
  combiStateLogic : PROCESS (currState,
    rxNow,
    txBusyMarker,
    dataReady,
    seqDone,
    rxData,
    hasProcessed,
    byteAvail,
    byteFinish,
    counter,
    byte_buf,
    dataResults_buf,
    maxIndex_buf)
  BEGIN
    rxDone_buf <= '0';
    start_buf <= '0';
    txNow_buf <= '0';
    txData_buf <= "00000000";
    counterIncrement <= '0';
    counterReset <= '0';
    hasProcessedSet <= '0';
    hasProcessedReset <= '0';
    byteAvailSet <= '0';
    byteAvailReset <= '0';
    byteFinishSet <= '0';
    byteFinishReset <= '0';
    numWords_bcd_buf <= (OTHERS => "0000");

    CASE currState IS
      WHEN resetState =>
        -- reset internal signals
        hasProcessedReset <= '1';
        counterReset <= '1';
        -- reset state logic
        nextState <= idle;

      WHEN idle =>
        nextState <= idle;
        IF rxNow = '1' THEN
          rxDone_buf <= '1';
          txData_buf <= rxData;
          txNow_buf <= '1';
          IF rxData = "01000001" OR rxData = "01100001" THEN -- if 'A' or 'a'
            nextState <= aWaitDig1;
          ELSE
            IF hasProcessed = '1' THEN
              IF rxData = "01001100" OR rxData = "01101100" THEN -- if 'L' or 'l'
                nextState <= lSendStartLB;
              ELSIF rxData = "01010000" OR rxData = "01110000" THEN -- if 'P' or 'p'
                nextState <= pSendStartLB;
              END IF;
            END IF;
          END IF;
        END IF;

      WHEN aWaitDig1 =>
        nextState <= aWaitDig1;
        IF rxNow = '1' THEN
          rxDone_buf <= '1';
          txData_buf <= rxData;
          txNow_buf <= '1';
          IF rxData >= "00110000" AND rxData <= "00111001" THEN -- check data is digit
            numWords_bcd_buf(2) <= rxData(3 DOWNTO 0); -- convert to bcd digit and send to data processor
            nextState <= aWaitDig2;
          ELSE
            nextState <= idle; -- go back to idle
          END IF;
        END IF;

      WHEN aWaitDig2 =>
        nextState <= aWaitDig2;
        IF rxNow = '1' THEN
          nextState <= idle; -- go back to idle
          rxDone_buf <= '1';
          txData_buf <= rxData;
          txNow_buf <= '1';
          IF rxData >= "00110000" AND rxData <= "00111001" THEN -- check data is digit
            numWords_bcd_buf(1) <= rxData(3 DOWNTO 0); -- convert to bcd digit and send to data processor
            nextState <= aWaitDig3;
          ELSE
            nextState <= idle; -- go back to idle
          END IF;
        END IF;

      WHEN aWaitDig3 =>
        nextState <= aWaitDig3;
        IF rxNow = '1' THEN
          nextState <= idle; -- go back to idle
          rxDone_buf <= '1';
          txData_buf <= rxData;
          txNow_buf <= '1';
          IF rxData >= "00110000" AND rxData <= "00111001" THEN -- check data is digit
            numWords_bcd_buf(0) <= rxData(3 DOWNTO 0); -- convert to bcd digit and send to data processor
            nextState <= aSendStartLB;
          ELSE
            nextState <= idle; -- go back to idle
          END IF;
        END IF;

      WHEN aSendStartLB =>
        nextState <= aSendStartLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';
          nextState <= aSendStartCR;
        END IF;

      WHEN aSendStartCR =>
        nextState <= aSendStartCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          start_buf <= '1';
          nextState <= aSendD1;
        END IF;

      WHEN aSendD1 =>
        nextState <= aSendD1;
        IF dataReady = '1' THEN -- wait for dataready
          byteAvailSet <= '0';
        ELSE
          byteFinishSet <= '0';
        END IF;

        IF seqDone = '1' THEN -- wait for seqdone
          byteFinishSet <= '1';
        ELSE
          byteFinishSet <= '0';
        END IF;

        IF txBusyMarker = '0' AND byteAvail = '1' THEN -- send first hex of data
          txData_buf <= nibble_to_ascii(byte_buf(7 DOWNTO 4));
          txNow_buf <= '1';
          nextState <= aSendD2;
        END IF;

      WHEN aSendD2 =>
        nextState <= aSendD2;
        IF txBusyMarker = '0' AND byteAvail = '1' THEN -- send second hex of data
          txData_buf <= nibble_to_ascii(byte_buf(3 DOWNTO 0));
          txNow_buf <= '1';
          byteAvailReset <= '1';

          IF byteFinish = '1' THEN
            byteFinishReset <= '1';
            hasProcessedSet <= '1';
            nextState <= aSendEndLB;
          ELSE
            byteFinishReset <= '0';
            hasProcessedSet <= '0';
            nextState <= aSendDLE;
          END IF;
        END IF;

      WHEN aSendDLE =>
        nextState <= aSendDLE;
        IF txBusyMarker = '0' THEN -- send DLE character
          txData_buf <= "00100000";-- Unsure is the current (ASCII Space) is correct or if it should be "00010000" (ASCII DLE) 
          txNow_buf <= '1';
          start_buf <= '1';
          nextState <= aSendD1;
        END IF;

      WHEN aSendEndLB =>
        nextState <= aSendEndLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';

          nextState <= aSendEndCR;
        END IF;

      WHEN aSendEndCR =>
        nextState <= aSendendCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          nextState <= idle;
        END IF;

      WHEN lSendStartLB =>
        nextState <= lSendStartLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';

          nextState <= lSendStartCR;

        END IF;

      WHEN lSendStartCR =>
        nextState <= lSendStartCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          nextState <= lSendD1;
        END IF;
      WHEN lSendD1 =>
        nextState <= lSendD1;

        IF txBusyMarker = '0' THEN -- send first hex of data
          txData_buf <= nibble_to_ascii(dataResults_buf(counter)(7 DOWNTO 4));
          txNow_buf <= '1';
          nextState <= lSendD2;
        END IF;

      WHEN lSendD2 =>
        nextState <= lSendD2;

        IF txBusyMarker = '0' THEN -- send second hex of data
          txData_buf <= nibble_to_ascii(dataResults_buf(counter)(3 DOWNTO 0));
          txNow_buf <= '1';
          nextState <= lSendDLE;

          IF counter = 7 THEN
            counterReset <= '1';
            nextState <= lSendEndLB;
          ELSE
            counterReset <= '0';
          END IF;
        END IF;

      WHEN lSendDLE =>
        nextState <= aSendDLE;

        IF txBusyMarker = '0' THEN -- send first hex of data
          txData_buf <= "00100000";
          txNow_buf <= '1';
          counterIncrement <= '1';
          nextState <= lSendD1;
        ELSE
          counterIncrement <= '0';
        END IF;

      WHEN lSendEndLB =>
        nextState <= aSendEndLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';

          nextState <= lSendEndCR;
        END IF;

      WHEN lSendEndCR =>
        nextState <= lSendEndCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          nextState <= idle;
        END IF;

      WHEN pSendStartLB =>
        nextState <= pSendStartLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';

          nextState <= pSendStartCR;

        END IF;

      WHEN pSendStartCR =>
        nextState <= pSendStartCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          nextState <= pSendD1;
        END IF;

      WHEN pSendD1 =>
        nextState <= pSendD1;
        IF txBusyMarker = '0' THEN -- send first hex of data
          txData_buf <= nibble_to_ascii(dataResults_buf(3)(7 DOWNTO 4));
          txNow_buf <= '1';
          nextState <= pSendD2;
        END IF;
      WHEN pSendD2 =>
        nextState <= pSendD2;

        IF txBusyMarker = '0' THEN -- send first hex of data
          txData_buf <= nibble_to_ascii(dataResults_buf(3)(3 DOWNTO 0));
          txNow_buf <= '1';
          nextState <= pSendDLE;
        END IF;
      WHEN pSendDLE =>
        nextState <= pSendDLE;

        IF txBusyMarker = '0' THEN -- send first hex of data
          txData_buf <= "00100000";
          txNow_buf <= '1';

          nextState <= pSendInd1;
        END IF;

      WHEN pSendInd1 =>
        nextState <= pSendInd1;
        IF txBusyMarker = '0' THEN -- send first digit of data
          txData_buf <= "00110000" + maxIndex_buf(2);
          txNow_buf <= '1';
          nextState <= pSendInd1;
        END IF;

      WHEN pSendInd2 =>
        nextState <= pSendInd2;
        IF txBusyMarker = '0' THEN -- send first digit of data
          txData_buf <= "00110000" + maxIndex_buf(1);
          txNow_buf <= '1';

          nextState <= pSendInd1;
        END IF;
      WHEN pSendInd3 =>
        nextState <= pSendInd3;
        IF txBusyMarker = '0' THEN -- send first digit of data
          txData_buf <= "00110000" + maxIndex_buf(0);
          txNow_buf <= '1';

          nextState <= pSendInd1;
        END IF;
      WHEN pSendEndLB =>
        nextState <= pSendEndLB;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001010";
          txNow_buf <= '1';
          nextState <= pSendEndCR;
        END IF;

      WHEN pSendEndCR =>
        nextState <= pSendEndCR;
        IF txBusyMarker = '0' THEN
          txData_buf <= "00001101";
          txNow_buf <= '1';
          nextState <= idle;
        END IF;

      WHEN OTHERS =>
        nextState <= resetState;
    END CASE;
  END PROCESS;

END readCommands;