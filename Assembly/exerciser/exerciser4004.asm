;=======================================================================
; INTEL 4004 CPU EXERCISER
;
; Self-test of the 4004 instruction set and an MCS-4 system (4001 ROM I/O
; port + 4002 RAM). Runs the suite, blinks a pass pattern, then repeats
; forever, so it can be left running as a burn-in / soak test.
;
; Tests
;   1  Accumulator & carry: CLB CLC STC CMC TCC CMA IAC DAC RAL RAR TCS
;                           KBP DAA
;   2  ADD / SUB with carry and borrow
;   3  All 16 index registers, pattern and complement (LDM/XCH/SUB)
;   4  Pairs & indexing: FIM, LD/XCH swap, INC wrap, ISZ loop, FIN, JIN
;   5  3-level subroutine stack: JMS / BBL (return values checked)
;   6  Conditional jumps: JCN on ACC=0, CY, inverted and combined forms
;   7  4002 RAM: SRC WRM RDM ADM SBM, status chars WR0-3 / RD0-3, two
;      passes (pattern then complement) across all 4 registers, chip 0
;
; Hardware I/O (bank 0, selected by DCL at reset)
;   ROM chip 0 I/O port (WRR) : current test number 1..7 while running.
;                               On a pass, blinks 0xA / 0x5 four times.
;                               On a failure, holds the failing test no.
;   RAM chip 0 output (WMP)   : 0x0 = running (first pass)
;                               0x1 = at least one full pass completed
;                               0xF = FAILED (CPU halts in a tight loop)
;   The TEST pin is not exercised (its level depends on the board).
;
; Register usage: R11 scratch for compares, R13 test number,
;                 P7 (R14:R15) port select, R12 blink counter.
;
; Notes on 4004 semantics this program relies on:
;   SUB r : A = A + ~r + ~CY  -> use CLC first; CY=1 means NO borrow
;   DAC   : CY=1 means NO borrow
;   JCN/ISZ/FIN/JIN are page-relative (page of the following byte)
;=======================================================================

; JCN condition codes
AZ      EQU 4               ; jump if ACC = 0
AN      EQU 12              ; jump if ACC != 0
C1      EQU 2               ; jump if CY = 1
C0      EQU 10              ; jump if CY = 0
AZC1    EQU 6               ; jump if ACC = 0 OR CY = 1
NAZC1   EQU 14              ; jump if ACC != 0 AND CY = 0

        ORG 0x000

RESET:
        LDM 0
        DCL                         ; select RAM bank 0
        FIM P7, 0x00                ; ROM chip 0 / RAM chip 0
        SRC P7
        LDM 0
        WMP                         ; RAM port = 0 (running)
        WRR                         ; ROM port = 0

;======================================================================
; TEST 1: Accumulator and carry operations
;======================================================================
T1:
        LDM 1
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        CLB                         ; A=0, CY=0
        JCN C0, K001                ; fail if C1
        JUN FAIL
K001:
        JCN AZ, K002                ; fail if AN
        JUN FAIL
K002:
        STC
        JCN C1, K003                ; STC sets CY
        JUN FAIL
K003:
        CMC
        JCN C0, K004                ; CMC clears it
        JUN FAIL
K004:
        CMC
        JCN C1, K005                ; CMC sets it
        JUN FAIL
K005:
        CLC
        JCN C0, K006                ; CLC clears it
        JUN FAIL
K006:
        STC
        TCC                         ; A=CY=1, CY=0
        JCN C0, K007                ; fail if C1
        JUN FAIL
K007:
        XCH R11                     ; expect A = 1
        LDM 1
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K008                ; fail if AN
        JUN FAIL
K008:
        LDM 5
        CMA                         ; ~0101 = 1010
        XCH R11                     ; expect A = 10
        LDM 10
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K009                ; fail if AN
        JUN FAIL
K009:
        LDM 15
        CLC
        IAC                         ; F+1 = 0, CY=1
        JCN C1, K010                ; fail if C0
        JUN FAIL
K010:
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K011                ; fail if AN
        JUN FAIL
K011:
        LDM 0
        DAC                         ; 0-1 = F, CY=0 (borrow)
        JCN C0, K012                ; fail if C1
        JUN FAIL
K012:
        XCH R11                     ; expect A = 15
        LDM 15
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K013                ; fail if AN
        JUN FAIL
K013:
        LDM 5
        DAC                         ; 5-1 = 4, CY=1 (no borrow)
        JCN C1, K014                ; fail if C0
        JUN FAIL
K014:
        XCH R11                     ; expect A = 4
        LDM 4
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K015                ; fail if AN
        JUN FAIL
K015:
        LDM 8
        CLC
        RAL                         ; 1000 -> 0000, CY=1
        JCN C1, K016                ; fail if C0
        JUN FAIL
K016:
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K017                ; fail if AN
        JUN FAIL
K017:
        LDM 0
        STC
        RAL                         ; CY rotates into bit0
        JCN C0, K018                ; fail if C1
        JUN FAIL
K018:
        XCH R11                     ; expect A = 1
        LDM 1
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K019                ; fail if AN
        JUN FAIL
K019:
        LDM 1
        CLC
        RAR                         ; 0001 -> 0000, CY=1
        JCN C1, K020                ; fail if C0
        JUN FAIL
K020:
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K021                ; fail if AN
        JUN FAIL
K021:
        LDM 0
        STC
        RAR                         ; CY rotates into bit3
        JCN C0, K022                ; fail if C1
        JUN FAIL
K022:
        XCH R11                     ; expect A = 8
        LDM 8
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K023                ; fail if AN
        JUN FAIL
K023:
        CLC
        TCS                         ; CY=0 -> A=9
        JCN C0, K024                ; fail if C1
        JUN FAIL
K024:
        XCH R11                     ; expect A = 9
        LDM 9
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K025                ; fail if AN
        JUN FAIL
K025:
        STC
        TCS                         ; CY=1 -> A=10, CY=0
        JCN C0, K026                ; fail if C1
        JUN FAIL
K026:
        XCH R11                     ; expect A = 10
        LDM 10
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K027                ; fail if AN
        JUN FAIL
K027:
        LDM 0
        KBP
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K028                ; fail if AN
        JUN FAIL
K028:
        LDM 4
        KBP                         ; one-hot 0100 -> 3
        XCH R11                     ; expect A = 3
        LDM 3
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K029                ; fail if AN
        JUN FAIL
K029:
        LDM 8
        KBP                         ; one-hot 1000 -> 4
        XCH R11                     ; expect A = 4
        LDM 4
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K030                ; fail if AN
        JUN FAIL
K030:
        LDM 3
        KBP                         ; two keys -> error F
        XCH R11                     ; expect A = 15
        LDM 15
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K031                ; fail if AN
        JUN FAIL
K031:
        LDM 12
        CLC
        DAA                         ; C+6 = 12h -> 2, CY=1
        JCN C1, K032                ; fail if C0
        JUN FAIL
K032:
        XCH R11                     ; expect A = 2
        LDM 2
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K033                ; fail if AN
        JUN FAIL
K033:
        LDM 5
        CLC
        DAA                         ; valid BCD unchanged
        JCN C0, K034                ; fail if C1
        JUN FAIL
K034:
        XCH R11                     ; expect A = 5
        LDM 5
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K035                ; fail if AN
        JUN FAIL
K035:
        LDM 3
        STC
        DAA                         ; CY=1 -> 3+6 = 9, CY stays
        JCN C1, K036                ; fail if C0
        JUN FAIL
K036:
        XCH R11                     ; expect A = 9
        LDM 9
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K037                ; fail if AN
        JUN FAIL
K037:

;======================================================================
; TEST 2: ADD / SUB with carry and borrow
;======================================================================
T2:
        LDM 2
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        LDM 7
        XCH R1                      ; R1 = 7
        LDM 9
        CLC
        ADD R1                      ; 9+7 = 16 -> 0, CY=1
        JCN C1, K038                ; fail if C0
        JUN FAIL
K038:
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K039                ; fail if AN
        JUN FAIL
K039:
        LDM 3
        STC
        ADD R1                      ; 3+7+1 = 11, CY=0
        JCN C0, K040                ; fail if C1
        JUN FAIL
K040:
        XCH R11                     ; expect A = 11
        LDM 11
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K041                ; fail if AN
        JUN FAIL
K041:
        LDM 9
        CLC
        SUB R1                      ; 9-7 = 2, CY=1 (no borrow)
        JCN C1, K042                ; fail if C0
        JUN FAIL
K042:
        XCH R11                     ; expect A = 2
        LDM 2
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K043                ; fail if AN
        JUN FAIL
K043:
        LDM 5
        CLC
        SUB R1                      ; 5-7 = -2 = E, CY=0 (borrow)
        JCN C0, K044                ; fail if C1
        JUN FAIL
K044:
        XCH R11                     ; expect A = 14
        LDM 14
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K045                ; fail if AN
        JUN FAIL
K045:
        LDM 9
        STC
        SUB R1                      ; 9-7-1 = 1, CY=1
        JCN C1, K046                ; fail if C0
        JUN FAIL
K046:
        XCH R11                     ; expect A = 1
        LDM 1
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K047                ; fail if AN
        JUN FAIL
K047:
        LDM 15
        XCH R1                      ; R1 = F
        LDM 15
        CLC
        ADD R1                      ; F+F = 1E -> E, CY=1
        JCN C1, K048                ; fail if C0
        JUN FAIL
K048:
        XCH R11                     ; expect A = 14
        LDM 14
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K049                ; fail if AN
        JUN FAIL
K049:

;======================================================================
; TEST 3: Index registers R0-R15
; Writes n to Rn, verifies all 16, then writes ~n and verifies again.
; R13 is overwritten here, so failures go through REGFAIL.
;======================================================================
T3:
        LDM 3
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
; --- write pattern n
        LDM 0
        XCH R0
        LDM 1
        XCH R1
        LDM 2
        XCH R2
        LDM 3
        XCH R3
        LDM 4
        XCH R4
        LDM 5
        XCH R5
        LDM 6
        XCH R6
        LDM 7
        XCH R7
        LDM 8
        XCH R8
        LDM 9
        XCH R9
        LDM 10
        XCH R10
        LDM 11
        XCH R11
        LDM 12
        XCH R12
        LDM 13
        XCH R13
        LDM 14
        XCH R14
        LDM 15
        XCH R15
; --- verify pattern n
        CLC
        LDM 0
        SUB R0                      ; expect R0 = 0
        JCN AZ, K050                ; fail if AN
        JUN REGFAIL
K050:
        CLC
        LDM 1
        SUB R1                      ; expect R1 = 1
        JCN AZ, K051                ; fail if AN
        JUN REGFAIL
K051:
        CLC
        LDM 2
        SUB R2                      ; expect R2 = 2
        JCN AZ, K052                ; fail if AN
        JUN REGFAIL
K052:
        CLC
        LDM 3
        SUB R3                      ; expect R3 = 3
        JCN AZ, K053                ; fail if AN
        JUN REGFAIL
K053:
        CLC
        LDM 4
        SUB R4                      ; expect R4 = 4
        JCN AZ, K054                ; fail if AN
        JUN REGFAIL
K054:
        CLC
        LDM 5
        SUB R5                      ; expect R5 = 5
        JCN AZ, K055                ; fail if AN
        JUN REGFAIL
K055:
        CLC
        LDM 6
        SUB R6                      ; expect R6 = 6
        JCN AZ, K056                ; fail if AN
        JUN REGFAIL
K056:
        CLC
        LDM 7
        SUB R7                      ; expect R7 = 7
        JCN AZ, K057                ; fail if AN
        JUN REGFAIL
K057:
        CLC
        LDM 8
        SUB R8                      ; expect R8 = 8
        JCN AZ, K058                ; fail if AN
        JUN REGFAIL
K058:
        CLC
        LDM 9
        SUB R9                      ; expect R9 = 9
        JCN AZ, K059                ; fail if AN
        JUN REGFAIL
K059:
        CLC
        LDM 10
        SUB R10                     ; expect R10 = 10
        JCN AZ, K060                ; fail if AN
        JUN REGFAIL
K060:
        CLC
        LDM 11
        SUB R11                     ; expect R11 = 11
        JCN AZ, K061                ; fail if AN
        JUN REGFAIL
K061:
        CLC
        LDM 12
        SUB R12                     ; expect R12 = 12
        JCN AZ, K062                ; fail if AN
        JUN REGFAIL
K062:
        CLC
        LDM 13
        SUB R13                     ; expect R13 = 13
        NOP                         ; pad: keep JCN/ISZ in one ROM page
        JCN AZ, K063                ; fail if AN
        JUN REGFAIL
K063:
        CLC
        LDM 14
        SUB R14                     ; expect R14 = 14
        JCN AZ, K064                ; fail if AN
        JUN REGFAIL
K064:
        CLC
        LDM 15
        SUB R15                     ; expect R15 = 15
        JCN AZ, K065                ; fail if AN
        JUN REGFAIL
K065:
; --- write pattern ~n
        LDM 15
        XCH R0
        LDM 14
        XCH R1
        LDM 13
        XCH R2
        LDM 12
        XCH R3
        LDM 11
        XCH R4
        LDM 10
        XCH R5
        LDM 9
        XCH R6
        LDM 8
        XCH R7
        LDM 7
        XCH R8
        LDM 6
        XCH R9
        LDM 5
        XCH R10
        LDM 4
        XCH R11
        LDM 3
        XCH R12
        LDM 2
        XCH R13
        LDM 1
        XCH R14
        LDM 0
        XCH R15
; --- verify pattern ~n
        CLC
        LDM 15
        SUB R0                      ; expect R0 = 15
        JCN AZ, K066                ; fail if AN
        JUN REGFAIL
K066:
        CLC
        LDM 14
        SUB R1                      ; expect R1 = 14
        JCN AZ, K067                ; fail if AN
        JUN REGFAIL
K067:
        CLC
        LDM 13
        SUB R2                      ; expect R2 = 13
        JCN AZ, K068                ; fail if AN
        JUN REGFAIL
K068:
        CLC
        LDM 12
        SUB R3                      ; expect R3 = 12
        JCN AZ, K069                ; fail if AN
        JUN REGFAIL
K069:
        CLC
        LDM 11
        SUB R4                      ; expect R4 = 11
        JCN AZ, K070                ; fail if AN
        JUN REGFAIL
K070:
        CLC
        LDM 10
        SUB R5                      ; expect R5 = 10
        JCN AZ, K071                ; fail if AN
        JUN REGFAIL
K071:
        CLC
        LDM 9
        SUB R6                      ; expect R6 = 9
        JCN AZ, K072                ; fail if AN
        JUN REGFAIL
K072:
        CLC
        LDM 8
        SUB R7                      ; expect R7 = 8
        JCN AZ, K073                ; fail if AN
        JUN REGFAIL
K073:
        CLC
        LDM 7
        SUB R8                      ; expect R8 = 7
        JCN AZ, K074                ; fail if AN
        JUN REGFAIL
K074:
        CLC
        LDM 6
        SUB R9                      ; expect R9 = 6
        JCN AZ, K075                ; fail if AN
        JUN REGFAIL
K075:
        CLC
        LDM 5
        SUB R10                     ; expect R10 = 5
        JCN AZ, K076                ; fail if AN
        JUN REGFAIL
K076:
        CLC
        LDM 4
        SUB R11                     ; expect R11 = 4
        JCN AZ, K077                ; fail if AN
        JUN REGFAIL
K077:
        CLC
        LDM 3
        SUB R12                     ; expect R12 = 3
        JCN AZ, K078                ; fail if AN
        JUN REGFAIL
K078:
        CLC
        LDM 2
        SUB R13                     ; expect R13 = 2
        JCN AZ, K079                ; fail if AN
        JUN REGFAIL
K079:
        CLC
        LDM 1
        SUB R14                     ; expect R14 = 1
        JCN AZ, K080                ; fail if AN
        JUN REGFAIL
K080:
        CLC
        LDM 0
        SUB R15                     ; expect R15 = 0
        JCN AZ, K081                ; fail if AN
        JUN REGFAIL
K081:

;======================================================================
; TEST 4: Register pairs, INC, ISZ, FIN, JIN
;======================================================================
T4:
        LDM 4
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        FIM P0, 0x5A                ; R0=5, R1=A
        CLC
        LDM 5
        SUB R0
        JCN AZ, K082                ; R0 must be 5
        JUN FAIL
K082:
        CLC
        LDM 10
        SUB R1
        JCN AZ, K083                ; R1 must be A
        JUN FAIL
K083:
        LDM 3
        XCH R0                      ; swap: A=5, R0=3
        XCH R11                     ; expect A = 5
        LDM 5
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K084                ; fail if AN
        JUN FAIL
K084:
        CLC
        LDM 3
        SUB R0
        JCN AZ, K085                ; R0 must now be 3
        JUN FAIL
K085:
        LDM 15
        XCH R2
        INC R2                      ; F+1 wraps to 0
        LD R2
        XCH R11                     ; expect A = 0
        LDM 0
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K086                ; fail if AN
        JUN FAIL
K086:
        LDM 12
        XCH R2                      ; loop counter C..F
        LDM 0
        XCH R3
T4LP:
        INC R3
        ISZ R2, T4LP                ; runs 4 times
        LD R3
        XCH R11                     ; expect A = 4
        LDM 4
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K087                ; fail if AN
        JUN FAIL
K087:
        FIM P0, TBL & 0xFF          ; P0 -> table byte in this page
        FIN P1                      ; R2:R3 = ROM[page:P0] = C3h
        CLC
        LDM 12
        SUB R2
        JCN AZ, K088                ; high nibble C
        JUN FAIL
K088:
        CLC
        LDM 3
        SUB R3
        JCN AZ, K089                ; low nibble 3
        JUN FAIL
K089:
        FIM P2, T4JT & 0xFF
        JIN P2                      ; indirect jump to T4JT
        JUN FAIL                    ; JIN fell through
TBL:
        DB 0xC3                     ; FIN data byte
T4JT:

;======================================================================
; TEST 5: Subroutine stack, 3 levels deep (JMS/BBL)
;======================================================================
T5:
        LDM 5
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        LDM 0
        XCH R4                      ; depth counter
        JMS SUB1
        XCH R11                     ; SUB1 returns via BBL 7
        LDM 7
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K090                ; fail if AN
        JUN FAIL
K090:
        LD R4
        XCH R11                     ; all three levels ran
        LDM 3
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K091                ; fail if AN
        JUN FAIL
K091:
        JUN T6
SUB1:
        INC R4
        JMS SUB2
        XCH R11                     ; expect A = 6
        LDM 6
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K092                ; fail if AN
        JUN FAIL
K092:
        BBL 7
SUB2:
        INC R4
        JMS SUB3
        XCH R11                     ; expect A = 5
        LDM 5
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K093                ; fail if AN
        JUN FAIL
K093:
        BBL 6
SUB3:
        INC R4
        BBL 5

;======================================================================
; TEST 6: Conditional jumps (JCN)
;======================================================================
T6:
        LDM 6
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        LDM 0
        JCN AZ, T6A                 ; must jump (AZ)
        JUN FAIL
T6A:
        LDM 1
        JCN AN, T6B                 ; must jump (AN)
        JUN FAIL
T6B:
        STC
        JCN C1, T6C                 ; must jump (C1)
        JUN FAIL
T6C:
        CLC
        JCN C0, T6D                 ; must jump (C0)
        JUN FAIL
T6D:
        LDM 1
        STC
        JCN AZC1, T6E               ; must jump (AZC1)
        JUN FAIL
T6E:
        LDM 1
        CLC
        JCN NAZC1, T6G              ; must jump (NAZC1)
        JUN FAIL
T6G:
        LDM 1
        JCN AZ, T6F                 ; must NOT jump (AZ)
        LDM 0
        JCN AN, T6F                 ; must NOT jump (AN)
        CLC
        JCN C1, T6F                 ; must NOT jump (C1)
        STC
        JCN C0, T6F                 ; must NOT jump (C0)
        LDM 1
        CLC
        JCN AZC1, T6F               ; must NOT jump (AZC1)
        LDM 0
        CLC
        JCN NAZC1, T6F              ; must NOT jump (NAZC1)
        JUN T7
T6F:
        JUN FAIL

;======================================================================
; TEST 7: 4002 RAM: main memory and status characters
; Chip 0, bank 0, registers 0-3. Char i of reg r = (i + r), then
; the complement on the second pass. Status: r, ~r, r+8, ~(r+8).
;======================================================================
T7:
        LDM 7
        XCH R13                     ; R13 = current test number
        JMS SHOW                    ; display test number on ROM port 0
        FIM P0, 0x00
        SRC P0                      ; reg 0, char 0
        LDM 6
        WRM                         ; M = 6
        LDM 3
        CLC
        ADM                         ; 3+6 = 9
        JCN C0, K094                ; fail if C1
        JUN FAIL
K094:
        XCH R11                     ; expect A = 9
        LDM 9
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K095                ; fail if AN
        JUN FAIL
K095:
        LDM 9
        CLC
        SBM                         ; 9-6 = 3, CY=1
        JCN C1, K096                ; fail if C0
        JUN FAIL
K096:
        XCH R11                     ; expect A = 3
        LDM 3
        CLC
        SUB R11                     ; A = expected - actual
        JCN AZ, K097                ; fail if AN
        JUN FAIL
K097:
        LDM 0
        XCH R4                      ; R4 = 0: pattern pass
T7P:
; --- write phase
        FIM P0, 0x00                ; R0 = register, R1 = char
        LDM 12
        XCH R2                      ; 4 registers
T7W:
        SRC P0
        JMS PAT
        LD R3
        WRM
        ISZ R1, T7W                 ; 16 chars
        LD R0
        WR0                         ; status 0 = r
        CMA
        WR1                         ; status 1 = ~r
        LDM 8
        CLC
        ADD R0
        WR2                         ; status 2 = r+8
        CMA
        WR3                         ; status 3 = ~(r+8)
        INC R0
        ISZ R2, T7W
; --- read/verify phase
        FIM P0, 0x00
        LDM 12
        XCH R2
T7R:
        SRC P0
        JMS PAT
        RDM
        CLC
        SUB R3
        JCN AZ, K098                ; main char mismatch
        JUN FAIL
K098:
        ISZ R1, T7R
        RD0
        CLC
        SUB R0
        JCN AZ, K099                ; status 0
        JUN FAIL
K099:
        RD1
        CMA
        CLC
        SUB R0
        JCN AZ, K100                ; status 1
        JUN FAIL
K100:
        LDM 8
        CLC
        ADD R0
        XCH R3
        RD2
        CLC
        SUB R3
        JCN AZ, K101                ; status 2
        JUN FAIL
K101:
        RD3
        CMA
        CLC
        SUB R3
        JCN AZ, K102                ; status 3
        JUN FAIL
K102:
        INC R0
        ISZ R2, T7R
        LD R4
        JCN AN, PASS                ; both passes done
        INC R4                      ; R4 = 1: complement pass
        JUN T7P

;======================================================================
; ALL TESTS PASSED: RAM port = 1, blink A/5 on ROM port 4x, rerun
;======================================================================
PASS:
        FIM P7, 0x00
        SRC P7
        LDM 1
        WMP                         ; RAM port = 1 (pass)
        LDM 12
        XCH R12                     ; 4 blinks
BLINK:
        LDM 10
        WRR
        JMS DELAY
        LDM 5
        WRR
        JMS DELAY
        ISZ R12, BLINK
        JUN T1                      ; run the suite again

;======================================================================
; FAILURE: ROM port = failing test number, RAM port = F, halt
;======================================================================
REGFAIL:
        LDM 3
        XCH R13                     ; restore test no. lost in test 3
FAIL:
        FIM P7, 0x00
        SRC P7
        LD R13
        WRR                         ; ROM port = failing test
        LDM 15
        WMP                         ; RAM port = F
;======================================================================
; TEST 99: INSTRUCTION HALT
;======================================================================
HALT:
        JUN HALT

;======================================================================
; SUBROUTINES
;======================================================================
; SHOW: write R13 to ROM port 0. Uses P7.
SHOW:
        FIM P7, 0x00
        SRC P7
        LD R13
        WRR
        BBL 0
; PAT: R3 = (R1 + R0), complemented if R4 != 0
PAT:
        LD R1
        CLC
        ADD R0
        XCH R3
        LD R4
        JCN AZ, PAT1
        LD R3
        CMA
        XCH R3
PAT1:
        BBL 0
; DELAY: 4-deep ISZ loop, 8*16^3 iterations, ~0.7 s at 740 kHz
DELAY:
        FIM P0, 0x00
        FIM P1, 0x08
DLY:
        ISZ R0, DLY
        ISZ R1, DLY
        ISZ R2, DLY
        ISZ R3, DLY
        BBL 0

        END
